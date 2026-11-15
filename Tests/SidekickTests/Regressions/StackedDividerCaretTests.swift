import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// A4 (right-arrow probe, bug-hunt P2): in a note that is only dividers
// ("---", "---\n---\n---") the HR rescue has no line above or below to send
// the caret to, so it returned `nil` and AppKit's own stepping ran over the
// zero-width divider glyphs. From inside a divider it moved AGAINST the key
// (caret 1: Right → 0, Left → 7), and typing at any stop edited a divider
// ("---X").
//
// Rule (Oguz, A4): a caret that sits on a divider leaves the divider block in
// the key's direction. Right/Down with no line below append one (the A3 rule);
// Left/Up with no line above leave the caret where it is.
//
// Layer 4 (HostedEditorRunner): the thematic-break attribute needs real layout,
// and the tests dispatch real arrow keys.
@MainActor
final class StackedDividerCaretTests: XCTestCase {

    /// Headline: Right from inside an all-divider note goes below it, never back.
    func test_right_insideAllDividerNote_goesBelowIt() {
        let runner = HostedEditorRunner(initialBody: "---\n---\n---", initialSelection: NSRange(location: 1, length: 0))
        runner.key(.right)
        runner.assertBody("---\n---\n---\n")
        runner.assertSelection(NSRange(location: 12, length: 0))
    }

    /// Left from inside an all-divider note has nowhere to go: it stays.
    func test_left_insideAllDividerNote_staysPut() {
        let runner = HostedEditorRunner(initialBody: "---\n---\n---", initialSelection: NSRange(location: 5, length: 0))
        runner.key(.left)
        runner.assertBody("---\n---\n---")
        runner.assertSelection(NSRange(location: 5, length: 0))
    }

    /// Every start inside the note: no arrow key moves against its direction.
    func test_noArrowMovesAgainstItsKey_inAllDividerNote() {
        let body = "---\n---\n---"
        for start in 0...(body as NSString).length {
            let right = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
            right.key(.right)
            XCTAssertGreaterThanOrEqual(right.selection.location, start, "Right from \(start)")
            let left = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
            left.key(.left)
            XCTAssertLessThanOrEqual(left.selection.location, start, "Left from \(start)")
        }
    }

    /// Typing after the escape lands below the dividers; all three stay dividers.
    func test_right_thenType_keepsDividersIntact() {
        let runner = HostedEditorRunner(initialBody: "---\n---\n---", initialSelection: NSRange(location: 0, length: 0))
        runner.key(.right)
        runner.type("X")
        runner.assertBody("---\n---\n---\nX")
    }

    /// A single divider at the end of the note: Right escapes below it.
    func test_right_atEndOfSingleDividerNote_goesBelowIt() {
        let runner = HostedEditorRunner(initialBody: "---", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.assertBody("---\n")
        runner.assertSelection(NSRange(location: 4, length: 0))
    }

    /// Down behaves like Right; Up behaves like Left.
    func test_downEscapes_upStays_inAllDividerNote() {
        let down = HostedEditorRunner(initialBody: "---\n---", initialSelection: NSRange(location: 0, length: 0))
        down.key(.down)
        down.assertBody("---\n---\n")
        down.assertSelection(NSRange(location: 8, length: 0))
        let up = HostedEditorRunner(initialBody: "---\n---", initialSelection: NSRange(location: 5, length: 0))
        up.key(.up)
        up.assertBody("---\n---")
        up.assertSelection(NSRange(location: 5, length: 0))
    }

    /// Dividers that end in a newline: Right lands on the existing empty last line.
    func test_right_terminatedAllDividerNote_landsOnLastLine() {
        let runner = HostedEditorRunner(initialBody: "---\n---\n", initialSelection: NSRange(location: 1, length: 0))
        runner.key(.right)
        runner.assertBody("---\n---\n")
        runner.assertSelection(NSRange(location: 8, length: 0))
    }

    /// Each blank line between dividers is its own stop, both directions.
    func test_blankLinesBetweenDividers_areStopsBothWays() {
        let runner = HostedEditorRunner(initialBody: "---\n\n---\n\n---\n", initialSelection: NSRange(location: 4, length: 0))
        var right: [Int] = []
        for _ in 0..<2 {
            runner.key(.right)
            right.append(runner.selection.location)
        }
        XCTAssertEqual(right, [9, 14])
        var left: [Int] = []
        for _ in 0..<3 {
            runner.key(.left)
            left.append(runner.selection.location)
        }
        XCTAssertEqual(left, [9, 4, 4])
        runner.assertBody("---\n\n---\n\n---\n")
    }

    /// Guard: a divider with text on both sides keeps the one-press crossing.
    func test_dividerBetweenText_unchanged() {
        let runner = HostedEditorRunner(initialBody: "one\n---\ntwo", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: 8, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: 3, length: 0))
        runner.assertBody("one\n---\ntwo")
    }
}
