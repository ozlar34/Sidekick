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
        let textView = NSTextView(
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
        textView.textContainerInset = NSSize(width: 0, height: 12)        // P7-PAD-01 (CONTEXT Claude's Discretion — recommended)
        textView.font = NSFont.systemFont(ofSize: 14, weight: .regular)
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
        }

        func updateCaretTypingAttributes(in tv: NSTextView) {
            let ns = tv.string as NSString
            let caretLoc = tv.selectedRange().location
            let firstNewline = ns.range(of: "\n")
            // Caret is on line 1 if there is no newline yet (single-line doc)
            // or its position is at/before the first newline character.
            let isOnFirstLine = firstNewline.location == NSNotFound
                                || caretLoc <= firstNewline.location
            let font: NSFont = isOnFirstLine
                ? NSFont.systemFont(ofSize: 14 * 1.5, weight: .bold)
                : NSFont.systemFont(ofSize: 14, weight: .regular)
            var attrs = tv.typingAttributes
            attrs[.font] = font
            tv.typingAttributes = attrs
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
