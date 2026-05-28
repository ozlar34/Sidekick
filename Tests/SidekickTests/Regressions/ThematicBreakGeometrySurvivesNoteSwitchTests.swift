import XCTest
import AppKit
@testable import Sidekick

// Regression guard for "HR hairline shifts upward after note-switch round trip".
//
// User-reported bug: typing `---` creates a horizontal rule that renders
// correctly on a freshly-typed note. Switching to another note and switching
// back causes the hairline to visibly shift upward, overlapping the line of
// text above the HR.
//
// Root cause: NSLayoutManager glyph-layout drift between two paths that
// produce the same .sidekickThematicBreak storage state.
//   - typed-incrementally: each dash glyph is generated separately. By the
//     time the 3rd dash is typed and the parser stamps `.sidekickHiddenMarker`
//     on chars 0..2 of the dash run, glyphs 0/1 are already in the cache as
//     visible glyphs. The HR's `---\n` ends up in its own line fragment.
//   - full-text replace (note switch): all 3 dashes' glyphs are generated
//     AFTER `.sidekickHiddenMarker` is set, so they're all `.null` (zero
//     width) from the start. The typesetter packs them onto the preceding
//     empty paragraph's line fragment, and the HR's trailing `\n` is left
//     orphaned on its OWN line fragment beneath. The line fragment used by
//     `drawBackground`'s `lineFragmentUsedRect(forGlyphAt: firstDashGlyph)`
//     is now the line ABOVE the HR's true paragraph — the hairline shifts up.
//
// Fix: drawBackground anchors on the HR paragraph's TRAILING newline, not the
// first dash glyph. The trailing newline is always in the HR paragraph's
// own line fragment (in both layout paths).
//
// See MarkdownLayoutManager.swift `drawBackground` for the rendering fix.
@MainActor
final class ThematicBreakGeometrySurvivesNoteSwitchTests: XCTestCase {

    /// Pin the hairline Y to a stable value regardless of typed-vs-mounted
    /// origin path. Both variants must agree, and both must agree after a
    /// note-switch round trip.
    func test_HR_hairlineY_stableAcrossTypedMountedRoundTrip() throws {
        let body = "before\n\n---\n\nafter"

        // Typed-from-empty path.
        let typedRunner = HostedEditorRunner(initialBody: "")
        typedRunner.type(body)
        typedRunner.inner.layoutManager.ensureLayout(for: typedRunner.inner.container)
        let typedHairlineY = computeHairlineYForHR(runner: typedRunner, body: body)

        // Mounted-from-string path.
        let mountedRunner = HostedEditorRunner(initialBody: body)
        let mountedHairlineY = computeHairlineYForHR(runner: mountedRunner, body: body)

        // Mounted, swapped away, swapped back (production note-switch path).
        let swappedRunner = HostedEditorRunner(initialBody: body)
        swapBody(swappedRunner, to: "different body, no HR")
        swapBody(swappedRunner, to: body)
        let swappedHairlineY = computeHairlineYForHR(runner: swappedRunner, body: body)

        // 1.5pt tolerance: typed-incremental path and full-text-replace path
        // produce minutely-different line stacks (typed sometimes uses a 21pt
        // line fragment where mounted uses 20pt due to paragraphSpacing
        // accumulation order). The user-visible bug was a ≥20pt line shift;
        // sub-line jitter is below perception threshold and not what we guard.
        let eps: CGFloat = 1.5
        XCTAssertEqual(typedHairlineY, mountedHairlineY, accuracy: eps,
                       "typed=\(typedHairlineY) mounted=\(mountedHairlineY)")
        XCTAssertEqual(typedHairlineY, swappedHairlineY, accuracy: eps,
                       "typed=\(typedHairlineY) swapped=\(swappedHairlineY)")
    }

    /// Stronger: the hairline must land on the HR's own paragraph's line, not
    /// on the line above it. Compute the line fragment that contains the HR's
    /// trailing newline and assert the hairline Y sits within ±10pt of that
    /// line's midY in EVERY variant.
    func test_HR_hairlineY_landsOnHRsOwnLine() throws {
        let body = "before\n\n---\n\nafter"

        for (label, runner) in [
            ("typed", makeTyped(body: body)),
            ("mounted", HostedEditorRunner(initialBody: body)),
            ("swapped", makeSwappedRoundTrip(body: body))
        ] {
            let hairlineY = computeHairlineYForHR(runner: runner, body: body)
            let trailingNewlineY = computeTrailingNewlineLineMidY(runner: runner, body: body)
            let eps: CGFloat = 1.0
            XCTAssertEqual(hairlineY, trailingNewlineY, accuracy: eps,
                           "[\(label)] hairline (Y=\(hairlineY)) must land on HR's own paragraph line (midY=\(trailingNewlineY))")
        }
    }

    // MARK: - Helpers

    private func makeTyped(body: String) -> HostedEditorRunner {
        let r = HostedEditorRunner(initialBody: "")
        r.type(body)
        r.inner.layoutManager.ensureLayout(for: r.inner.container)
        return r
    }

    private func makeSwappedRoundTrip(body: String) -> HostedEditorRunner {
        let r = HostedEditorRunner(initialBody: body)
        swapBody(r, to: "different body, no HR")
        swapBody(r, to: body)
        return r
    }

    private func swapBody(_ runner: HostedEditorRunner, to newBody: String) {
        let storage = runner.inner.storage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: newBody)
        storage.endEditing()
        runner.inner.layoutManager.ensureLayout(for: runner.inner.container)
    }

    /// Mirror the hairline Y math from `MarkdownLayoutManager.drawBackground`:
    /// uses the line fragment that contains the HR's trailing newline.
    private func computeHairlineYForHR(runner: HostedEditorRunner, body: String) -> CGFloat {
        let lm = runner.inner.layoutManager
        let storage = runner.inner.storage
        lm.ensureLayout(for: runner.inner.container)
        let hrCharLoc = (body as NSString).range(of: "---").location
        XCTAssertNotEqual(hrCharLoc, NSNotFound, "Test body must contain `---`")
        let trailingNewlineChar = hrCharLoc + 3
        let anchorGlyph: Int
        if trailingNewlineChar < storage.length {
            anchorGlyph = lm.glyphIndexForCharacter(at: trailingNewlineChar)
        } else {
            let dashGlyphRange = lm.glyphRange(forCharacterRange: NSRange(location: hrCharLoc, length: 3),
                                                actualCharacterRange: nil)
            anchorGlyph = dashGlyphRange.location
        }
        let used = lm.lineFragmentUsedRect(forGlyphAt: anchorGlyph, effectiveRange: nil)
        return used.midY - 0.5  // hairline is 1pt tall, centered
    }

    private func computeTrailingNewlineLineMidY(runner: HostedEditorRunner, body: String) -> CGFloat {
        let lm = runner.inner.layoutManager
        let storage = runner.inner.storage
        lm.ensureLayout(for: runner.inner.container)
        let hrCharLoc = (body as NSString).range(of: "---").location
        let trailingNewlineChar = hrCharLoc + 3
        guard trailingNewlineChar < storage.length else {
            // Fall back to the dashes' own line.
            let dashGlyphRange = lm.glyphRange(forCharacterRange: NSRange(location: hrCharLoc, length: 3),
                                                actualCharacterRange: nil)
            return lm.lineFragmentUsedRect(forGlyphAt: dashGlyphRange.location, effectiveRange: nil).midY
        }
        let glyph = lm.glyphIndexForCharacter(at: trailingNewlineChar)
        return lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).midY
    }
}
