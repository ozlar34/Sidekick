import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// User-reported bug: a note containing `---` shows the rendered HR hairline
// on first display; after switching to another note and switching back, the
// `---` chars survive but the hairline is gone. The parser
// (MarkdownInlineParser.findThematicBreaks) has its own unit coverage in
// MarkdownInlineParserTests, and EditorInteractionTests pins the keystroke
// paths that interact with HR — but no test exercises the note-switch round
// trip that production drives through HybridEditorView.updateNSView's
// `.applyExternalPush` branch (HybridEditorView.swift:584-595).
//
// Production path on note switch:
//   storage.beginEditing()
//   storage.replaceCharacters(in: NSRange(0, storage.length), with: newBody)
//   storage.endEditing()                 // fires processEditing → reparse
//
// This file drives storage directly with the same pattern. If the reparse
// re-stamps `.sidekickThematicBreak` on the dash run, the HR survives.
@MainActor
final class ThematicBreakSurvivesNoteSwitchTests: XCTestCase {

    /// Body with HR in the middle, after a blank line and before content.
    /// This is the canonical shape: `text\n\n---\n\nmore text`.
    func test_thematicBreak_survivesNoteSwitchRoundTrip() throws {
        let noteA = "before\n\n---\n\nafter"
        let noteB = "different body, no horizontal rule"

        let runner = HostedEditorRunner(initialBody: noteA)

        // Baseline: HR attribute is stamped on the dash run after initial mount.
        // The `---` occupies chars 8..10 (after "before\n\n" = 8 chars).
        let hrLocation = (noteA as NSString).range(of: "---").location
        XCTAssertEqual(hrLocation, 8, "Test setup sanity")
        assertHRStamped(runner.attributedString, at: hrLocation, label: "initial mount")

        // Simulate note-switch push to note B.
        swapBody(runner, to: noteB)

        // After the swap, the new body has no HR — the attribute must be absent
        // on the chars where HR used to be (if those chars even exist).
        // Just sanity-check there's no thematic-break run anywhere in noteB.
        XCTAssertFalse(
            attributedStringHasAnyThematicBreak(runner.attributedString),
            "Note B has no `---` — no thematic-break attribute should exist anywhere"
        )

        // Simulate return to note A.
        swapBody(runner, to: noteA)

        // Round-trip assertion: HR attribute must be re-stamped on the dash run.
        assertHRStamped(runner.attributedString, at: hrLocation, label: "after round trip")
        // And: glyphs for the dash chars must carry `.null` property — that's
        // what makes the `---` invisible so the painted hairline isn't obscured.
        assertHRGlyphsHidden(runner: runner, charLocation: hrLocation, label: "after round trip")
        // And: drawBackground must find the HR run when called over the whole
        // glyph range — this is what paints the visible hairline. If the
        // glyph→char mapping is stale after a full-text replace, drawBackground
        // can be called but enumerate over an empty char range, skipping HR.
        assertDrawBackgroundFindsHR(runner: runner, charLocation: hrLocation, label: "after round trip")
    }

    /// Minimal body shape: HR at the leading edge (no preceding blank line —
    /// exercises the parser's `lineRange.location == 0` branch).
    func test_thematicBreak_survivesNoteSwitchRoundTrip_minimalBody() throws {
        let noteA = "---\nafter"
        let noteB = "no rule here"

        let runner = HostedEditorRunner(initialBody: noteA)

        let hrLocation = 0
        assertHRStamped(runner.attributedString, at: hrLocation, label: "initial mount (minimal)")

        swapBody(runner, to: noteB)
        XCTAssertFalse(
            attributedStringHasAnyThematicBreak(runner.attributedString),
            "Note B has no `---` — no thematic-break attribute should exist anywhere"
        )

        swapBody(runner, to: noteA)
        assertHRStamped(runner.attributedString, at: hrLocation, label: "after round trip (minimal)")
        assertHRGlyphsHidden(runner: runner, charLocation: hrLocation, label: "after round trip (minimal)")
        assertDrawBackgroundFindsHR(runner: runner, charLocation: hrLocation, label: "after round trip (minimal)")
    }

    // MARK: - Byte-preservation for `***` and `___` marker types

