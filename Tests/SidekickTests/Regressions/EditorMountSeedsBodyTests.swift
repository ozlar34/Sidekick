import XCTest
import AppKit
import SwiftUI
@testable import Sidekick

// User-reported bug (2026-09-02): on launch, the first note the panel opens on rendered an EMPTY body (title shown,
// text area blank); switching to another note and back made the body appear. The old editor was seeded from view
// state that the first update pass could drop. The editor view now attaches the open note's own content, so this
// test pins the production composition: the real `EditorPaneView` in an `NSHostingView` in a window shows the
// selected note's text after the first layout pass.
@MainActor
final class EditorMountSeedsBodyTests: XCTestCase {

    func test_freshMount_showsTheNoteText() throws {
        let body = "# Heading one\nSome body text that must be visible on first mount."
        let note = Note(id: UUID(), filename: "a.md", title: "Heading one", body: body,
                        pinned: false, order: 0, modified: Date(), createdAt: Date())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorMountSeedsBodyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: folder.appendingPathComponent(note.filename))   // the open note reads its file
        let store = try NoteStore(folder: folder, seededNotes: [note])
        defer { try? FileManager.default.removeItem(at: folder) }
        let panelState = PanelState()
        panelState.selectedNoteID = note.id

        let root = EditorPaneView(store: store, panelState: panelState, note: note,
                                  selectedID: .constant(note.id))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // The editor shows the text without markers: the heading is a block kind, not a `# `.
        let shown = "Heading one\nSome body text that must be visible on first mount."
        let deadline = Date().addingTimeInterval(2.0)
        var tv: NoteTextView?
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
            tv = Self.findEditor(in: hosting)
            if let tv, tv.string == shown { break }
        }

        let textView = try XCTUnwrap(tv, "EditorPaneView should mount the editor view")
        XCTAssertEqual(textView.string, shown, "freshly mounted editor must show the selected note's text, not an empty buffer")
        XCTAssertEqual(textView.blockKinds, ["h1", "p"])
    }

    private static func findEditor(in view: NSView?) -> NoteTextView? {
        guard let view else { return nil }
        if let tv = view as? NoteTextView { return tv }
        for sub in view.subviews { if let tv = findEditor(in: sub) { return tv } }
        return nil
    }
}
