import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// User-reported bug: clicking a horizontal-rule divider stranded the caret on
// the uninhabitable HR line — the zero-width dash glyphs made it look frozen
// (right-arrow appeared stuck while offsets advanced invisibly). The keyboard
// rescue (`snapCaretOutOfHR`) already worked, but its same-line exemption let
// the mouse path slip through: a click's intermediate `stillSelecting` pass
// parks the caret on the HR line, so the final pass sees "same line" and
// declines to snap.
//
// Fix — `HybridTextView.mouseDown` relocates the caret at the click site after
// `super.mouseDown`. The neighbor is chosen by which half of the divider was
// clicked: top → end of line above, bottom → start of line below. The
// top/bottom geometry is verified live; the neighbor DECISION is
// `hrCaretRelocationTarget`, unit-tested directly here (synthesizing a precise
// AppKit mouse-tracking loop headlessly is not feasible).
@MainActor
final class DividerClickCaretLeakTests: XCTestCase {

    // Body "abc\n---\nxyz": HR line "---\n" = offsets 4…7, end of line above = 3,
    // start of line below = 8.

    /// Top-half click on the divider relocates to the end of the line above.
    func test_topHalfClick_relocatesToLineAbove() {
        let runner = HostedEditorRunner(
            initialBody: "abc\n---\nxyz",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertEqual(
            tv.hrCaretRelocationTarget(caret: 5, clickInBottomHalf: false), 3,
            "Top-half divider click must relocate to end of the line above (3)"
        )
    }

    /// Bottom-half click on the divider relocates to the start of the line below.
    func test_bottomHalfClick_relocatesToLineBelow() {
        let runner = HostedEditorRunner(
            initialBody: "abc\n---\nxyz",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertEqual(
            tv.hrCaretRelocationTarget(caret: 6, clickInBottomHalf: true), 8,
            "Bottom-half divider click must relocate to start of the line below (8)"
        )
    }

    /// A click that resolves onto a normal (non-HR) line is never relocated.
    func test_nonHRLine_noRelocation() {
        let runner = HostedEditorRunner(
            initialBody: "abc\n---\nxyz",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertNil(
            tv.hrCaretRelocationTarget(caret: 1, clickInBottomHalf: true),
            "A click on ordinary text must not be relocated"
        )
    }

    /// HR at document start has no line above — a top-half click must still go
    /// to the only neighbor (the line below).
    func test_hrAtDocStart_topHalfGoesBelow() {
        let runner = HostedEditorRunner(
            initialBody: "---\nafter",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertEqual(
            tv.hrCaretRelocationTarget(caret: 1, clickInBottomHalf: false), 4,
            "HR at doc start has no line above — click must relocate below (4)"
        )
    }

    /// HR at document end with no trailing newline has no line below — a
    /// bottom-half click must fall back to the line above.
    func test_hrAtDocEndNoNewline_bottomHalfGoesAbove() {
        let runner = HostedEditorRunner(
            initialBody: "before\n---",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertEqual(
            tv.hrCaretRelocationTarget(caret: 8, clickInBottomHalf: true), 6,
            "HR at doc end (no newline) has no line below — click must relocate above (6)"
        )
    }

    /// HR is the entire document — no neighbor exists, so no relocation target.
    func test_hrIsEntireDoc_noRelocation() {
        let runner = HostedEditorRunner(
            initialBody: "---",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertNil(
            tv.hrCaretRelocationTarget(caret: 1, clickInBottomHalf: true),
            "Degenerate doc (HR only) has nowhere to relocate"
        )
    }

    // MARK: - Full mouseDown path ([8]/[9], via SyntheticMouse)
    //
    // The cases above unit-test the neighbor DECISION. These drive a real
    // NSEvent mouseDown through `super.mouseDown` + the keyboard `snapCaretOutOfHR`
    // + `relocateCaretOffHRAfterClick`, closing the no-mouseDown-coverage gap
    // [6] flagged for the divider fix. The invariant they lock in ([8]/[9]):
    // the CLICKED half alone picks the neighbor — top → line above (3), bottom →
    // line below (8) — regardless of where the caret sat before the click. A
    // rescue that keyed off the post-`super` caret would let the pre-click
    // position (via the keyboard snap's stale direction) leak into the result.

    /// Text-container point in the top or bottom quarter of the HR line's
    /// fragment, horizontally centered.
    private func hrHalfPoint(_ runner: HostedEditorRunner, hrCharIndex: Int, bottom: Bool) -> NSPoint {
        let lm = runner.inner.layoutManager
        let glyph = lm.glyphRange(forCharacterRange: NSRange(location: hrCharIndex, length: 0),
                                  actualCharacterRange: nil).location
        let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSPoint(x: frag.midX, y: frag.minY + frag.height * (bottom ? 0.75 : 0.25))
    }

    // Body "abc\n---\nxyz": HR dashes at offsets 4…6, HR line "---\n" = 4…7,
    // end of line above = 3, start of line below = 8.

    func test_syntheticClick_topHalf_fromAbove_goesAbove() {
        let runner = HostedEditorRunner(initialBody: "abc\n---\nxyz",
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.click(atTextPoint: hrHalfPoint(runner, hrCharIndex: 4, bottom: false))
        XCTAssertEqual(runner.selection.location, 3, "top-half click → end of line above")
    }

    func test_syntheticClick_bottomHalf_fromAbove_goesBelow() {
        let runner = HostedEditorRunner(initialBody: "abc\n---\nxyz",
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.click(atTextPoint: hrHalfPoint(runner, hrCharIndex: 4, bottom: true))
        XCTAssertEqual(runner.selection.location, 8, "bottom-half click → start of line below")
    }

    /// The discriminating [9] cases: caret starts BELOW the HR, so a rescue that
    /// inherited the keyboard snap's direction (target < previous → "above")
    /// would send a bottom-half click the wrong way. Geometry must still win.
    func test_syntheticClick_bottomHalf_fromBelow_goesBelow() {
        let runner = HostedEditorRunner(initialBody: "abc\n---\nxyz",
                                        initialSelection: NSRange(location: 11, length: 0))
        runner.click(atTextPoint: hrHalfPoint(runner, hrCharIndex: 4, bottom: true))
        XCTAssertEqual(runner.selection.location, 8, "bottom-half click → below, even coming from below")
    }

    func test_syntheticClick_topHalf_fromBelow_goesAbove() {
        let runner = HostedEditorRunner(initialBody: "abc\n---\nxyz",
                                        initialSelection: NSRange(location: 11, length: 0))
        runner.click(atTextPoint: hrHalfPoint(runner, hrCharIndex: 4, bottom: false))
        XCTAssertEqual(runner.selection.location, 3, "top-half click → above, even coming from below")
    }
}
