import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// DebugHarness probe (2026-09-02): a DOUBLE-click in the gap just right of a
// rendered checkbox selects a single hidden prefix character (the space after
// `]`). The selection is invisible — the prefix renders as the checkbox — so
// the user sees nothing selected, and the next typed character silently
// replaces the hidden space, turning `- [ ] task` into `- [ ]Xtask` and
// un-rendering the checkbox. The single-click path is already rescued
// (`checklistGapRelocationTarget`); the multi-click path bypassed it because
// the rescue is gated on a zero-length selection.
//
// Contract pinned here: any click whose resulting selection lies entirely
// inside a checklist prefix gap collapses to a caret at content start.
@MainActor
final class ChecklistGapDoubleClickTests: XCTestCase {

    func test_doubleClickInGap_collapsesToContentStart() {
        let body = "- [ ] task open\nnext"
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: (body as NSString).length, length: 0))
        runner.click(atTextPoint: gapPoint(runner), clickCount: 2)
        XCTAssertEqual(runner.selection, NSRange(location: 6, length: 0),
                       "double-click in the checkbox gap must not select hidden prefix chars")
    }

    func test_doubleClickOnContentWord_stillSelectsWord() {
        let body = "- [ ] task open\nnext"
        let runner = HostedEditorRunner(initialBody: body,
                                        initialSelection: NSRange(location: 0, length: 0))
        let lm = runner.inner.layoutManager
        let g = lm.glyphIndexForCharacter(at: 7)   // 'a' of "task"
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let x = frag.origin.x + lm.location(forGlyphAt: g).x
        runner.click(atTextPoint: NSPoint(x: x + 1, y: frag.midY), clickCount: 2)
        XCTAssertEqual(runner.selection, NSRange(location: 6, length: 4),
                       "double-click on 'task' should still select the word")
    }

    /// A point on the checklist line between the drawn checkbox and the
    /// content start: the x where the (zero-width) hidden prefix glyphs sit.
    private func gapPoint(_ runner: HostedEditorRunner) -> NSPoint {
        let lm = runner.inner.layoutManager
        let g = lm.glyphIndexForCharacter(at: 5)   // hidden space before content
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let x = frag.origin.x + lm.location(forGlyphAt: g).x
        return NSPoint(x: x, y: frag.midY)
    }
}
