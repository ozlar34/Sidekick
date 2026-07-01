import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// User-reported bug: typing right next to a task-list checkbox broke the box,
// and pressing Enter from that spot made no new box. Root cause — the `- [ ] `
// prefix is a 6-char atomic block, but the caret could rest in its interior
// "gap" (offsets 1…5). From the gap, typed characters landed inside the
// checkbox syntax and `handleChecklistReturn` (which only continues from
// content start, line+6) declined, so Enter fell through to a plain newline.
//
// Fix — `HybridTextView.snapCaretOutOfChecklistGap` treats the prefix as
// atomic: a zero-length caret landing in the gap snaps to content start (line+6)
// when moving forward, or to line start (line+0) when moving backward. This
// removes the trap AND restores Enter-continuation (the caret is always at
// content start by the time Enter is pressed).
//
// Layer 4 (HostedEditorRunner) because the snap lives on HybridTextView's
// setSelectedRanges override — a plain NSTextView stack would bypass it, and a
// window is needed for the checklist marker attribute to be laid out.
@MainActor
final class ChecklistGapCaretTrapTests: XCTestCase {

    // Body "- [ ] task": prefix "- [ ] " = offsets 0…5, content "task" = 6…9.

    /// Forward motion into the gap (from line start) snaps to content start.
    /// Pre-fix: the caret stayed put in the gap (offset 5).
    func test_forwardIntoGap_snapsToContentStart() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 5, length: 0))   // forward from 0
        XCTAssertEqual(
            tv.selectedRange().location, 6,
            "Caret moving forward into the checkbox prefix gap must snap to content start (6)"
        )
    }

    /// A hidden interior offset (inside the ` [ ]` run) also snaps forward.
    func test_forwardIntoHiddenInterior_snapsToContentStart() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 3, length: 0))   // forward from 0
        XCTAssertEqual(tv.selectedRange().location, 6)
    }

    /// Backward motion into the gap (from content start) snaps to line start.
    func test_backwardIntoGap_snapsToLineStart() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 6, length: 0)  // content start (no snap)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 3, length: 0))   // backward from 6
        XCTAssertEqual(
            tv.selectedRange().location, 0,
            "Caret moving backward into the checkbox prefix gap must snap to line start (0)"
        )
    }

    /// Content start (line+6) is a valid resting spot — never snapped.
    func test_contentStart_notSnapped() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 6, "Content start must remain inhabitable")
    }

    /// Line start (line+0, before the checkbox) is a valid resting spot.
    func test_lineStart_notSnapped() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 6, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 0, "Line start must remain inhabitable")
    }

    /// The headline symptom: pressing Enter from the gap must now continue the
    /// list. The gap snap lands the caret at content start (6) first, so
    /// `handleChecklistReturn` fires and inserts a fresh `- [ ] ` box.
    /// Pre-fix: caret stuck at 5 → Enter produced a plain "- [ ]\n task".
    func test_enterFromGap_continuesList() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 5, length: 0))   // snaps to 6
        XCTAssertEqual(tv.selectedRange().location, 6, "Precondition: gap snap moved caret to content start")

        runner.key(.enter)
        XCTAssertEqual(
            runner.body, "- [ ] \n- [ ] task",
            "Enter from the (snapped) checkbox line must continue the list with a fresh `- [ ] ` box"
        )
        XCTAssertEqual(
            runner.selection.location, 13,
            "Caret must land at the content start of the new checkbox line"
        )
    }

    /// Sanity anchor: a genuine task-list line carries the marker at line start,
    /// which is what arms the gap trap.
    func test_renderedCheckbox_carriesMarker() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let marker = runner.inner.storage.attribute(
            .sidekickChecklistMarker, at: 0, effectiveRange: nil
        )
        XCTAssertNotNil(marker, "Precondition: rendered task list carries the checklist marker at line start")
    }

    /// The negative case: a plain paragraph carries no `.sidekickChecklistMarker`,
    /// so the gap snap must NOT fire — offsets 1…5 stay freely inhabitable. This
    /// exercises the attribute gate directly: deleting the marker check from
    /// `snapCaretOutOfChecklistGap` would trap the caret on ANY line here, and
    /// this assertion turns red. (Plain text, not a fenced block: inside a fence
    /// the `- [ ] ` still parses and renders a checkbox — marker present, snap
    /// fires — so a fence is not a marker-free line.)
    func test_plainLine_gapNotSnapped() {
        let runner = HostedEditorRunner(
            initialBody: "hello world",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        // Precondition: no checklist marker on this ordinary line.
        XCTAssertNil(
            runner.inner.storage.attribute(.sidekickChecklistMarker, at: 0, effectiveRange: nil),
            "Precondition: a plain paragraph must not carry a checklist marker"
        )
        tv.setSelectedRange(NSRange(location: 3, length: 0))   // an interior offset in the 1…5 range
        XCTAssertEqual(
            tv.selectedRange().location, 3,
            "Without a checklist marker the gap snap must not fire — the caret stays where it landed"
        )
    }

    // MARK: - Click-path decision ([4], via checklistGapRelocationTarget)
    //
    // The keyboard `snapCaretOutOfChecklistGap` picks its side from the stale
    // `previous` — meaningless for a mouse click. The click path instead calls
    // `checklistGapRelocationTarget`, which always returns content start: the gap
    // sits entirely RIGHT of the checkbox, so a click that resolved into it is a
    // click "into" the item (a click left of the box resolves to offset 0 and
    // never enters the gap). The full click geometry (which glyph a gap click
    // resolves to) is verified live — a synthetic mid-line on-glyph click can't
    // produce a zero-length caret in this harness — so only the decision is
    // unit-tested here, mirroring `DividerClickCaretLeakTests`.

    /// Every interior gap offset (1…5) resolves to content start on a click.
    func test_clickTarget_gapOffsets_goToContentStart() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        for caret in 1...5 {
            XCTAssertEqual(
                tv.checklistGapRelocationTarget(caret: caret), 6,
                "A click resolving to gap offset \(caret) must relocate to content start (6)"
            )
        }
    }

    /// Line start (before the checkbox) and content start are both valid resting
    /// spots — a click there is never relocated.
    func test_clickTarget_edges_notRelocated() {
        let runner = HostedEditorRunner(
            initialBody: "- [ ] task",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertNil(tv.checklistGapRelocationTarget(caret: 0), "line start is inhabitable")
        XCTAssertNil(tv.checklistGapRelocationTarget(caret: 6), "content start is inhabitable")
        XCTAssertNil(tv.checklistGapRelocationTarget(caret: 8), "a click in the content is left alone")
    }

    /// A plain paragraph (no rendered checkbox) is never relocated, even at an
    /// offset that would be "in the gap" of a real checklist prefix.
    func test_clickTarget_plainLine_notRelocated() {
        let runner = HostedEditorRunner(
            initialBody: "hello world",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertNil(
            tv.checklistGapRelocationTarget(caret: 3),
            "Without a checklist marker the click rescue must not fire"
        )
    }
}
