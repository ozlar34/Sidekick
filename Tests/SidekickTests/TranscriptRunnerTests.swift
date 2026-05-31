import XCTest
import AppKit
@testable import Sidekick

/// Smoke tests for `KeystrokeRunner` (Layer 1 of the headless harness).
///
/// These tests prove the runner drives REAL `HybridEditorView.Coordinator`
/// routing — not direct storage mutation — by exercising the same delegate
/// paths AppKit hits at runtime. If the runner regresses to direct storage
/// pokes, the thematic-break smoke will stop reflecting the production
/// `handleThematicBreakReturn` end-state.
@MainActor
final class TranscriptRunnerTests: XCTestCase {

    /// Typing `---` then Enter must exercise the HR paths via the real
    /// Coordinator.
    ///
    /// With HR-01 (plan 04-04), typing `---` as the final line of an empty
    /// doc now triggers `escapeTypedTrailingHRIfNeeded`, which appends a
    /// trailing `\n` and parks the caret at offset 4 (the empty editable line
    /// below the rule). Subsequent Enter from that position is a normal
    /// newline on a non-HR line — body becomes "---\n\n", caret at 5.
    ///
    /// Pinning the exact bytes is what makes this test load-bearing: any
    /// drift in the typed-trailing escape or in the runner's command dispatch
    /// will move these numbers.
    func test_smoke_threeDashesPlusEnter_insertsThematicBreakAndMovesCaretUp() {
        let runner = KeystrokeRunner(initialBody: "",
                                     initialSelection: NSRange(location: 0, length: 0))
        runner.type("---")
        // HR-01: trailing rule gets an editable line appended below it.
        XCTAssertEqual(runner.body, "---\n",
                       "Three typed trailing dashes must produce '---\\n' (HR-01 escape appends editable line)")
        XCTAssertEqual(runner.selection, NSRange(location: 4, length: 0),
                       "Caret must sit on the editable line below the rule (offset 4)")

        runner.key(.enter)

        // Enter from the empty line below HR is a plain newline — no HR
        // handler fires. Body gains one more `\n`, caret at 5.
        XCTAssertEqual(runner.body, "---\n\n",
                       "Enter from line below HR appends a plain newline")
        XCTAssertEqual(runner.selection, NSRange(location: 5, length: 0),
                       "Caret advances to offset 5 after plain newline")

        // Transcript dump must reflect the exact step log — paste-ready Swift.
        let dump = runner.transcriptDump()
        XCTAssertTrue(dump.contains("KeystrokeRunner(initialBody: \"\""),
                      "Transcript must start with the initializer call")
        XCTAssertTrue(dump.contains("runner.type(\"---\")"),
                      "Transcript must log the type() call as paste-ready Swift")
        XCTAssertTrue(dump.contains("runner.key(.enter)"),
                      "Transcript must log the key() call as paste-ready Swift")
    }

    /// Minimal sanity: `.backspace` must actually delete via the real
    /// Coordinator → handleAtomicMarkerBackspace fallthrough →
    /// NSTextView default deleteBackward path. If the runner's
    /// fallthrough-to-default branch breaks, this fails.
    func test_smoke_typeBackspaceBackspaceProducesEmpty() {
        let runner = KeystrokeRunner()
        runner.type("hi")
        runner.assertBody("hi")
        runner.key(.backspace)
        runner.key(.backspace)
        runner.assertBody("")
        runner.assertSelection(NSRange(location: 0, length: 0))
    }
}
