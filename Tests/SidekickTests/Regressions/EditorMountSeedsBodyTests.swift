import XCTest
import AppKit
import SwiftUI
@testable import Sidekick

// Why this file lives in Regressions/:
// User-reported bug: on launch, the first note the panel opens on renders an
// EMPTY body (title shows, text area blank). Switching to another note and
// back makes the body appear. Reproduced with the DebugHarness on 2026-09-02:
// the selected note held 153 chars, the mounted NSTextView held 0.
//
// Mechanism: `EditorPaneView` seeds `localBody` from `note.body` in
// `.onAppear`, but the child `HybridEditorView.makeNSView` can run FIRST with
// the still-empty `localBody`. The follow-up `updateNSView` then sees text
// "" → note.body with an UNCHANGED `externalPushToken`, classifies it as a
// reflexive echo of typing, and drops it (EDIT-02 guard). The `.onChange(of:
// note.id)` path bumps the token, which is why a note switch heals it.
//
// This test mounts the real `EditorPaneView` in an `NSHostingView` inside a
// window — the production composition — and asserts the hosted NSTextView
// holds the note body after the first layout pass.
@MainActor
final class EditorMountSeedsBodyTests: XCTestCase {

    func test_freshMount_seedsEditorWithNoteBody() throws {
        let body = "# Heading one\nSome body text that must be visible on first mount."
        let note = Note(id: UUID(), filename: "a.md", title: "Heading one", body: body,
                        pinned: false, order: 0, modified: Date(), createdAt: Date())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorMountSeedsBodyTests-\(UUID().uuidString)")
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

        // Let SwiftUI mount, run onAppear, and flush the follow-up update pass.
        let deadline = Date().addingTimeInterval(2.0)
        var tv: NSTextView?
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
            tv = Self.findTextView(in: hosting)
            if let tv, tv.string == body { break }
        }

        let textView = try XCTUnwrap(tv, "EditorPaneView should mount an NSTextView")
        XCTAssertEqual(textView.string, body,
                       "freshly mounted editor must show the selected note's body, not an empty buffer")
    }

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }
}
