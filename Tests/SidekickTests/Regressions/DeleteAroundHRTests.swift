import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// HR research surfaced R15/R16/R17 (delete behavior around HRs) as a test
// gap — production behavior was inferred-correct but unpinned. These tests
// lock in the CURRENT behavior so any future change to the delete logic, the
// parser, or the caret-snap surfaces a deliberate diff instead of a silent
// regression.
//
// R15 and R16 were originally written to pin the OLD two-keystroke behavior
// (first press collapsed the adjacent blank line; HR survived; second press
// merged text into the HR line and the HR vanished). They were intentionally
// INVERTED by HR-03 (requirement HR-03), which introduced
// handleThematicBreakBackspace / handleThematicBreakForwardDelete. Those
// handlers intercept the first keystroke when the caret sits on an EMPTY line
// adjacent to an HR and remove the entire HR line (plus the empty line) in
// one undo step.
//
// Current behavior pinned:
//   • R15 — Backspace from the empty line directly below an HR: ONE keystroke
//     removes the whole HR line and the empty line together; caret lands at
//     the start of where the HR was. Non-empty adjacent lines are unaffected.
//   • R16 — Forward-delete from the empty line directly above an HR: ONE
//     keystroke removes the empty line and the whole HR line together; caret
//     stays at its original position.
//   • R17 — Selection-delete spanning HR: atomic; HR and surrounding
//     newlines are removed in a single edit, no orphan blank lines (unchanged
//     from the original file — range selections with length > 0 are not
//     intercepted by the new caret-only handlers).
@MainActor
final class DeleteAroundHRTests: XCTestCase {

    /// Body: "before\n\n---\n\nafter"
    ///        b e f o r e \n \n -  -  -  \n \n a  f  t  e  r
    ///        0 1 2 3 4 5  6  7 8  9 10 11 12 13 14 15 16 17
    /// HR line "---\n" occupies chars 8..11.
    /// Empty line below HR ("\n") is char 12.
    /// Empty line above HR ("\n") is char 7.
    private let canonicalBody = "before\n\n---\n\nafter"
    private let hrLocation = 8

    // MARK: - R15: Backspace from empty line below HR (one-shot, HR-03)

