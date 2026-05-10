/// NSViewRepresentable wrapping the Sidekick hybrid markdown editor.
///
/// Owns the four-piece TextKit 1 assembly:
///   MarkdownTextStorage → MarkdownLayoutManager → NSTextContainer → NSTextView
/// Exposes a SwiftUI-visible @Binding var text: String that is the single
/// source of truth for the underlying markdown bytes. The Coordinator
/// bridges NSTextViewDelegate.textDidChange → binding.text, with an
/// infinite-loop guard (only write if values differ).
///
/// Placement: used by EditorPaneView.body's non-preview branch as a
/// drop-in replacement for TextEditor(text: $localBody). The SwiftUI
/// "Start writing..." overlay stays at the EditorPaneView level
/// (D-ES-04) because `text.isEmpty` is still observable from SwiftUI.
///
/// Pattern source: ResizeHandleView.swift (NSViewRepresentable + final-class
/// AppKit wrapper), FormattingToolbarView.swift (NSTextView edit-sandwich —
/// we don't re-implement but must not break it).
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md
///   D-ES-01, D-ES-03, D-ES-04, D-ST-01, D-ST-02.
import AppKit
import SwiftUI

/// NSTextView subclass that floors its frame height at the enclosing scroll
/// view's clip-view height. Without this, a short note's text view ends at
/// content height, leaving a "dead zone" below — clicks in that empty area
/// fall outside the text view's frame and never reach it. With the floor in
/// place, NSTextView's built-in "click below the last glyph → caret at end
/// of document" behavior covers the empty area for free, no mouseDown
/// override required.
///
/// Two paths feed the height update:
///   1. setConstrainedFrameSize — invoked by the layout manager after every
///      text edit. Flooring `desiredSize.height` at clip-view height makes
///      every layout-driven resize respect the floor.
///   2. clipFrameChanged — invoked when the scroll view (and thus the clip
///      view) resizes, e.g. window resize. Layout doesn't re-fire on a
///      height-only resize, so we re-floor explicitly here.
///
/// `widthTracksTextView` + `autoresizingMask = .width` continue to handle
/// width tracking; we only own the vertical floor.
final class HybridTextView: NSTextView {
    /// Click-to-toggle for GFM task-list checkboxes. When the user clicks on
    /// the substituted ◯/◉ glyph (the leading `-` char of a task-list line),
    /// flip the state byte (` ` ↔ `x`) instead of moving the caret. Anywhere
    /// else, fall through to NSTextView's default cursor placement.
    ///
    /// Hit detection uses `glyphIndex(for:in:fractionOfDistanceThroughGlyph:)`:
    /// only treat as a hit if `fraction < 1.0` (the click landed inside the
    /// glyph rect, not past its trailing edge — past-the-edge hits should
    /// place the caret like normal). F-09: also assert the click x sits at
    /// or past the glyph's left edge — `glyphIndex(for:)` snaps clicks in
    /// the leading-indent zone (before the line's first glyph) to glyph 0
    /// with fraction 0, which would otherwise toggle on margin clicks.
    override func mouseDown(with event: NSEvent) {
        if let lm = layoutManager,
           let tc = textContainer,
           let storage = textStorage {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let textPoint = NSPoint(
                x: viewPoint.x - textContainerOrigin.x,
                y: viewPoint.y - textContainerOrigin.y
            )
            var fraction: CGFloat = 0
            let glyphIdx = lm.glyphIndex(
                for: textPoint,
                in: tc,
                fractionOfDistanceThroughGlyph: &fraction
            )
            if fraction < 1.0 {
                let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
                if charIdx >= 0,
                   charIdx < storage.length,
                   storage.attribute(.sidekickChecklistMarker,
                                     at: charIdx,
                                     effectiveRange: nil) != nil {
                    let glyphRect = lm.boundingRect(
                        forGlyphRange: NSRange(location: glyphIdx, length: 1),
                        in: tc
                    )
                    if textPoint.x >= glyphRect.minX {
                        if FormattingToolbarView.toggleChecklistState(at: charIdx, in: self) {
                            return
                        }
                    }
                }
            }
        }
        super.mouseDown(with: event)
    }

