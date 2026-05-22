import XCTest
import AppKit
@testable import Sidekick

/// NSTextView subclass used only in tests to supply an explicit UndoManager.
/// Windowless NSTextViews have no responder chain, so `undoManager` is nil
/// by default.
private final class TestableTextView: NSTextView {
    private let _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }
}

@MainActor
final class UndoCoalescingTests: XCTestCase {
    private func makeTextView(_ body: String, selection: NSRange) -> NSTextView {
        let tv = TestableTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.string = body
        tv.setSelectedRange(selection)
        return tv
    }

    /// Test A: an edit applied through the shouldChangeText/replaceCharacters/didChangeText
    /// sandwich registers on the undo manager, and a single undo() restores the prior string.
    func test_editSandwich_registersUndo() {
        let tv = makeTextView("abc", selection: NSRange(location: 3, length: 0))
        let range = NSRange(location: 3, length: 0)
        guard tv.shouldChangeText(in: range, replacementString: "d") else {
            return XCTFail("shouldChangeText must permit the edit")
        }
        tv.replaceCharacters(in: range, with: "d")
        tv.didChangeText()
        XCTAssertEqual(tv.string, "abcd", "Sandwich edit must mutate the string")
        XCTAssertTrue(tv.undoManager?.canUndo ?? false,
                      "Sandwich edit must register on undoManager")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "abc", "Undo must restore the pre-edit string")
    }

    /// Test B: three separate sandwich edits (each in its own undo group) can be
    /// individually stepped back via repeated undo() calls — no step skipped,
    /// no step duplicated.
    func test_repeatedUndo_stepsBackWithoutSkipping() {
        let tv = makeTextView("", selection: NSRange(location: 0, length: 0))
        // Disable per-event coalescing so each explicit group is a distinct undo step.
        // In a test there is no real run-loop event cycle, so groupsByEvent would
        // merge all edits into one group. Turning it off makes NSUndoManager respect
        // the explicit beginUndoGrouping/endUndoGrouping boundaries.
        tv.allowsUndo = true
        tv.undoManager?.groupsByEvent = false

        func append(_ s: String) {
            let r = NSRange(location: tv.string.utf16.count, length: 0)
            // Open the explicit group first so NSUndoManager is in a valid state
            // when shouldChangeText registers its undo action.
            tv.undoManager?.beginUndoGrouping()
            guard tv.shouldChangeText(in: r, replacementString: s) else {
                tv.undoManager?.endUndoGrouping()
                return XCTFail("shouldChangeText must permit the edit")
            }
            tv.replaceCharacters(in: r, with: s)
            tv.didChangeText()
            tv.undoManager?.endUndoGrouping()
        }

        append("a"); append("b"); append("c")
        XCTAssertEqual(tv.string, "abc")

        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "ab", "First undo must remove exactly one step")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "a", "Second undo must remove exactly one step")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "", "Third undo must remove exactly one step")
    }

    /// Test C: a bare storage edit (exactly what updateNSView's reflexive echo does)
    /// does NOT register on the undo manager — this documents the bug mechanism
    /// that the EDIT-02 fix prevents from firing reflexively.
    func test_bareStorageEdit_doesNotRegisterUndo() {
        let tv = makeTextView("abc", selection: NSRange(location: 0, length: 0))
        guard let storage = tv.textStorage else {
            return XCTFail("text view must have a text storage")
        }
        // A bare storage edit — exactly what updateNSView's reflexive echo does.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: "xyz")
        storage.endEditing()
        XCTAssertEqual(tv.string, "xyz", "Bare storage edit mutates the string")
        XCTAssertFalse(tv.undoManager?.canUndo ?? false,
                       "Bare storage edit must NOT register on undoManager — this is the bug mechanism the EDIT-02 fix prevents from firing reflexively")
    }
}