    /// Byte-preservation guarantee: a `***` thematic break survives a full
    /// note-switch round trip with its exact bytes intact — never normalized to `---`.
    func test_asteriskRule_survivesRoundTrip_bytesPreserved() throws {
        let noteA = "alpha\n\n***\n\nbeta"
        let noteB = "no rule here"

        let runner = HostedEditorRunner(initialBody: noteA)

        // The `***` occupies chars 7..9 ("alpha\n\n" = 7 chars).
        let hrLocation = (noteA as NSString).range(of: "***").location
        XCTAssertEqual(hrLocation, 7, "Test setup sanity: *** starts at offset 7")

        // Baseline: HR attribute stamped on the asterisk run after initial mount.
        assertHRStamped(runner.attributedString, at: hrLocation, label: "initial mount")
        XCTAssertTrue(runner.body.contains("***"),
                      "Body must contain *** verbatim after initial mount")
        XCTAssertFalse(runner.body.contains("---"),
                       "Body must NOT be normalized to --- after initial mount")

        // Simulate note-switch to note B (no HR).
        swapBody(runner, to: noteB)
        XCTAssertFalse(
            attributedStringHasAnyThematicBreak(runner.attributedString),
            "Note B has no HR — no thematic-break attribute should exist anywhere"
        )

        // Simulate return to note A.
        swapBody(runner, to: noteA)

        // Round-trip assertion: HR re-stamped on the asterisk run.
        assertHRStamped(runner.attributedString, at: hrLocation, label: "after round trip")
        // Byte-preservation: the literal *** chars survived verbatim.
        XCTAssertTrue(runner.body.contains("***"),
                      "Body must still contain *** verbatim after round trip (no normalization)")
        XCTAssertFalse(runner.body.contains("---"),
                       "Body must NOT be normalized to --- after round trip")
    }

    /// Byte-preservation guarantee: a `___` thematic break survives a full
    /// note-switch round trip with its exact bytes intact — never normalized to `---`.
    func test_underscoreRule_survivesRoundTrip_bytesPreserved() throws {
        let noteA = "alpha\n\n___\n\nbeta"
        let noteB = "no rule here"

        let runner = HostedEditorRunner(initialBody: noteA)

        // The `___` occupies chars 7..9 ("alpha\n\n" = 7 chars).
        let hrLocation = (noteA as NSString).range(of: "___").location
        XCTAssertEqual(hrLocation, 7, "Test setup sanity: ___ starts at offset 7")

        // Baseline: HR attribute stamped on the underscore run after initial mount.
        assertHRStamped(runner.attributedString, at: hrLocation, label: "initial mount")
        XCTAssertTrue(runner.body.contains("___"),
                      "Body must contain ___ verbatim after initial mount")
        XCTAssertFalse(runner.body.contains("---"),
                       "Body must NOT be normalized to --- after initial mount")

        // Simulate note-switch to note B (no HR).
        swapBody(runner, to: noteB)
        XCTAssertFalse(
            attributedStringHasAnyThematicBreak(runner.attributedString),
            "Note B has no HR — no thematic-break attribute should exist anywhere"
        )

        // Simulate return to note A.
        swapBody(runner, to: noteA)

        // Round-trip assertion: HR re-stamped on the underscore run.
        assertHRStamped(runner.attributedString, at: hrLocation, label: "after round trip")
        // Byte-preservation: the literal ___ chars survived verbatim.
        XCTAssertTrue(runner.body.contains("___"),
                      "Body must still contain ___ verbatim after round trip (no normalization)")
        XCTAssertFalse(runner.body.contains("---"),
                       "Body must NOT be normalized to --- after round trip")
    }

    // MARK: - Helpers