    /// F-07: defense against macOS Character Viewer (emoji picker) handing us
    /// a stale `replacementRange` after our nonactivating panel briefly loses
    /// input-target status. Per FB13789916, the picker can capture a range at
    /// invocation time that no longer matches the textView's selection by the
    /// time the user picks an emoji and the picker fires `insertText:`. Honoring
    /// the stale range causes the next typed character to replace the just-
    /// inserted emoji. When we are NOT in active marked-text composition (so
    /// no IME composition is in flight) and the picker's range disagrees with
    /// our current selection, fall back to inserting at the current selection
    /// (`NSNotFound` per NSTextInputClient docs).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        var range = replacementRange
        if !hasMarkedText(),
           range.location != NSNotFound,
           !NSEqualRanges(range, selectedRange()) {
            range = NSRange(location: NSNotFound, length: 0)
        }
        super.insertText(string, replacementRange: range)
    }

    override func setConstrainedFrameSize(_ desiredSize: NSSize) {
        var size = desiredSize
        if let clipHeight = enclosingScrollView?.contentView.bounds.height {
            size.height = max(size.height, clipHeight)
        }
        super.setConstrainedFrameSize(size)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clipView = enclosingScrollView?.contentView else { return }
        // Remove first to avoid stacking observers if the view re-mounts
        // (e.g. SwiftUI tearing down and recreating the NSViewRepresentable).
        NotificationCenter.default.removeObserver(
            self, name: NSView.frameDidChangeNotification, object: clipView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification, object: clipView
        )
        clipView.postsFrameChangedNotifications = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipFrameChanged() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? used.height
        let insetY = textContainerInset.height * 2
        let target = max(used.height + insetY, clipHeight)
        if abs(frame.height - target) > 0.5 {
            var f = frame
            f.size.height = target
            frame = f
        }
    }
}

