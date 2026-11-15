import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// A3 (right-arrow probe): in a note that already ends in a divider with no
// line below it ("one\n---", e.g. loaded from disk), Right and Down from the
// end of "one" stayed at 3 forever. The HR rescue had no line below to land
// on, so it sent the caret back above the rule. Typing then gave "oneX\n---".
// HR-01 already guaranteed a line below a freshly-TYPED trailing divider;
// nothing did so for a divider that was already there.
//
// Fix: `moveRight`/`moveDown` call `escapeBelowTrailingHR`, which appends one
// `\n` (undo-safe, shared with HR-01 via `appendLineBelowTrailingHR`) and parks
// the caret on the new empty line below the divider.
//
// Layer 4 (HostedEditorRunner): the thematic-break attribute needs real layout,
// and the tests dispatch real arrow keys.
@MainActor
final class TrailingDividerEscapeTests: XCTestCase {

    /// Headline: one Right from the end of "one" goes below the divider.
    func test_right_fromLineAbove_goesBelowTrailingDivider() {
        let runner = HostedEditorRunner(initialBody: "one\n---", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.assertBody("one\n---\n")
        runner.assertSelection(NSRange(location: 8, length: 0))
    }

    /// Typing there continues under the divider; `---` stays a divider line.
    func test_right_thenType_landsBelowDivider() {
        let runner = HostedEditorRunner(initialBody: "one\n---", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.type("X")
        runner.assertBody("one\n---\nX")
    }

    /// Down from the line above behaves the same.
    func test_down_fromLineAbove_goesBelowTrailingDivider() {
        let runner = HostedEditorRunner(initialBody: "one\n---", initialSelection: NSRange(location: 1, length: 0))
        runner.key(.down)
        runner.assertBody("one\n---\n")
        runner.assertSelection(NSRange(location: 8, length: 0))
    }

    /// Stacked trailing dividers form one block: one Right crosses all of them.
    func test_right_crossesStackedTrailingDividers() {
        let runner = HostedEditorRunner(initialBody: "one\n---\n***", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.assertBody("one\n---\n***\n")
        runner.assertSelection(NSRange(location: 12, length: 0))
    }

    /// Left from below mirrors Right: back to the end of "one", no new text.
    func test_left_fromBelow_returnsAboveDivider() {
        let runner = HostedEditorRunner(initialBody: "one\n---", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.key(.left)
        runner.assertBody("one\n---\n")
        runner.assertSelection(NSRange(location: 3, length: 0))
    }

    /// Up from the empty line below a trailing divider crosses it in one press.
    /// Pre-fix: the n-1 clamp put the source ON the divider line, so the
    /// same-line exemption let the caret stop on the divider (8 → 7).
    func test_up_fromEmptyLineBelowDivider_returnsAboveDivider() {
        let runner = HostedEditorRunner(initialBody: "one\n---\n", initialSelection: NSRange(location: 8, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: 3, length: 0))
    }

    /// After the escape, the full Left walk is one character per press.
    func test_leftWalk_afterEscape_isOneCharacterPerPress() {
        let runner = HostedEditorRunner(initialBody: "one\n---", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        var walk: [Int] = []
        for _ in 0..<4 {
            runner.key(.left)
            walk.append(runner.selection.location)
        }
        XCTAssertEqual(walk, [3, 2, 1, 0])
    }

    /// The appended line is one undo step: undo removes it again.
    func test_escape_isUndoable() {
        let runner = HostedEditorRunner(initialBody: "one\n---", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.assertBody("one\n---\n")
        runner.inner.textView.undoManager?.undo()
        runner.assertBody("one\n---")
    }

    /// Guard: a divider that already has a line below is untouched (no text added).
    func test_right_dividerWithLineBelow_addsNothing() {
        let runner = HostedEditorRunner(initialBody: "one\n---\ntwo", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.assertBody("one\n---\ntwo")
        runner.assertSelection(NSRange(location: 8, length: 0))
    }

    /// Guard: Right from the end of a plain last line adds nothing.
    func test_right_atEndOfPlainNote_addsNothing() {
        let runner = HostedEditorRunner(initialBody: "one", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.assertBody("one")
        runner.assertSelection(NSRange(location: 3, length: 0))
    }
}
