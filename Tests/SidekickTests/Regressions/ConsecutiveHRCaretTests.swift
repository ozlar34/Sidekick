import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// HR keystroke probe (2026-09-02): with two dividers back to back
// (`a\n---\n---\nb`), Right from the end of `a` landed the caret ON the second
// divider line (the HR rescue stepped exactly one line and did not re-check
// the neighbor), the next Right snapped BACKWARD to after `a`, and Backspace
// then deleted `a` instead of acting on a divider. Adjacent HR lines must be
// treated as one uninhabitable block.
@MainActor
final class ConsecutiveHRCaretTests: XCTestCase {

    private let body = "a\n---\n---\nb"   // a=0 ⏎=1 ---=2..4 ⏎=5 ---=6..8 ⏎=9 b=10

    func test_rightFromAbove_skipsBothDividers() {
        let r = KeystrokeRunner(initialBody: body, initialSelection: NSRange(location: 1, length: 0))
        r.key(.right)
        r.assertSelection(NSRange(location: 10, length: 0))
        r.key(.right)
        r.assertSelection(NSRange(location: 11, length: 0))
    }

    func test_leftFromBelow_skipsBothDividers() {
        let r = KeystrokeRunner(initialBody: body, initialSelection: NSRange(location: 10, length: 0))
        r.key(.left)
        r.assertSelection(NSRange(location: 1, length: 0))
    }

    func test_clickRelocation_bottomHalfOfFirstDivider_goesBelowRun() {
        let r = KeystrokeRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        let tv = r.textView as! HybridTextView
        XCTAssertEqual(tv.hrCaretRelocationTarget(caret: 3, clickInBottomHalf: true), 10)
        XCTAssertEqual(tv.hrCaretRelocationTarget(caret: 7, clickInBottomHalf: false), 1)
    }

    func test_threeDividers_stillOneBlock() {
        let r = KeystrokeRunner(initialBody: "a\n---\n***\n___\nb", initialSelection: NSRange(location: 1, length: 0))
        r.key(.right)
        r.assertSelection(NSRange(location: 14, length: 0))
        r.key(.left)
        r.assertSelection(NSRange(location: 1, length: 0))
    }
}
