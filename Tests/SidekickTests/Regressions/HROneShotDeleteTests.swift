import XCTest
import AppKit
@testable import Sidekick

// TDD RED: HR-03 one-shot delete handlers.
// These tests assert the NEW one-shot behavior implemented by
// handleThematicBreakBackspace / handleThematicBreakForwardDelete.
// They are RED until Task 1 implements the handlers.
@MainActor
final class HROneShotDeleteTests: XCTestCase {

    /// Body: "before\n\n---\n\nafter"
    ///        b e f o r e \n \n -  -  -  \n \n a  f  t  e  r
    ///        0 1 2 3 4 5  6  7 8  9 10 11 12 13 14 15 16 17
    /// HR line is "---\n" at chars 8..11.
    /// The empty line BELOW the HR starts at char 12.
    private let canonicalBody = "before\n\n---\n\nafter"

    // MARK: - Backspace from empty line below HR

    func test_backspace_onEmptyLineBelowHR_removesWholeRule_inOneKeystroke() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 12, length: 0)
        )
        runner.key(.backspace)

        XCTAssertEqual(runner.body, "before\n\nafter",
                       "One backspace from empty line below HR must remove the entire HR line")
        XCTAssertFalse(attributedStringHasAnyThematicBreak(runner.attributedString),
                       "No thematic break attribute should remain after one-shot delete")
        XCTAssertEqual(runner.selection.location, 8,
                       "Caret must land at start of where the HR was")
    }

    // MARK: - Forward-delete from empty line above HR

    func test_forwardDelete_onEmptyLineAboveHR_removesWholeRule_inOneKeystroke() {
        let runner = HostedEditorRunner(
            initialBody: canonicalBody,
            initialSelection: NSRange(location: 7, length: 0)
        )
        runner.key(.delete)

        XCTAssertEqual(runner.body, "before\n\nafter",
                       "One forward-delete from empty line above HR must remove the entire HR line")
        XCTAssertFalse(attributedStringHasAnyThematicBreak(runner.attributedString),
                       "No thematic break attribute should remain after one-shot delete")
        XCTAssertEqual(runner.selection.location, 7,
                       "Caret must stay at original position after forward-delete")
    }

    // MARK: - Guard: non-empty line adjacent to HR must NOT trigger one-shot delete

    func test_backspace_onNonEmptyLineAdjacentHR_doesNotRemoveWholeRule() {
        // Body: "x\n---\n\nafter", caret after "x" (non-empty line above HR)
        let runner = HostedEditorRunner(
            initialBody: "x\n---\n\nafter",
            initialSelection: NSRange(location: 1, length: 0)
        )
        runner.key(.backspace)

        XCTAssertTrue(runner.body.contains("---"),
                      "Non-empty caret line must NOT trigger one-shot HR delete — dashes must survive")
    }

    // MARK: - Helper

    /// Returns true if ANY character in the attributed string carries
    /// `.sidekickThematicBreak == true`.
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
