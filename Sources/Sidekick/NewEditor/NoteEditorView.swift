import AppKit
import SwiftUI

/// SwiftUI host of the new editor view. Same contract as `HybridEditorView`: `text` is the
/// markdown of the note; the view shows it through the note document and writes back the markdown
/// the note document produces.
struct NoteEditorView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: HybridEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NoteTextView.make()
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor
        scrollView.documentView = tv

        context.coordinator.textView = tv
        tv.load(markdown: text)
        tv.onMarkdownChange = { [weak coordinator = context.coordinator] md in
            guard let parent = coordinator?.parent, parent.text != md else { return }
            parent.text = md
        }
        tv.onShiftTabAtStart = { [weak controller] in controller?.onShiftTabAtBodyStart?() }
        controller.textView = tv
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? NoteTextView else { return }
        // Same echo guard as the old editor: only a raised push token (note switch, reload) replaces the buffer.
        switch HybridEditorView.bindingPushDecision(
            currentString: tv.markdown,
            incomingText: text,
            currentToken: controller.externalPushToken,
            lastConsumedToken: context.coordinator.lastConsumedPushToken
        ) {
        case .noChange:
            context.coordinator.lastConsumedPushToken = controller.externalPushToken
        case .reflexiveEcho:
            break
        case .applyExternalPush:
            tv.load(markdown: text)
            context.coordinator.lastConsumedPushToken = controller.externalPushToken
        }
    }

    final class Coordinator {
        var parent: NoteEditorView
        weak var textView: NoteTextView?
        var lastConsumedPushToken: Int

        init(_ parent: NoteEditorView) {
            self.parent = parent
            self.lastConsumedPushToken = MainActor.assumeIsolated { parent.controller.externalPushToken }
        }
    }
}
