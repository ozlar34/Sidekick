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

    // MARK: - EDIT-02 / WR-01 guard predicate (IN-02)

    /// Test D: the `updateNSView` binding-push guard — extracted as the pure
    /// `HybridEditorView.bindingPushDecision` — classifies the three cases
    /// IN-02 calls out:
    ///   (a) reflexive echo                             → consume sentinel, skip
    ///   (b) genuine note switch                        → apply external push
    ///   (c) external push equal to a prior typed value → apply external push
    ///
    /// Case (c) is the WR-01 false-negative: before the single-shot fix, an
    /// external push whose value happened to equal an earlier-typed string was
    /// wrongly classified as a reflexive echo and dropped. With the sentinel
    /// cleared the moment it matches case (a), case (c) is reached with a
    /// stale/empty sentinel and correctly applies.
    func test_bindingPushDecision_classifiesEchoSwitchAndStalePush() {
        // (a) Reflexive echo: text view already shows the value the Coordinator
        // just pushed up, and the incoming binding `text` equals that sentinel.
        let echo = HybridEditorView.bindingPushDecision(
            currentString: "foo",          // editor currently shows "foo"
            incomingText: "foo",           // ... but binding agrees — no diff yet
            lastBoundText: "foo"
        )
        XCTAssertEqual(echo, .noChange,
                       "Incoming text equal to the current string is a no-op")

        // The reflexive-echo branch proper: editor moved on to "bar" via a
        // genuine push, then SwiftUI re-runs updateNSView with the echo of the
        // earlier "foo" the Coordinator pushed. textView.string ("bar") differs
        // from incoming ("foo") AND incoming equals the sentinel → consume it.
        let reflexive = HybridEditorView.bindingPushDecision(
            currentString: "bar",
            incomingText: "foo",
            lastBoundText: "foo"
        )
        XCTAssertEqual(reflexive, .reflexiveEchoConsumeSentinel,
                       "An incoming text equal to the live sentinel is a reflexive echo — skip the bare-storage replace and consume the sentinel")

        // (b) Genuine note switch: incoming text is brand-new content, unequal
        // to both the current string and the sentinel → apply.
        let switchNote = HybridEditorView.bindingPushDecision(
            currentString: "old note body",
            incomingText: "different note body",
            lastBoundText: "old note body"
        )
        XCTAssertEqual(switchNote, .applyExternalPush,
                       "A note switch to fresh content must apply the external push")

        // (c) WR-01 false-negative path: type "foo" → type "bar" → external
        // push "foo". By the time the "foo" push arrives, the sentinel has
        // already been consumed (cleared to "") by the reflexive echo of an
        // earlier push, so it is now empty. The incoming "foo" differs from the
        // current "bar" AND differs from the empty sentinel → apply, NOT drop.
        let stalePush = HybridEditorView.bindingPushDecision(
            currentString: "bar",
            incomingText: "foo",           // equals a *previously* typed value
            lastBoundText: ""              // sentinel already consumed
        )
        XCTAssertEqual(stalePush, .applyExternalPush,
                       "A genuine external push equal to a previously-typed value must apply — the single-shot sentinel must not shadow it (WR-01)")
    }
}
