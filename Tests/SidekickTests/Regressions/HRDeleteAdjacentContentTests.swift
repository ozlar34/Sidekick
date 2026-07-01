import XCTest
import AppKit
@testable import Sidekick

// N-01 (Oguz, 2026-07-01, live testing of 707b8ee): pressing Backspace at the
// start of a CONTENT line directly below a horizontal rule revealed the raw
// `---` (default merge) instead of deleting the rule. Root: the HR delete
// handlers only fired when the caret's own line was EMPTY. These now also fire
// on a content line adjacent to the rule — one keystroke deletes the whole HR
// and keeps the content line ("A\n---\nB" -> "A\nB"); a second Backspace then
// merges the two paragraphs the normal way. Forward-delete mirrors it.
@MainActor
final class HRDeleteAdjacentContentTests: XCTestCase {

    // MARK: - Backspace from the content line BELOW the rule

    /// Precondition + core case: `---` between two content lines parses as an HR,
    /// and Backspace at the start of the line below deletes only the rule.
    func test_backspace_startOfContentLineBelowHR_deletesRuleOnly() {
        let runner = KeystrokeRunner(
            initialBody: "A\n---\nB",
            initialSelection: NSRange(location: 6, length: 0)  // start of "B"
        )
        // Precondition: the middle line really is a rendered thematic break.
        XCTAssertNotNil(
            runner.storage.attribute(.sidekickThematicBreak, at: 2, effectiveRange: nil),
            "`---` between content lines must render as an HR for this case to apply"
        )
        runner.key(.backspace)
        runner.assertBody("A\nB")
        runner.assertSelection(NSRange(location: 2, length: 0))  // start of "B", risen to line 2
    }

    /// A SECOND Backspace then merges the two paragraphs normally (atomic-object
    /// model: first press eats the divider, second joins).
    func test_backspace_twice_deletesRuleThenMerges() {
        let runner = KeystrokeRunner(
            initialBody: "A\n---\nB",
            initialSelection: NSRange(location: 6, length: 0)
        )
        runner.key(.backspace)   // -> "A\nB", caret 2
        runner.key(.backspace)   // -> "AB", caret 1
        runner.assertBody("AB")
        runner.assertSelection(NSRange(location: 1, length: 0))
    }

    /// Preserved existing behavior: an EMPTY line below the rule collapses BOTH
    /// the rule and the empty line.
    func test_backspace_emptyLineBelowHR_collapsesRuleAndEmptyLine() {
        let runner = KeystrokeRunner(
            initialBody: "A\n---\n",           // trailing empty line below the rule
            initialSelection: NSRange(location: 6, length: 0)  // the empty line
        )
        runner.key(.backspace)
        runner.assertBody("A\n")
        runner.assertSelection(NSRange(location: 2, length: 0))
    }

    /// HR at document start (no line above): Backspace from the line below still
    /// deletes the rule.
    func test_backspace_hrAtDocStart_deletesRule() {
        let runner = KeystrokeRunner(
            initialBody: "---\nB",
            initialSelection: NSRange(location: 4, length: 0)  // start of "B"
        )
        runner.key(.backspace)
        runner.assertBody("B")
        runner.assertSelection(NSRange(location: 0, length: 0))
    }

    /// Mid-line Backspace (not at line start) stays a normal character delete —
    /// the HR handler must not fire.
    func test_backspace_midContentLineBelowHR_normalDelete() {
        let runner = KeystrokeRunner(
            initialBody: "A\n---\nBC",
            initialSelection: NSRange(location: 8, length: 0)  // after "C", end of "BC"
        )
        runner.key(.backspace)
        runner.assertBody("A\n---\nB")  // deleted 'C', rule untouched
        runner.assertSelection(NSRange(location: 7, length: 0))
    }

    // MARK: - Forward-delete from the content line ABOVE the rule (mirror)

    /// fn+Delete at the END of the content line above the rule deletes only the
    /// rule; the caret stays put.
    func test_forwardDelete_endOfContentLineAboveHR_deletesRuleOnly() {
        let runner = KeystrokeRunner(
            initialBody: "A\n---\nB",
            initialSelection: NSRange(location: 1, length: 0)  // end of "A"
        )
        runner.key(.delete)
        runner.assertBody("A\nB")
        runner.assertSelection(NSRange(location: 1, length: 0))  // unchanged
    }

    /// HR at document end (no line below): fn+Delete from the line above deletes
    /// the rule.
    func test_forwardDelete_hrAtDocEnd_deletesRule() {
        let runner = KeystrokeRunner(
            initialBody: "A\n---",
            initialSelection: NSRange(location: 1, length: 0)  // end of "A"
        )
        runner.key(.delete)
        runner.assertBody("A\n")
        runner.assertSelection(NSRange(location: 1, length: 0))
    }

    /// Mid-line forward-delete (not at line end) stays a normal character delete.
    func test_forwardDelete_midContentLineAboveHR_normalDelete() {
        let runner = KeystrokeRunner(
            initialBody: "AB\n---\nC",
            initialSelection: NSRange(location: 0, length: 0)  // before "A"
        )
        runner.key(.delete)
        runner.assertBody("B\n---\nC")  // deleted 'A', rule untouched
        runner.assertSelection(NSRange(location: 0, length: 0))
    }
}
