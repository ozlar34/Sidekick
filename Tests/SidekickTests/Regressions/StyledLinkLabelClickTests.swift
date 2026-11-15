import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// User-reported: "caret jumps when clicking near links". DebugHarness sweep
// (2026-09-02) showed the mechanism: a plain click ANYWHERE on a styled link
// label (`[label](url)`, label carries AppKit `.link`) never moves the caret.
// NSTextView treats a mouseDown on `.link` text as a link click — it tracks to
// mouseUp, asks the delegate `clickedOnLink`, and does NOT place the caret
// even when the delegate returns false. The caret stays wherever it was, so
// the next typed character lands far from where the user clicked.
//
// Contract pinned here: a plain (non-⌘) single click on a styled-link label
// places the caret at the clicked character, exactly like plain text.
@MainActor
final class StyledLinkLabelClickTests: XCTestCase {

    private let body = "see [styled link](https://example.com) after"
    // "see [" = 5 chars, so label chars start at 5: s=5 t=6 y=7 l=8 e=9 d=10

    func test_plainClickOnLinkLabel_placesCaretAtClickedChar() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: (body as NSString).length, length: 0))
        runner.click(atTextPoint: leftEdgePoint(runner, ofCharAt: 7))
        XCTAssertEqual(runner.selection, NSRange(location: 7, length: 0),
                       "plain click on 'y' of the label should put the caret before 'y'")
    }

    func test_plainClickOnLinkLabel_rightHalf_placesCaretAfterChar() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.click(atTextPoint: rightEdgePointInside(runner, ofCharAt: 7))
        XCTAssertEqual(runner.selection, NSRange(location: 8, length: 0),
                       "plain click on the right half of 'y' should put the caret after 'y'")
    }

    func test_plainClickOnLinkLabel_replacesExistingRangeSelection() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 3))
        runner.click(atTextPoint: leftEdgePoint(runner, ofCharAt: 9))
        XCTAssertEqual(runner.selection, NSRange(location: 9, length: 0),
                       "a prior range selection must not survive a plain click on the label")
    }

    func test_doubleClickOnLinkLabel_selectsWord() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.click(atTextPoint: leftEdgePoint(runner, ofCharAt: 7), clickCount: 2)
        XCTAssertEqual(runner.selection, NSRange(location: 5, length: 6),
                       "double-click on the label should select the word 'styled'")
    }

    // ⇧-click extends the selection to the clicked char. AppKit skips that on
    // `.link` text just as it skips caret placement, so the link-label rescue
    // owns it too; without that, the rescue collapsed the click to a caret
    // (found in review, 2026-09-03).
    func test_shiftClickOnLinkLabel_extendsSelection_notCollapsed() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.click(atTextPoint: leftEdgePoint(runner, ofCharAt: 9), modifierFlags: [.shift])
        XCTAssertEqual(runner.selection, NSRange(location: 0, length: 9),
                       "shift-click on the label should extend the selection 0..<9, not collapse to a caret")
    }

    // A drag that starts on the label must produce a normal text selection.
    // AppKit treats a mouseDown on `.link` text as a link drag (never a text
    // selection), so the rescue collapsed it to a caret at the mouseDown point
    // (found in live verification, 2026-09-03).
    func test_dragFromLinkLabel_selectsRange_notCaret() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.drag(fromTextPoint: leftEdgePoint(runner, ofCharAt: 7),
                    toTextPoint: leftEdgePoint(runner, ofCharAt: 10))
        XCTAssertEqual(runner.selection, NSRange(location: 7, length: 3),
                       "drag from 'y' to 'd' on the label should select 7..<10 like plain text")
    }

    // Same drag, but ending past the label on plain text.
    func test_dragFromLinkLabel_intoPlainText_selectsRange() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 0))
        let after = (body as NSString).range(of: "after").location   // plain text
        runner.drag(fromTextPoint: leftEdgePoint(runner, ofCharAt: 5),
                    toTextPoint: leftEdgePoint(runner, ofCharAt: after))
        XCTAssertEqual(runner.selection, NSRange(location: 5, length: after - 5),
                       "drag from the label start into plain text should select up to the drop point")
    }

    // Drag from plain text INTO the label goes through AppKit's normal path;
    // pinned so the link-label rescue never regresses it.
    func test_dragFromPlainTextIntoLabel_selectsRange() {
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.drag(fromTextPoint: leftEdgePoint(runner, ofCharAt: 1),
                    toTextPoint: leftEdgePoint(runner, ofCharAt: 8))
        XCTAssertEqual(runner.selection, NSRange(location: 1, length: 7))
    }

    // MARK: - Geometry helpers

    private func leftEdgePoint(_ runner: HostedEditorRunner, ofCharAt i: Int) -> NSPoint {
        let lm = runner.inner.layoutManager
        let g = lm.glyphIndexForCharacter(at: i)
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let x = frag.origin.x + lm.location(forGlyphAt: g).x
        return NSPoint(x: x + 1, y: frag.midY)
    }

    private func rightEdgePointInside(_ runner: HostedEditorRunner, ofCharAt i: Int) -> NSPoint {
        let lm = runner.inner.layoutManager
        let g = lm.glyphIndexForCharacter(at: i)
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: runner.inner.container)
        return NSPoint(x: rect.maxX - 1, y: frag.midY)
    }
}
