import XCTest
import AppKit
@testable import Sidekick

/// Real-NSEvent mouseDown coverage for the checklist click path — the code
/// finding [6] flagged as having ZERO coverage (all prior tests drive caret
/// placement via `setSelectedRange`, bypassing `HybridTextView.mouseDown`).
/// Uses the `SyntheticMouse` harness (Support/SyntheticMouse.swift) to post a
/// real left-click through the full geometry path.
///
/// N-02 investigation (2026-07-01) landed here. The reported symptom — "click
/// on the right of a checklist line → caret jumps to the beginning" — was
/// root-caused to layout, NOT the caret snaps:
///
///   * The `- [ ] ` prefix ends in a space, the preferred wrap point. When the
///     content's first token is too long to fit beside the checkbox on row 1
///     (e.g. a ~57-char word / URL / hash at ≤400px window width), that token
///     wraps ENTIRELY to row 2, stranding the checkbox alone on row 1.
///   * A right-click in row 1's now-empty area resolves — correctly, per
///     NSTextView — to the end of that visual row, i.e. offset 6 (just after
///     the checkbox). The user reads it as "jumped to the beginning."
///   * The stated trigger (bold/italic content) does NOT reproduce: bold
///     multi-word content wraps at spaces and every row resolves correctly.
///
/// Decision (Oguz, 2026-07-01): ACCEPT / DEFER. Realistic content works; only
/// long unbreakable tokens in a narrow window strand the checkbox, and the
/// clean layout fix (break-word-if-needed) has no good TextKit 1 primitive.
/// These tests therefore lock in the WORKING behavior and characterize the
/// accepted edge case as a change-detector — if a future layout fix stops the
/// stranding, `test_strandedCheckboxRow_acceptedBehavior` will flag for update.
@MainActor
final class ClickGeometryClusterTests: XCTestCase {

    /// The synthetic mouseDown must not hang (NSTextView's drag-tracking loop
    /// is defused by queuing mouseUp first) and must land on the clicked line.
    func test_syntheticClickDoesNotHang() {
        let runner = HostedEditorRunner(initialBody: "hello\nworld",
                                        initialSelection: NSRange(location: 0, length: 0))
        runner.click(atTextPoint: runner.rightEdgePoint(ofCharAt: 8))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 6,
                                    "click should land on the 'world' line, not snap back")
    }

    /// WORKING case: a bold checklist item whose multi-word content wraps at
    /// spaces across several rows. A right-edge click on the FIRST row must land
    /// in that row's visible text (well past the 6-char prefix) — i.e. the
    /// checkbox is NOT stranded and the caret does not jump to content start.
    func test_wrappingBoldChecklist_firstRowKeepsText() {
        let body = "- [ ] **alpha beta gamma delta epsilon zeta eta theta iota kappa**\nnext"
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0),
            windowSize: CGSize(width: 240, height: 400)   // narrow → forces wrap
        )
        let row0 = firstRowCharRange(runner)
        XCTAssertGreaterThan(row0.length, 6,
                             "row 1 should carry visible words beside the checkbox, not the prefix alone")

        // Click far to the right of row 1; caret should land at row 1's trailing
        // boundary — inside the visible text, NOT back at content start (6).
        runner.inner.textView.setSelectedRange(NSRange(location: (runner.inner.storage.string as NSString).length, length: 0))
        runner.click(atTextPoint: rightEdgePointOfRow(runner, glyphAt: 0))
        XCTAssertEqual(runner.selection.location, row0.location + row0.length,
                       "right-click on row 1 should land at the end of row 1's text")
        XCTAssertGreaterThan(runner.selection.location, 6,
                             "caret must not jump back to content start (the N-02 symptom)")
    }

    /// ACCEPTED edge case (N-02, deferred): a checklist item whose sole content
    /// is a token too long to share row 1 with the checkbox. Row 1 holds only
    /// the 6-char prefix, and a right-click there resolves to offset 6. This
    /// asserts the CURRENT accepted behavior; a future layout fix that stops the
    /// stranding should update this test rather than silently regress it.
    func test_strandedCheckboxRow_acceptedBehavior() {
        let body = "- [ ] testtesttesfdksalfldskjafdsfadfdsfdasfdsafdsafdasdfsadsfads\nnext"
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0),
            windowSize: CGSize(width: 400, height: 400)   // production min width
        )
        let row0 = firstRowCharRange(runner)
        XCTAssertEqual(row0.length, 6,
                       "precondition: the long token strands the checkbox alone on row 1")

        runner.inner.textView.setSelectedRange(NSRange(location: (runner.inner.storage.string as NSString).length, length: 0))
        runner.click(atTextPoint: rightEdgePointOfRow(runner, glyphAt: 0))
        XCTAssertEqual(runner.selection.location, 6,
                       "accepted: right-click on a checkbox-only row 1 resolves to content start")
    }

    // MARK: - Helpers

    /// Character range of the first visual line fragment (row 1) of the document.
    private func firstRowCharRange(_ runner: HostedEditorRunner) -> NSRange {
        let lm = runner.inner.layoutManager
        var eff = NSRange()
        _ = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: &eff)
        return lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
    }

    /// A text-container point 40pt past the right edge of the fragment that
    /// contains `glyphAt`, vertically centered.
    private func rightEdgePointOfRow(_ runner: HostedEditorRunner, glyphAt: Int) -> NSPoint {
        let frag = runner.inner.layoutManager.lineFragmentRect(forGlyphAt: glyphAt, effectiveRange: nil)
        return NSPoint(x: frag.maxX + 40, y: frag.midY)
    }
}
