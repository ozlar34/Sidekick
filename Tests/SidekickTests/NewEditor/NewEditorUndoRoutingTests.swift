import AppKit
import XCTest
@testable import Sidekick

/// ⌘Z and Edit > Undo send `undo:` to the panel, which undoes with its own undo manager. The note's undo history
/// lives in the note's undo manager (`NoteContent.undoManager`), so with the editor focused the panel must use that.
@MainActor
final class NewEditorUndoRoutingTests: XCTestCase {
    private let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

    private func endUndoGroup() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }

    func testThePanelsUndoCommandUndoesTypingInTheNote() {
        let panel = SidekickPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600))
        let tv = NoteTextView.make()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        scroll.documentView = tv
        tv.frame = scroll.bounds
        panel.contentView = scroll
        tv.load(markdown: "abc\n")
        panel.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        endUndoGroup()
        XCTAssertEqual(tv.string, "abcx\n")

        XCTAssertTrue(panel.undoManager === tv.undoManager, "the panel undoes with the note's undo manager")
        XCTAssertTrue(panel.validateUserInterfaceItem(undoItem), "Undo is enabled")
        panel.perform(Selector(("undo:")), with: nil)
        endUndoGroup()
        XCTAssertEqual(tv.string, "abc\n", "the panel's undo: reverts the typing")
        panel.contentView = nil
        panel.close()
    }
}
