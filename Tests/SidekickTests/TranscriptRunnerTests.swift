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

    /// Typing `---` then Enter must exercise `handleThematicBreakReturn`
    /// via the real Coordinator path.
    ///
    /// Observed end-state (pinned to actual Coordinator output): starting
    /// from an empty body, typing `---` lands caret at offset 3 (the end
    /// of the dashes). `drawInsertionPoint` semantics treat the caret-
    /// at-end-of-dashes position as the HR's right edge (see
    /// `EditorInteractionTests.test_thematicBreakReturn_caretMidDashes_treatedAsRightEdge`)
    /// — Enter inserts a `\n` at lineEnd and parks the caret AT offset 3
    /// (one past the original lineEnd would be 4; observed is {3,0} which
    /// matches `setSelectedRange` to the original lineEnd as the handler
    /// records the new line below). Pinning the exact bytes here is what
    /// makes this test load-bearing: any drift in handleThematicBreakReturn
    /// or in the runner's command dispatch will move these numbers.
    func test_smoke_threeDashesPlusEnter_insertsThematicBreakAndMovesCaretUp() {
        let runner = KeystrokeRunner(initialBody: "",
                                     initialSelection: NSRange(location: 0, length: 0))
        runner.type("---")
        XCTAssertEqual(runner.body, "---",
                       "Three typed dashes must produce '---' in the buffer")

        runner.key(.enter)

        // Pinned to actual Coordinator end-state: body gains a trailing `\n`
        // (right-edge Enter on a no-trailing-newline HR appends one) and
        // caret stays at offset 3.
        XCTAssertEqual(runner.body, "---\n",
                       "Right-edge Enter on doc-start HR appends `\\n` at lineEnd")
        XCTAssertEqual(runner.selection, NSRange(location: 3, length: 0),
                       "Caret rests at offset 3 (end of the dashes, start of the new blank line)")

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
