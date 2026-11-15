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
import AppKit
import SwiftUI

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
        textView.textContainerInset = NSSize(width: 14, height: 14)       // P7-PAD-01 (CONTEXT Claude's Discretion — recommended)
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
        defaultStyle.minimumLineHeight = 20
        defaultStyle.maximumLineHeight = 20
        defaultStyle.paragraphSpacing = 1
        textView.defaultParagraphStyle = defaultStyle
        // Explicit dynamic text color — NSColor.textColor adapts to light/dark
        // appearance, matching the old TextEditor + SwiftUI .primary behavior.
        textView.textColor = NSColor.textColor
        textView.insertionPointColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        // Drop NSUnderlineStyle.single from the default linkTextAttributes
        // (kept linkColor + pointingHand) so link-chip pills don't get an
        // auto-underline rendered at the control-glyph baseline. The
        // [label](url) styled-label path applies its own explicit storage
        // underline in MarkdownTextStorage.applyLinks, so dropping the
        // temp-attribute default doesn't affect it.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        controller.textView = textView   // NEW (D-TB-02) — publish upward once
        // quick-260523-29t: weak back-pointer so HybridTextView can republish
        // armedInlineKinds upward without a retain cycle.
        textView.hybridController = controller

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

    /// Outcome of the EDIT-02 `updateNSView` binding-push decision.
    ///
    /// Extracted as a named type so the guard's branching logic is unit-testable
    /// without mounting the full `NSViewRepresentable` (IN-02). `updateNSView`
    /// itself just switches on the result.
    enum BindingPushDecision: Equatable {
        /// Binding value already equals the text view string — nothing to do.
        case noChange
        /// Incoming `text` differs from the text view, but no genuine external
        /// push has occurred (tokens equal) — this is a reflexive echo of user
        /// typing. Skip the undo-corrupting bare-storage replace.
        case reflexiveEcho
        /// A genuine external push (note switch / reload-from-disk) raised the
        /// token. Apply the bare-storage replace and record the token.
        case applyExternalPush
    }

    /// Pure decision function for the EDIT-02 binding-push guard.
    ///
    /// Classification is by EXPLICIT PUSH TOKEN, never by string value:
    ///   - currentString == incomingText               -> noChange
    ///   - currentToken != lastConsumedToken           -> applyExternalPush
    ///   - otherwise (token unchanged, strings differ) -> reflexiveEcho
    ///
    /// Why token, not string (history): the WR-01 fix tried to distinguish
    /// echo vs push by comparing `incomingText` against a remembered string. A
    /// single-shot variant of that (commit 79f0f3b) cleared the remembered
    /// string on the first echo, so every later reflexive echo of normal
    /// typing was misclassified as an external push -> bare-storage replace ->
    /// corrupted undo stack -> Cmd+Z wiped the whole note. An explicit push
    /// token cannot be fooled by value collisions in EITHER direction.
    static func bindingPushDecision(
        currentString: String,
        incomingText: String,
        currentToken: Int,
        lastConsumedToken: Int
    ) -> BindingPushDecision {
        guard currentString != incomingText else { return .noChange }
        if currentToken != lastConsumedToken {
            return .applyExternalPush
        }
        return .reflexiveEcho
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage as? MarkdownTextStorage else { return }

        // External binding-push guard (EDIT-02).
        //
        // Classification is token-based: EditorPaneView bumps
        // `controller.externalPushToken` at each genuine external-push site
        // (note switch, reload-from-disk). updateNSView compares that token
        // against the value this Coordinator last consumed — an advance means
        // a real external push; an unchanged token means any binding change
        // reaching here is a reflexive echo of user typing.
        //
        // Why token, not string value: a bare `storage.replaceCharacters`
        // bypasses the shouldChangeText/didChangeText sandwich and corrupts
        // NSTextView's undo coalescing, so it must fire ONLY for genuine
        // external pushes. The WR-01 single-shot string sentinel could be
        // fooled by value collisions in both directions (see
        // `bindingPushDecision`); an explicit push token cannot.
        //
        // The branching itself lives in `bindingPushDecision` (a pure
        // function) so it can be unit-tested without mounting the
        // NSViewRepresentable.
        switch Self.bindingPushDecision(
            currentString: textView.string,
            incomingText: text,
            currentToken: controller.externalPushToken,
            lastConsumedToken: context.coordinator.lastConsumedPushToken
        ) {
        case .noChange:
            break
        case .reflexiveEcho:
            // Reflexive echo of user typing — the SwiftUI binding caught up
            // to what the Coordinator pushed in textDidChange. A bare-storage
            // replace here bypasses the shouldChangeText/didChangeText
            // sandwich and corrupts the NSTextView undo stack (EDIT-02).
            // No token advanced -> skip. No state to clear.
            break
        case .applyExternalPush:
            // Genuine external push — note switch or reload-from-disk bumped
            // the token. Apply the bare-storage replace (intentionally NOT
            // registered on the undo stack — this content did not come from a
            // user keystroke), then record the token so a follow-up reflexive
            // echo of this same value is not re-applied.
            storage.beginEditing()
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.replaceCharacters(in: fullRange, with: text)
            storage.endEditing()
            // processEditing fires inside endEditing → attributes reapplied.
            context.coordinator.lastConsumedPushToken = controller.externalPushToken
        }
    }

    // MARK: - Coordinator (NSTextViewDelegate bridge)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HybridEditorView
        weak var textView: NSTextView?
        /// The value of `controller.externalPushToken` this Coordinator has
        /// already applied. updateNSView treats `controller.externalPushToken
        /// != lastConsumedPushToken` as a genuine external push. Initialized
        /// to match the controller's starting token in `init` so the first
        /// updateNSView after mount is not misread as a push.
        var lastConsumedPushToken: Int

        init(_ parent: HybridEditorView) {
            self.parent = parent
            // Seed the last-consumed token to the controller's current value
            // so the first updateNSView after mount is treated as an echo /
            // no-op, not a push (makeNSView already seeds the initial text).
            // `controller` is @MainActor-isolated and makeCoordinator() — the
            // sole caller — runs on the main actor, so the read is safe.
            self.lastConsumedPushToken = MainActor.assumeIsolated {
                parent.controller.externalPushToken
            }
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Infinite-loop guard — only push up if the binding value is stale.
            // No per-keystroke string snapshot is needed: the EDIT-02 echo
            // guard is now purely token-based (see `bindingPushDecision`).
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
                if FormattingToolbarView.handleThematicBreakReturn(in: textView) { return true }
                if FormattingToolbarView.handleChecklistReturn(in: textView) { return true }
                if FormattingToolbarView.handleBulletReturn(in: textView) { return true }
                if FormattingToolbarView.handleNumberedReturn(in: textView) { return true }
                return false
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if FormattingToolbarView.handleThematicBreakBackspace(in: textView) { return true }   // HR-03: one-shot HR delete from adjacent empty line
                if FormattingToolbarView.handleAtomicMarkerBackspace(in: textView) { return true }    // quick-260524-0ia: atomic inline-format marker pair delete
                if FormattingToolbarView.handleChecklistBackspace(in: textView) { return true }
            }
            if commandSelector == #selector(NSResponder.deleteForward(_:)) {
                if FormattingToolbarView.handleThematicBreakForwardDelete(in: textView) { return true } // HR-03: one-shot HR delete from adjacent empty line
                if FormattingToolbarView.handleAtomicMarkerForwardDelete(in: textView) { return true } // quick-260524-0ia: atomic inline-format marker pair delete
                if FormattingToolbarView.handleChecklistForwardDelete(in: textView) { return true }
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
