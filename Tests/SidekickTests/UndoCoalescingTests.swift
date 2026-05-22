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

    // MARK: - EDIT-02 guard predicate (token-based)

    /// Test D: the `updateNSView` binding-push guard — extracted as the pure
    /// `HybridEditorView.bindingPushDecision`. Classification is by EXPLICIT
    /// PUSH TOKEN, never by string value:
    ///   - strings equal                    → noChange
    ///   - strings differ, token UNCHANGED  → reflexiveEcho (skip the replace)
    ///   - strings differ, token ADVANCED   → applyExternalPush
    ///
    /// The last case is the WR-01 false-negative — a genuine external push
    /// whose new body equals a value the user typed earlier. The old
    /// single-shot string sentinel could misclassify it; an explicit token
    /// cannot, because the push site advances the token regardless of the
    /// body's value.
    ///
    /// Note: this is the PURE-FUNCTION check. The authoritative live-path
    /// EDIT-02 regression guard is Test E
    /// (`test_liveMultiKeystroke_singleUndoStepsBackOneIncrement`) — Test D
    /// alone stayed green through the 79f0f3b single-shot-sentinel regression.
    func test_bindingPushDecision_classifiesByPushToken() {
        // No-op: binding already equals the text view string (token unchanged).
        let noChange = HybridEditorView.bindingPushDecision(
            currentString: "foo",
            incomingText: "foo",
            currentToken: 3,
            lastConsumedToken: 3
        )
        XCTAssertEqual(noChange, .noChange,
                       "Incoming text equal to the current string is a no-op")

        // Reflexive echo: strings differ but NO push token advanced — the
        // SwiftUI binding is echoing user typing back into updateNSView.
        let reflexive = HybridEditorView.bindingPushDecision(
            currentString: "bar",
            incomingText: "foo",
            currentToken: 3,
            lastConsumedToken: 3
        )
        XCTAssertEqual(reflexive, .reflexiveEcho,
                       "Strings differ with an unchanged token — a reflexive echo; skip the undo-corrupting bare-storage replace")

        // Genuine note switch: fresh content AND the push token advanced.
        let switchNote = HybridEditorView.bindingPushDecision(
            currentString: "old note body",
            incomingText: "different note body",
            currentToken: 4,
            lastConsumedToken: 3
        )
        XCTAssertEqual(switchNote, .applyExternalPush,
                       "An advanced token marks a genuine external push — apply it")

        // WR-01 false-negative, now solved by the token: a genuine external
        // push (token advanced) whose new body happens to equal a string the
        // user typed earlier. String-value comparison would mistake this for
        // an echo and drop it; the token cannot be fooled — the push site
        // advanced it regardless of the body's value.
        let collidingPush = HybridEditorView.bindingPushDecision(
            currentString: "bar",
            incomingText: "foo",           // equals a *previously* typed value
            currentToken: 4,
            lastConsumedToken: 3
        )
        XCTAssertEqual(collidingPush, .applyExternalPush,
                       "A genuine external push must apply even when its body equals a previously-typed string — the token decides, not the string value (WR-01)")
    }

    /// Test E — the authoritative live-path EDIT-02 regression guard.
    ///
    /// Drives a REAL `NSTextView` through a per-character `shouldChangeText /
    /// replaceCharacters / didChangeText` sandwich — one sandwich per keystroke,
    /// exactly what AppKit does for genuine typing — and, after each character,
    /// runs the reflexive-echo round-trip `updateNSView` performs: the binding
    /// value SwiftUI echoes back, with the push token UNCHANGED, must classify
    /// as a reflexive echo, never an external push.
    ///
    /// This is the test that would have caught the 79f0f3b single-shot-sentinel
    /// regression. The pure-function Test D only checks `bindingPushDecision`
    /// against hand-picked inputs and stayed green while the live typing path
    /// corrupted the undo stack and one Cmd+Z wiped the whole note
    /// (03-UAT.md Test 1). The assertion that a single `undo()` steps back
    /// exactly one character — not the whole body — is the real EDIT-02 check.
    func test_liveMultiKeystroke_singleUndoStepsBackOneIncrement() {
        let tv = makeTextView("", selection: NSRange(location: 0, length: 0))
        // Disable per-event coalescing so each explicit keystroke group is a
        // distinct undo step — same rationale as Test B (no real run-loop
        // event cycle in a unit test; see 03-01-SUMMARY.md "Auto-fixed Issues" #1).
        tv.undoManager?.groupsByEvent = false

        // A fixed push token, identical on both sides of every echo check:
        // a reflexive echo of user typing never advances the token.
        let token = 1
        var previousString = ""

        for ch in "hello" {
            let appendRange = NSRange(location: tv.string.utf16.count, length: 0)
            // Open the explicit group BEFORE shouldChangeText — shouldChangeText
            // registers its undo action internally and needs a valid group.
            tv.undoManager?.beginUndoGrouping()
            guard tv.shouldChangeText(in: appendRange, replacementString: String(ch)) else {
                tv.undoManager?.endUndoGrouping()
                return XCTFail("shouldChangeText must permit the keystroke")
            }
            tv.replaceCharacters(in: appendRange, with: String(ch))
            tv.didChangeText()
            tv.undoManager?.endUndoGrouping()

            // Reflexive-echo round-trip, in sync: the Coordinator pushed
            // tv.string up to the binding; SwiftUI re-runs updateNSView with
            // that echoed value. Binding equals the text view → no-op.
            let echoInSync = HybridEditorView.bindingPushDecision(
                currentString: tv.string,
                incomingText: tv.string,
                currentToken: token,
                lastConsumedToken: token
            )
            XCTAssertEqual(echoInSync, .noChange,
                           "Binding equal to the text view string is a no-op")

            // The regression window: updateNSView runs with an echo that LAGS
            // the text view by one keystroke (the binding a beat behind). The
            // token is unchanged → this MUST be a reflexive echo. The 79f0f3b
            // bug returned .applyExternalPush here once the sentinel emptied,
            // firing the undo-corrupting bare-storage replace.
            let echoLagging = HybridEditorView.bindingPushDecision(
                currentString: tv.string,
                incomingText: previousString,
                currentToken: token,
                lastConsumedToken: token
            )
            XCTAssertEqual(echoLagging, .reflexiveEcho,
                           "A lagging echo with an unchanged token is a reflexive echo — never an external push (the 79f0f3b regression)")

            previousString = tv.string
        }

        XCTAssertEqual(tv.string, "hello", "All five keystrokes must land")

        // The EDIT-02 assertion: one Cmd+Z steps back exactly ONE character,
        // NOT the whole note — the exact failure from 03-UAT.md Test 1.
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "hell",
                       "First undo must remove exactly one character — not the whole body")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "hel", "Second undo must remove exactly one character")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "he", "Third undo must remove exactly one character")

        // Redo replays the same increments forward (Cmd+Shift+Z).
        tv.undoManager?.redo()
        XCTAssertEqual(tv.string, "hel", "Redo must restore exactly one character")
    }
}
