import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// It encodes a bug-shape that was historically reported (memory entry
// "backspace at right edge of <u>...</u> eats hidden marker bytes and
// exposes literal tags"). The fix shipped under quick task 260524-0ia
// (commit 31ef3f2). This file is the keystroke-driven version of that
// regression — the helper-level version lives in AtomicMarkerDeleteTests
// (test_live_backspace_underline_atCloseEdge_swallowsPairKeepsContent at
// line 282 of that file). Together they pin the fix at two layers:
// the helper function (FormattingToolbarView.handleAtomicMarkerBackspace)
// AND the Coordinator path that calls it (HybridEditorView.Coordinator
// .textView(_:doCommandBy:) — deleteBackward(_:) branch at line 757-758
// of HybridEditorView.swift). If either drifts, one of the two tests
// will catch it.
//
// Why the runner instead of the helper-level test:
// AtomicMarkerDeleteTests calls FormattingToolbarView.handleAtomicMarkerBackspace
// directly. That proves the helper's logic is correct. This file proves the
// helper is REACHED end-to-end through the real delegate path (coordinator
// dispatch → command-selector match → helper call). If a future refactor
// were to wire deleteBackward differently in the Coordinator and silently
// bypass handleAtomicMarkerBackspace, the helper-level test would still
// pass but this Coordinator-level test would catch the regression.

/// Layer 3 of the headless harness — keystroke-driven regression guard
/// for the `<u>...</u>` right-edge backspace bug shipped-fix.
@MainActor
final class BackspaceAtUnderlineRightEdgeTests: XCTestCase {

    func test_backspaceAtUnderlineRightEdge_doesNotExposeLiteralTags() throws {
        // Body: "<u>foo</u>" (10 chars). Caret at offset 10 = right edge of
        // the closing tag, i.e. the "close edge" handleAtomicMarkerBackspace
        // is wired to detect for underline pairs.
        let runner = KeystrokeRunner(
            initialBody: "<u>foo</u>",
            initialSelection: NSRange(location: 10, length: 0)
        )

        // Drive backspace through the real Coordinator → handleAtomicMarkerBackspace
        // path. If the path is intact, the entire pair is removed atomically
        // and inner content survives.
        runner.key(.backspace)

        // Primary defensive assertions: no literal underline tag bytes
        // must leak into the body. Pre-fix this was the exact symptom —
        // hidden marker bytes got eaten one at a time, exposing `</u>`,
        // then `</u`, then `</`, etc. None of those substrings may appear.
        XCTAssertFalse(runner.body.contains("<u>"),
                       "Literal opening tag must not be exposed after right-edge backspace")
        XCTAssertFalse(runner.body.contains("</u>"),
                       "Literal closing tag must not be exposed after right-edge backspace")
        XCTAssertFalse(runner.body.contains("</u"),
                       "Partial closing tag must not be exposed")
        XCTAssertFalse(runner.body.contains("</"),
                       "Even more partial closing tag must not be exposed")

        // Post-fix end-state: pair atomically removed, inner content
        // preserved, caret parked at end of inner content. Matches the
        // helper-level pin in AtomicMarkerDeleteTests
        // (test_live_backspace_underline_atCloseEdge_swallowsPairKeepsContent).
        XCTAssertEqual(runner.body, "foo",
                       "Underline pair must be deleted; inner content preserved (primary bug case)")
        XCTAssertEqual(runner.selection, NSRange(location: 3, length: 0),
                       "Caret parks at end of inner content (offset 3)")
    }
}
