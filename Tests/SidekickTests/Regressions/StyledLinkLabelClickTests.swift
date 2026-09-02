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
