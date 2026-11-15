import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// A5 (right-arrow probe): divider dashes were `.null` glyphs. The typesetter
// skips `.null` glyphs, so a divider line had no glyph of its own:
//   - loaded or set in one pass (`one\n---`), the dashes joined the `one` line
//     fragment, and a trailing divider drew its hairline through `one`;
//   - typed after Return on the line above (`one` + Return + `---`, `two`
//     below), AppKit's own Left/Right on `one` jumped to the line's ends
//     (Left 3 → 0, Right 0 → 3, Left 1 → 3) until the note was reloaded.
//
// Fix: `MarkdownLayoutManager` lays divider dashes out as zero-advancement
// control glyphs. They stay invisible but occupy the divider's own line.
//
// Layer 4 (HostedEditorRunner): needs real layout and real arrow keys.
@MainActor
final class DividerOwnLineLayoutTests: XCTestCase {

    /// The dash glyphs sit on a line fragment below `one`, whichever path built
    /// the layout (mounted, trailing, or typed).
    func test_dividerDashes_layOutOnTheirOwnLine() {
        let cases: [(String, HostedEditorRunner)] = [
            ("mounted mid", HostedEditorRunner(initialBody: "one\n---\ntwo")),
            ("mounted trailing", HostedEditorRunner(initialBody: "one\n---")),
            ("typed", typedRunner()),
        ]
        for (label, runner) in cases {
            let lm = runner.inner.layoutManager
            lm.ensureLayout(for: runner.inner.container)
            let oneLine = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: 0), effectiveRange: nil)
            for dash in 4...6 {
                let dashLine = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: dash), effectiveRange: nil)
                XCTAssertGreaterThanOrEqual(dashLine.minY, oneLine.maxY,
                    "[\(label)] dash \(dash) must sit below `one` (dash line \(dashLine), one line \(oneLine))")
            }
        }
    }

    /// Plain Left/Right on the line above a typed divider step one character.
    func test_arrowsOnLineAboveTypedDivider_stepOneCharacter() {
        for (start, key, expected) in [(3, KeystrokeRunner.Key.left, 2),
                                       (0, .right, 1),
                                       (1, .left, 0),
                                       (2, .right, 3)] {
            let runner = typedRunner()
            runner.select(NSRange(location: start, length: 0))
            runner.key(key)
            runner.assertSelection(NSRange(location: expected, length: 0))
        }
    }

    /// `one` + Return + `---` typed above an existing `two`.
    private func typedRunner() -> HostedEditorRunner {
        let runner = HostedEditorRunner(initialBody: "one\ntwo", initialSelection: NSRange(location: 3, length: 0))
        runner.type("\n---")
        runner.assertBody("one\n---\ntwo")
        return runner
    }
}