    /// Drive the storage through the same begin/replace/end pattern that
    /// `HybridEditorView.updateNSView`'s `.applyExternalPush` branch uses on
    /// a note switch. Then force layout so glyph generation runs against the
    /// new content (mirrors `HostedEditorRunner.forceLayout`).
    private func swapBody(_ runner: HostedEditorRunner, to newBody: String) {
        let storage = runner.inner.storage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: newBody)
        storage.endEditing()
        runner.inner.layoutManager.ensureLayout(for: runner.inner.container)
    }

    /// Assert `.sidekickThematicBreak == true` AND `.sidekickHiddenMarker == true`
    /// are stamped on the three dash chars starting at `location`.
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

    /// Assert that each of the three dash chars at `charLocation` produces a
    /// glyph with `.null` property. The hidden-marker mechanism (in
    /// MarkdownLayoutManager.setGlyphs) reads `.sidekickHiddenMarker` and ORs
    /// in `.null` on the glyph. If the glyph cache holds stale (non-null)
    /// properties after a full-text replace, the `---` chars render as visible
    /// dashes on top of the hairline rect — that's the reported visual bug.
    private func assertHRGlyphsHidden(
        runner: HostedEditorRunner,
        charLocation: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lm = runner.inner.layoutManager
        for offset in 0..<3 {
            let charIdx = charLocation + offset
            let glyphIdx = lm.glyphIndexForCharacter(at: charIdx)
            let prop = lm.propertyForGlyph(at: glyphIdx)
            XCTAssertTrue(
                prop.contains(.null),
                "[\(label)] glyph for char \(charIdx) must carry `.null` property (got \(prop.rawValue))",
                file: file, line: line
            )
        }
    }

    /// Design-contract pin: the parser must treat `---` as HR regardless of
    /// what's above it. Removing the prev-line-empty guard eliminated the
    /// substring-scoping asymmetry that caused the user-visible "HR appears,
    /// then vanishes on note switch" bug — full-doc and paragraph-scoped
    /// parses now agree.
    func test_findThematicBreaks_consistentAcrossScopes() {
        let body = "preceding text\n---\nfollowing"
        let fullDocRanges = MarkdownInlineParser.findThematicBreaks(in: body)
        let paragraphScoped = MarkdownInlineParser.findThematicBreaks(in: "---")

        XCTAssertEqual(fullDocRanges.count, 1,
                       "Full-doc parse must accept `---` regardless of prev-line content")
        XCTAssertEqual(paragraphScoped.count, 1,
                       "Substring-scoped parse must accept identically — no asymmetry")
    }

    /// Diagnostic: confirm the toolbar HR insert path still works after the fix.
    /// `performInsertThematicBreak` inserts `\n---\n\n` (or variants) which is
    /// supposed to produce blank-line-bounded HR shape that the parser accepts.
    func test_toolbarInsert_afterPlainText_rendersHR() throws {
        let runner = HostedEditorRunner(initialBody: "hello",
                                        initialSelection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performInsertThematicBreak(in: runner.inner.textView)
        runner.inner.layoutManager.ensureLayout(for: runner.inner.container)
        let body = runner.body
        NSLog("[SK-TB] post-insert body=\(body.debugDescription) length=\(body.count)")

        // Find the `---` in the resulting body and check whether HR is stamped.
        let dashRange = (body as NSString).range(of: "---")
        XCTAssertNotEqual(dashRange.location, NSNotFound, "Toolbar must insert `---`")
        let attrHR = runner.attributedString
            .attribute(.sidekickThematicBreak, at: dashRange.location, effectiveRange: nil) as? Bool
        XCTAssertEqual(attrHR, true,
                       "Toolbar-inserted `---` must be stamped as HR (body=\(body.debugDescription))")
    }

    /// Reproducer for the user-reported bug ("HR goes away on note switch"):
    /// a `---` line preceded by non-empty text used to flip between stamped
    /// (paragraph-scoped reparse, while typing) and unstamped (full-doc
    /// reparse, on note switch). Post-fix: HR is stamped consistently
    /// across both reparse scopes and survives the round trip.
    func test_setextLikeHR_isStampedAndSurvivesRoundTrip() {
        let body = "cd /Users/oguzoral/projects/Sidekick\n---\nafter"
        let runner = HostedEditorRunner(initialBody: body)

        let hrLocation = (body as NSString).range(of: "---").location
        let initialAttr = runner.attributedString
            .attribute(.sidekickThematicBreak, at: hrLocation, effectiveRange: nil) as? Bool
        XCTAssertEqual(initialAttr, true,
                       "Initial mount: `---` under non-empty line must still render as HR")

        // Round-trip through a note switch to ensure full-doc reparse agrees
        // with the initial mount.
        let storage = runner.inner.storage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: "completely different body")
        storage.endEditing()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: body)
        storage.endEditing()
        runner.inner.layoutManager.ensureLayout(for: runner.inner.container)

        let afterRoundTrip = runner.attributedString
            .attribute(.sidekickThematicBreak, at: hrLocation, effectiveRange: nil) as? Bool
        XCTAssertEqual(afterRoundTrip, true,
                       "After note-switch round trip: `---` under non-empty line must STILL render as HR")
    }

    /// Mirror of `MarkdownLayoutManager.drawBackground`'s HR-finding inner
    /// loop, without actually painting. Asserts that walking the full glyph
    /// range surfaces the `.sidekickThematicBreak` run at `charLocation`.
    private func assertDrawBackgroundFindsHR(
        runner: HostedEditorRunner,
        charLocation: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lm = runner.inner.layoutManager
        let storage = runner.inner.storage
        let totalGlyphRange = NSRange(location: 0,
                                      length: lm.numberOfGlyphs)
        let charRange = lm.characterRange(forGlyphRange: totalGlyphRange,
                                          actualGlyphRange: nil)
        XCTAssertGreaterThan(
            charRange.length, 0,
            "[\(label)] characterRange for full glyph range must be non-empty",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            charRange.location + charRange.length, storage.length,
            "[\(label)] characterRange must be within storage bounds",
            file: file, line: line
        )

        var foundHRAtExpectedLocation = false
        storage.enumerateAttribute(
            .sidekickThematicBreak,
            in: charRange,
            options: []
        ) { value, attrRange, _ in
            guard (value as? Bool) == true, attrRange.length > 0 else { return }
            if attrRange.location == charLocation && attrRange.length == 3 {
                foundHRAtExpectedLocation = true
            }
        }
        XCTAssertTrue(
            foundHRAtExpectedLocation,
            "[\(label)] drawBackground walk must surface HR run at (\(charLocation), 3)",
            file: file, line: line
        )
    }

    /// True if any char in the attributed string carries `.sidekickThematicBreak`.
    private func attributedStringHasAnyThematicBreak(_ attr: NSAttributedString) -> Bool {
        var found = false
        attr.enumerateAttribute(
            .sidekickThematicBreak,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, _, stop in
            if (value as? Bool) == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
