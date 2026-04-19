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

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.textContainerInset = NSSize(width: 0, height: 12)        // P7-PAD-01 (CONTEXT Claude's Discretion — recommended)
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)  // matches EditorPaneView.swift:74
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Seed initial text. replaceCharacters triggers processEditing which
        // applies the initial attribute pass.
        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }

        // 2. Scroll view wrapper.
        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

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
    }
}