    /// ONE Backspace from the start of the empty line directly below the HR
    /// removes the entire HR line AND the empty line in a single undo step.
    /// The caret lands at the start of where the HR was.
    func test_backspace_onEmptyLineBelowHR_removesWholeRule_inOneKeystroke() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 12, length: 0)  // start of empty line below HR
        )
        runner.key(.backspace)

        XCTAssertEqual(
            runner.body, "before\n\nafter",
            "One backspace from empty line below HR must remove the entire HR line and the empty line"
        )
        XCTAssertFalse(
            attributedStringHasAnyThematicBreak(runner.attributedString),
            "No thematic break attribute should remain after one-shot HR delete"
        )
        XCTAssertEqual(
            runner.selection.location, 8,
            "Caret must land at the start of where the HR was"
        )
    }

    // MARK: - R16: Forward-delete from empty line above HR (one-shot, HR-03)

    /// ONE forward-delete from the start of the empty line directly above the
    /// HR removes the empty line AND the entire HR line in a single undo step.
    /// The caret stays at its original position.
    func test_forwardDelete_onEmptyLineAboveHR_removesWholeRule_inOneKeystroke() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 7, length: 0)  // the empty line above HR
        )
        runner.key(.delete)

        XCTAssertEqual(
            runner.body, "before\n\nafter",
            "One forward-delete from empty line above HR must remove the empty line and the entire HR line"
        )
        XCTAssertFalse(
            attributedStringHasAnyThematicBreak(runner.attributedString),
            "No thematic break attribute should remain after one-shot HR delete"
        )
        XCTAssertEqual(
            runner.selection.location, 7,
            "Caret must stay at its original position after forward-delete"
        )
    }

    // MARK: - Guard: non-empty line adjacent to HR must not trigger one-shot delete

    /// Backspace from a NON-empty line adjacent to an HR must NOT trigger the
    /// one-shot handler — the handler guards that the caret's own line is empty.
    /// The `---` line survives (the caret line is non-empty so the handler
    /// declines and NSTextView's default single-char delete runs).
    func test_backspace_onNonEmptyLineAdjacentHR_doesNotRemoveWholeRule() {
        // Body "x\n---\n\nafter": caret after "x" on a non-empty line above the HR.
        let runner = HostedEditorRunner(
            initialBody: "x\n---\n\nafter",
            initialSelection: NSRange(location: 1, length: 0)
        )
        runner.key(.backspace)

        XCTAssertTrue(
            runner.body.contains("---"),
            "Non-empty caret line must NOT trigger one-shot HR delete — dashes must survive"
        )
    }

    // MARK: - R17: Selection-delete spanning HR (unchanged)

    /// A selection that spans the blank-line / HR / blank-line block
    /// removes the whole region atomically. The HR vanishes (no dashes
    /// remain) and "before" + "after" become contiguous. Confirms that
    /// the setSelectedRanges snap (length == 0 only) does not interfere
    /// with non-zero range deletes that cross the HR — companion to
    /// CaretSkipsAcrossHRTests.test_rangeSelectionAcrossHR_notSnapped.
    func test_selectionDelete_spanningHR_removesEverythingAtomically() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 0, length: 0)
        )
        // Select "\n\n---\n\n" — the entire HR block + its surrounding blanks.
        runner.select(NSRange(location: 6, length: 7))
        runner.key(.backspace)

        XCTAssertEqual(
            runner.body, "beforeafter",
            "Spanning selection-delete must remove HR and both surrounding blank lines"
        )
        XCTAssertNil(
            runner.attributedString.attribute(
                .sidekickThematicBreak,
                at: min(5, runner.attributedString.length - 1),
                effectiveRange: nil
            ),
            "No HR attribute should remain anywhere in the doc"
        )
        XCTAssertEqual(
            runner.selection.location, 6,
            "Caret lands at the deletion seam"
        )
    }

    // MARK: - Helpers

    /// Assert `.sidekickThematicBreak == true` AND `.sidekickHiddenMarker == true`
    /// on the three dash chars starting at `location`. Mirror of the helper
    /// in ThematicBreakSurvivesNoteSwitchTests (intentional duplicate so each
    /// regression file is self-contained — extracting to a shared support
    /// type is a refactor for another day).
    private func assertHRStamped(
        _ attr: NSAttributedString,
        at location: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for offset in 0..<3 {
            let idx = location + offset
            let breakVal = attr.attribute(.sidekickThematicBreak, at: idx, effectiveRange: nil) as? Bool
            XCTAssertEqual(
                breakVal, true,
                "[\(label)] `.sidekickThematicBreak` must be true at char \(idx)",
                file: file, line: line
            )
            let hiddenVal = attr.attribute(.sidekickHiddenMarker, at: idx, effectiveRange: nil) as? Bool
            XCTAssertEqual(
                hiddenVal, true,
                "[\(label)] `.sidekickHiddenMarker` must be true at char \(idx)",
                file: file, line: line
            )
        }
    }

    /// Inverse of `assertHRStamped`: the dashes at `location` must NOT carry
    /// the HR attribute (because their line no longer matches the dashes-only
    /// regex after a content merge).
    private func assertHRNotStamped(
        _ attr: NSAttributedString,
        at location: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for offset in 0..<3 {
            let idx = location + offset
            guard idx < attr.length else {
                XCTFail(
                    "[\(label)] char \(idx) out of bounds (string len \(attr.length))",
                    file: file, line: line
                )
                return
            }
            let breakVal = attr.attribute(.sidekickThematicBreak, at: idx, effectiveRange: nil) as? Bool
            XCTAssertNotEqual(
                breakVal, true,
                "[\(label)] `.sidekickThematicBreak` must NOT be true at char \(idx) (the line no longer parses as HR)",
                file: file, line: line
            )
        }
    }

    /// Returns true if ANY character in `attr` carries `.sidekickThematicBreak`.
    /// Mirrors `attributedStringHasAnyThematicBreak` in
    /// ThematicBreakSurvivesNoteSwitchTests (intentional duplicate for
    /// self-contained regression files).
    private func attributedStringHasAnyThematicBreak(_ attr: NSAttributedString) -> Bool {
        var found = false
        attr.enumerateAttribute(
            .sidekickThematicBreak,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