struct HybridEditorView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: HybridEditorController   // NEW (D-TB-02)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 1. Storage + layout manager + container + text view — four-piece
        //    TextKit 1 assembly. ORDER MATTERS: storage first, layout manager
        //    added to storage, container added to layout manager, text view
        //    created with that container.
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        // Scroll view wrapper created first so we can size the text view to match.
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        // NSTextView hosted in NSScrollView needs Apple's full sizing contract:
        // initial non-zero frame + min/max size + isVerticallyResizable. Without
        // these, the text view stays 0×0, clicks never land on it, and typing
        // never reaches the storage. (This is distinct from the .zero frame
        // that works for standalone NSTextView instances.)
        let textView = HybridTextView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 0),
            textContainer: container
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        // F-07: NSTextView's automatic text mutations (smart quotes, dash
        // substitution, autocorrect, link detection, inline completion) inject
        // synthetic key events that delete recently-typed characters. After
        // a paste:-driven emoji insertion (which is how the macOS Character
        // Viewer commits picks), autocorrect fires a synthetic deleteBackward:
        // ~1.4s later, removing whatever ASCII char the user just typed
        // adjacent to the emoji. A markdown notes editor wants none of these
        // mutations — they conflict with markdown syntax (smart quotes break
        // raw ", dash subs break --, text replacements rewrite snippets).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 20, height: 10)       // P7-PAD-01 (CONTEXT Claude's Discretion — recommended)
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        // Absolute line-height clamp instead of lineHeightMultiple. AppKit
        // derives the insertion-point height from the layout fragment height,
        // and on macOS 14+ uses NSTextInsertionIndicator (a sibling subview)
        // so the legacy drawInsertionPoint(in:color:turnedOn:) override is
        // bypassed. Setting min == max forces a fixed pixel line box regardless
        // of font metrics so the caret stays in proportion to the rendered
        // glyph height. paragraphSpacing adds breathing room between bullets
        // and paragraphs without growing the line box (and thus the caret).
        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.minimumLineHeight = 18
        defaultStyle.maximumLineHeight = 18
        defaultStyle.paragraphSpacing = 1
        textView.defaultParagraphStyle = defaultStyle
        // Explicit dynamic text color — NSColor.textColor adapts to light/dark
        // appearance, matching the old TextEditor + SwiftUI .primary behavior.
        textView.textColor = NSColor.textColor
        textView.insertionPointColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        controller.textView = textView   // NEW (D-TB-02) — publish upward once

        // Seed initial text. replaceCharacters triggers processEditing which
        // applies the initial attribute pass.
        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }

        // Seed caret typing attributes for the initial selection — programmatic
        // seeding does not fire textViewDidChangeSelection, so call directly.
        context.coordinator.updateCaretTypingAttributes(in: textView)
        // Same reason: seed the toolbar's active-format highlight for the
        // initial caret position so a freshly-mounted note with the caret
        // already inside formatted text shows the correct active button.
        context.coordinator.updateActiveInlineKind(in: textView)
        context.coordinator.updateActiveHeadingLevel(in: textView)
        context.coordinator.updateActiveLinePrefix(in: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage as? MarkdownTextStorage else { return }

        // External binding-push: e.g. reloadFromDisk() (STORAGE-03) or
        // toolbar wrapSelection mutation from Phase 10.
        //
        // Guard against infinite loop: only push into storage when the
        // binding value differs from the current text view string. If we
        // blindly wrote every update, textDidChange → binding.text = tv.string
        // → updateNSView → storage.replaceCharacters → textDidChange would
        // never terminate on first keystroke.
        if textView.string != text {
            // Programmatic edit — bypass the shouldChangeText sandwich
            // (CONTEXT PATTERNS line 497 note): this update originates from
            // SwiftUI state, NOT from a user keystroke, so we should NOT
            // register on the NSTextView undo stack.
            storage.beginEditing()
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.replaceCharacters(in: fullRange, with: text)
            storage.endEditing()
            // processEditing fires inside endEditing → attributes reapplied.
        }
    }

    // MARK: - Coordinator (NSTextViewDelegate bridge)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HybridEditorView
        weak var textView: NSTextView?

        init(_ parent: HybridEditorView) {
            self.parent = parent
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Infinite-loop guard — only push up if the binding value is stale.
            if parent.text != tv.string {
                parent.text = tv.string
            }
            // Text edits can change which inline pair encloses the caret
            // without the selection itself moving (e.g. typing the closing
            // `*` of an italic pair around the caret). Refresh here too.
            updateActiveInlineKind(in: tv)
            // Same reason for headings: typing/deleting a leading `#` flips
            // the line in/out of heading state without selection movement.
            updateActiveHeadingLevel(in: tv)
            // Same reason for line prefixes: typing/deleting a `- ` prefix
            // flips the line in/out of bullet/numbered/checklist/blockquote
            // state without the selection moving.
            updateActiveLinePrefix(in: tv)
        }

        /// Caret typing attributes are sticky after edits — when the user
        /// presses Enter from line 1 (H1) into line 2, AppKit carries the
        /// H1 typing attrs forward, so the caret on line 2 stays tall even
        /// though the line 2 text will render at body 14pt. Refresh on every
        /// selection change so the caret height matches what the next typed
        /// character will be: H1 on the first line, body 14pt elsewhere.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            updateCaretTypingAttributes(in: tv)
            updateActiveInlineKind(in: tv)
            updateActiveHeadingLevel(in: tv)
            updateActiveLinePrefix(in: tv)
        }

        /// Recompute which inline pair (bold / italic / code) currently
        /// encloses the selection and publish it to the controller so the
        /// toolbar can highlight the matching button. Only writes when the
        /// value actually changes — `@Published` fires objectWillChange even
        /// on identical writes, which would re-render EditorPaneView on
        /// every keystroke unnecessarily.
        ///
        /// `MainActor.assumeIsolated` because NSTextViewDelegate methods are
        /// documented main-thread-only but their Swift signatures are not
        /// `@MainActor` annotated, while `HybridEditorController` is —
        /// without the assertion the controller property writes flag a
        /// concurrency diagnostic.
        func updateActiveInlineKind(in tv: NSTextView) {
            let kind = FormattingToolbarView.activeInlineKind(
                body: tv.string,
                selection: tv.selectedRange()
            )
            MainActor.assumeIsolated {
                if parent.controller.activeInlineKind != kind {
                    parent.controller.activeInlineKind = kind
                }
            }
        }

        /// Recompute the heading level of the line containing the caret
        /// and publish it to the controller. Single-line scan over the
        /// `^#{1,6} ` prefix — cheaper than re-running the full parser
        /// for what is purely a UI hint. Coalesces identical writes for
        /// the same reason as `updateActiveInlineKind`.
        /// Recompute the line-prefix block format (bullet / numbered /
        /// checklist / blockquote) of the line containing the caret and
        /// publish to the controller. Coalesces identical writes for the
        /// same reason as `updateActiveInlineKind`.
        func updateActiveLinePrefix(in tv: NSTextView) {
            let prefix = FormattingToolbarView.activeLinePrefix(
                body: tv.string,
                selection: tv.selectedRange()
            )
            MainActor.assumeIsolated {
                if parent.controller.activeLinePrefix != prefix {
                    parent.controller.activeLinePrefix = prefix
                }
            }
        }

        func updateActiveHeadingLevel(in tv: NSTextView) {
            let nsBody = tv.string as NSString
            let selection = tv.selectedRange()
            let probe = NSRange(location: min(selection.location, nsBody.length), length: 0)
            let lineRange = nsBody.lineRange(for: probe)
            let lineNS = nsBody.substring(with: lineRange) as NSString

            var hashes = 0
            while hashes < lineNS.length, lineNS.character(at: hashes) == 0x23 {
                hashes += 1
            }
            let level: Int?
            if hashes >= 1, hashes <= 6,
               hashes < lineNS.length, lineNS.character(at: hashes) == 0x20 {
                // Cap display at 3 — toolbar dropdown only offers H1–H3.
                level = min(hashes, 3)
            } else {
                level = nil
            }
            MainActor.assumeIsolated {
                if parent.controller.activeHeadingLevel != level {
                    parent.controller.activeHeadingLevel = level
                }
            }
        }

        func updateCaretTypingAttributes(in tv: NSTextView) {
            // Body editor is uniformly body-styled now that title lives in
            // its own field. Pin font + paragraph style so the caret on an
            // empty doc reserves the body line box (18pt) instead of falling
            // back to defaultParagraphStyle metrics.
            var attrs = tv.typingAttributes
            attrs[.font] = NSFont.systemFont(ofSize: 15, weight: .regular)
            attrs[.paragraphStyle] = MarkdownTextStorage.bodyParagraphStyle
            tv.typingAttributes = attrs
        }

        /// Enter continuation for list-style lines. Order matters: checklist
        /// is a superset of the bullet prefix (`- [ ] foo` starts with `- `),
        /// so the checklist handler runs first and only returns true when the
        /// line really is a task-list line. Bullet and numbered handlers
        /// follow. Each returns true when it handled the Enter — caller stops
        /// the default `insertNewline:` from firing in that case. Other
        /// `doCommandBy` selectors (insert tab, delete forward, etc.) fall
        /// through to NSTextView's default behavior.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if FormattingToolbarView.handleChecklistReturn(in: textView) { return true }
                if FormattingToolbarView.handleBulletReturn(in: textView) { return true }
                if FormattingToolbarView.handleNumberedReturn(in: textView) { return true }
                return false
            }
            // Shift-Tab at body offset 0 → return focus to the title field
            // (counterpart to title→body Tab in EditorPaneView). Anywhere else
            // in the body, fall through to NSTextView's default backtab.
            if commandSelector == #selector(NSResponder.insertBacktab(_:)),
               textView.selectedRange().location == 0,
               textView.selectedRange().length == 0 {
                if let callback = parent.controller.onShiftTabAtBodyStart {
                    callback()
                    return true
                }
            }
            return false
        }

        /// PRIMARY PATH — NSTextViewDelegate method invoked when the user clicks on a
        /// character that carries the `.link` attribute. Returning true = we handled
        /// it; returning false = fall through to NSTextView's default behavior
        /// (cursor placement on plain click, per Apple AppKit docs when the delegate
        /// method IS implemented). Per 10-CONTEXT.md D-LC-01.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // D-LC-01: ⌘-click opens; plain click falls through to default cursor positioning
            guard NSEvent.modifierFlags.contains(.command) else {
                return false   // Let NSTextView do default cursor positioning on plain click
            }
            // AppKit's clickedOnLink delivers `link` as Any — usually URL, sometimes String
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            if let url {
                // D-LC-02: dispatch link URL via NSWorkspace (hybrid editor owns this path; prior preview consumer was removed in Phase 11).
                // All schemes pass through (http/https/mailto/file/custom);
                // no whitelist, no confirm sheet.
                NSWorkspace.shared.open(url)
            }
            return true   // ⌘-click handled (or no-op'd on nil URL)
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    @Previewable @State var text = ""
    let controller = HybridEditorController()
    return HybridEditorView(text: $text, controller: controller)
        .frame(width: 400, height: 500)
}

#Preview("Mixed formatting") {
    @Previewable @State var text = """
# Heading Example
This is **bold text** and *italic text* with `inline code`.
- Bullet point one
- Bullet point two
A [link example](https://example.com) ends this preview.
"""
    let controller = HybridEditorController()
    return HybridEditorView(text: $text, controller: controller)
        .frame(width: 400, height: 500)
}
