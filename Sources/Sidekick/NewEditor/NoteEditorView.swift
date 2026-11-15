import AppKit
import SwiftUI

/// SwiftUI host of the new editor view. It shows an open note: the note's storage and undo history
/// are attached to the single text view, and edits flow to the open note, never through view state.
struct NoteEditorView: NSViewRepresentable {
    @ObservedObject var openNote: OpenNote
    @ObservedObject var controller: HybridEditorController

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NoteTextView.make()
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor
        scrollView.documentView = tv

        tv.attach(openNote.content)
        tv.onShiftTabAtStart = { [weak controller] in controller?.onShiftTabAtBodyStart?() }
        controller.textView = tv
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NoteTextView else { return }
        tv.attach(openNote.content)
        // An unreadable file keeps the view read-only; a reload that succeeded makes it editable again.
        tv.isEditable = openNote.content.isEditable
    }
}

/// Strip above the editor that explains why an open note is read-only. Empty for a readable note.
struct OpenNoteStatusView: View {
    @ObservedObject var openNote: OpenNote

    var body: some View {
        if case .unreadable(let message) = openNote.state {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.12))
                Divider()
            }
        }
    }
}
