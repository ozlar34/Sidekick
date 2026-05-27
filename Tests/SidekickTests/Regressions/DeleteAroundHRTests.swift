import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// HR research surfaced R15/R16/R17 (delete behavior around HRs) as a test
// gap — production behavior was inferred-correct but unpinned. These tests
// lock in the current behavior so any future change to atomic-delete logic,
// the parser, or the caret-snap surfaces a deliberate diff instead of a
// silent regression.
//
// Current behavior pinned:
//   • Backspace from the line immediately after HR (R15) — first press
//     collapses the blank line below the HR; HR survives. Second press
//     merges "after" content into the HR line; HR vanishes (line no longer
//     matches the dashes-only regex).
//   • Forward-delete from the line immediately before HR (R16) — symmetric
//     with R15: first press collapses the blank above; HR survives. Second
//     press merges "before" into the HR line; HR vanishes.
//   • Selection-delete spanning HR (R17) — atomic; HR and surrounding
//     newlines are removed in a single edit, no orphan blank lines.
//
// All three rules fall out of NSTextView's default delete behavior + the
// storage reparse; there is no HR-specific delete handler. If we ever add
// one (e.g. "Backspace adjacent to HR deletes the whole HR line atomically"),
// these tests will fail and force the new behavior to be documented.
@MainActor
final class DeleteAroundHRTests: XCTestCase {

    /// Body: "before\n\n---\n\nafter"
    ///        b e f o r e \n \n -  -  -  \n \n a  f  t  e  r
    ///        0 1 2 3 4 5  6  7 8  9 10 11 12 13 14 15 16 17
    /// HR is at chars 8..10 (3 dashes).
    private let canonicalBody = "before\n\n---\n\nafter"
    private let hrLocation = 8

    // MARK: - R15: Backspace from line after HR

    /// First Backspace from start of "after" deletes the leading `\n` of
    /// "after"'s line, collapsing the blank line between HR and "after".
    /// The HR line itself is untouched, so the dashes-only regex still
    /// matches and the HR attribute remains stamped.
    func test_backspace_fromStartOfLineAfterHR_collapsesBlankBelow_hrSurvives() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 13, length: 0)  // start of "after"
        )
        runner.key(.backspace)

        XCTAssertEqual(
            runner.body, "before\n\n---\nafter",
            "First backspace must collapse the blank line below HR but leave the `---` line intact"
        )
        assertHRStamped(runner.attributedString, at: hrLocation,
                        label: "after first backspace")
        XCTAssertEqual(
            runner.selection.location, 12,
            "Caret shifts left by one to follow the deleted char"
        )
    }

    /// Two Backspaces from start of "after": the second one deletes the
    /// `\n` between HR and "after", merging "after" into the HR line.
    /// `---after` no longer matches the dashes-only regex, so reparse strips
    /// the HR attribute. Locks in the parser reparse path; if a future
    /// change ever protects HR boundaries from cross-line deletes, this
    /// test fails and forces the new behavior to be deliberate.
    func test_backspaceTwice_fromStartOfLineAfterHR_mergesIntoHRLine_hrVanishes() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 13, length: 0)
        )
        runner.key(.backspace)
        runner.key(.backspace)

        XCTAssertEqual(
            runner.body, "before\n\n---after",
            "Second backspace must merge `after` into the HR line"
        )
        assertHRNotStamped(runner.attributedString, at: hrLocation,
                           label: "after second backspace")
        XCTAssertEqual(
            runner.selection.location, 11,
            "Caret sits at the merge point between dashes and `after`"
        )
    }

    // MARK: - R16: Forward-delete from line before HR

    /// First forward-delete from end of "before" deletes the trailing `\n`
    /// of "before"'s line, collapsing the blank line between "before" and HR.
    /// The HR line itself is untouched, so the dashes-only regex still
    /// matches and the HR attribute remains stamped (now at chars 7..9).
    func test_forwardDelete_fromEndOfLineBeforeHR_collapsesBlankAbove_hrSurvives() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 6, length: 0)  // end of "before"
        )
        runner.key(.delete)

        XCTAssertEqual(
            runner.body, "before\n---\n\nafter",
            "First forward-delete must collapse the blank line above HR"
        )
        // After the delete the dashes shift down by one: 8..10 → 7..9.
        assertHRStamped(runner.attributedString, at: 7,
                        label: "after first forward-delete")
        XCTAssertEqual(
            runner.selection.location, 6,
            "Caret stays at end of `before` — forward-delete consumes ahead, not behind"
        )
    }

    /// Two forward-deletes from end of "before": the second one deletes the
    /// `\n` between "before" and HR, merging "before" into the HR line.
    /// `before---` no longer matches the dashes-only regex, so reparse
    /// strips the HR attribute.
    func test_forwardDeleteTwice_fromEndOfLineBeforeHR_mergesIntoHRLine_hrVanishes() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 6, length: 0)
        )
        runner.key(.delete)
        runner.key(.delete)

        XCTAssertEqual(
            runner.body, "before---\n\nafter",
            "Second forward-delete must merge `before` into the HR line"
        )
        // Dashes now sit at chars 6..8 inside "before---".
        assertHRNotStamped(runner.attributedString, at: 6,
                           label: "after second forward-delete")
        XCTAssertEqual(
            runner.selection.location, 6,
            "Caret stays at the merge point between `before` and dashes"
        )
    }

    // MARK: - R17: Selection-delete spanning HR

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
}
