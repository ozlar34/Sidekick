import XCTest
import AppKit
@testable import Sidekick

/// Pins the NSTextStorage contract for the hybrid markdown editor.
/// Covers:
///   - STORAGE-01 round-trip (byte-identical .string for every markdown construct)
///   - D-T-02 edit-range invariant (attribute mutations scoped to edited paragraph)
///   - D-T-04 hidden-marker attribute fallback (assert .sidekickHiddenMarker on exactly
///     the marker character indices; does NOT assert NSGlyphProperty.null directly —
///     that's layout-manager territory and harder to test window-less)
///
/// Pattern source: PerformWrapTests.swift (windowless AppKit + @MainActor).
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md
///   D-T-02, D-T-03, D-T-04.
@MainActor
final class MarkdownTextStorageTests: XCTestCase {

    /// Standard four-piece TextKit 1 assembly. Leaving the layout manager
    /// unwired can mask processEditing bugs — the layout manager is notified
    /// of edited ranges as part of the NSTextStorage contract (PATTERNS.md
    /// line 371).
    private func makeStorage(_ body: String) -> MarkdownTextStorage {
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 100))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: body)
        return storage
    }

    // MARK: - STORAGE-01: byte-identical round-trip

    func test_storage_isByteIdenticalRoundTrip_simpleMarkdown() {
        let markdown = "# Heading\n\n**bold** and *italic* and `code`.\n\n- bullet one\n- bullet two\n\n```\nfenced code\n```\n"
        let storage = makeStorage(markdown)
        XCTAssertEqual(storage.string, markdown,
                       "STORAGE-01: hybrid rendering must be view-only; bytes unchanged")
    }

    func test_storage_isByteIdenticalRoundTrip_withEmoji() {
        // Emoji surrogate-pair sanity — storage.string must preserve the
        // full UTF-16 encoding. "🎉" is a surrogate pair = 2 UTF-16 units.
        let markdown = "hello **🎉** world"
        let storage = makeStorage(markdown)
        XCTAssertEqual(storage.string, markdown,
                       "STORAGE-01: surrogate pairs must survive round-trip")
    }

    func test_storage_roundTrip_afterMultipleEdits() {
        let storage = makeStorage("")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "**a**")
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " *b*")
        storage.replaceCharacters(in: NSRange(location: 9, length: 0), with: " `c`")
        XCTAssertEqual(storage.string, "**a** *b* `c`",
                       "STORAGE-01 holds under a sequence of small edits")
    }

    // MARK: - D-T-04: hidden-marker attribute on marker ranges

    func test_boldMarkers_tagged_sidekickHiddenMarker() {
        let storage = makeStorage("**bold**")
        // Marker open: {0,2} — characters '*' '*'
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                        "Opening ** at location 0 must carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                        "Opening ** at location 1 must carry .sidekickHiddenMarker")
        // Content: {2,4} ("bold") — must NOT carry the marker attribute
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                     "Content 'bold' at location 2 must NOT carry .sidekickHiddenMarker")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 5, effectiveRange: nil),
                     "Content 'bold' at location 5 must NOT carry .sidekickHiddenMarker")
        // Marker close: {6,2}
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 6, effectiveRange: nil),
                        "Closing ** at location 6 must carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 7, effectiveRange: nil),
                        "Closing ** at location 7 must carry .sidekickHiddenMarker")
    }

    func test_headingMarkers_tagged_sidekickHiddenMarker() {
        let storage = makeStorage("# Title")
        // Prefix range {0,2} covers "# " (hash + space)
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                        "# prefix at location 0 must carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                        "Space after # at location 1 must carry .sidekickHiddenMarker")
        // Content "Title" at 2..6 must NOT carry the marker attribute
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                     "First content char 'T' at location 2 must NOT carry .sidekickHiddenMarker")
    }

    func test_bulletPrefix_tagged_sidekickBulletMarker() {
        let storage = makeStorage("- item")
        // Dash at 0 gets .sidekickBulletMarker so the layout manager
        // substitutes its glyph to U+2022 BULLET. The trailing space at 1
        // stays visible so rendered output is `• item` (not `•item`).
        XCTAssertNotNil(storage.attribute(.sidekickBulletMarker, at: 0, effectiveRange: nil),
                        "- at location 0 must carry .sidekickBulletMarker (glyph substituted to •)")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                     "- at location 0 must NOT carry .sidekickHiddenMarker (it's visible as •)")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                     "Space after - at location 1 must stay visible for `• item` rendering")
        XCTAssertNil(storage.attribute(.sidekickBulletMarker, at: 2, effectiveRange: nil),
                     "Content 'i' at location 2 must NOT carry .sidekickBulletMarker")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                     "Content 'i' at location 2 must NOT carry .sidekickHiddenMarker")
    }

    func test_inlineCodeMarkers_tagged_sidekickHiddenMarker() {
        // "a `code` b" — backtick at location 2, code "code" at 3..6, close backtick at 7
        let storage = makeStorage("a `code` b")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 2, effectiveRange: nil),
                        "Opening ` at location 2 must carry .sidekickHiddenMarker")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 3, effectiveRange: nil),
                     "Content 'c' at location 3 must NOT carry .sidekickHiddenMarker")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 7, effectiveRange: nil),
                        "Closing ` at location 7 must carry .sidekickHiddenMarker")
    }

    func test_unclosedBold_doesNotHideMarker() {
        // D-MH-04: unclosed markers stay visible. `.sidekickHiddenMarker`
        // must NOT be set on the opening ** of "**foo".
        let storage = makeStorage("**foo")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                     "Unclosed ** must NOT carry .sidekickHiddenMarker (D-MH-04)")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                     "Unclosed ** must NOT carry .sidekickHiddenMarker (D-MH-04)")
    }

    // MARK: - D-T-02: edit-range invariant

    func test_processEditing_onlyMutatesAttributesInEditedParagraphRange() {
        let body = "para one\n\npara two\n\npara **three**\n\npara four"
        let storage = makeStorage(body)

        // Snapshot the font attribute on paragraph 1 ("para one") chars 0..8
        // BEFORE the edit.
        let before = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        // Edit inside paragraph 2 ("para two"):
        // "para one" = 8 chars, "\n" = 1, "\n" = 1, total offset to "para two" = 10
        // "para two" = 8 chars, editing at end of "para two" = location 18
        let editLocation = 18   // "para one\n\npara two" → length 18, insert after
        storage.replaceCharacters(in: NSRange(location: editLocation, length: 0), with: "X")

        // Assert font on location 0 (paragraph 1) is unchanged.
        let after = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(before, after,
                       "D-T-02: edits in paragraph 2 must not mutate attributes in paragraph 1")
    }

    func test_processEditing_editInsideFenceExpandsReparseToFence() {
        // When the edit lands inside a fenced code block, the reparse range
        // must expand to include both fence lines so the closing ``` keeps
        // its hidden-marker attribute.
        //
        // Buffer layout (UTF-16 offsets):
        //   "```\n"       = 4 chars  → location  0, fenceOpen  {0, 4}
        //   "line one\n"  = 9 chars  → location  4
        //   "line two\n"  = 9 chars  → location 13
        //   "```\n"       = 4 chars  → location 22, fenceClose {22, 4}
        let body = "```\nline one\nline two\n```\n"
        let storage = makeStorage(body)

        // Confirm closing fence is hidden after initial parse.
        // Closing ``` starts at location 22.
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 22, effectiveRange: nil),
                        "Closing ``` at location 22 must carry .sidekickHiddenMarker after initial parse")

        // Edit inside the content region (insert "X" at location 13 — start of "line two").
        storage.replaceCharacters(in: NSRange(location: 13, length: 0), with: "X")

        // The closing fence index shifted by +1 → now at 23. Verify still hidden.
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 23, effectiveRange: nil),
                        "Closing ``` must remain hidden after edit inside fence (D-PS-02 expansion)")
    }

    // MARK: - Visible attributes applied correctly

    func test_boldContent_getsSemiboldFont() {
        let storage = makeStorage("**bold**")
        // Content "bold" starts at location 2
        let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font, "Bold content must have a font attribute")
        // Font descriptor should include the semibold/bold trait.
        let descriptor = font?.fontDescriptor
        XCTAssertTrue(
            descriptor?.symbolicTraits.contains(.bold) == true
            || (descriptor?.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0 >= 0.3,
            "Bold content font must register as bold/semibold"
        )
    }

    func test_inlineCodeContent_getsMonospacedFontAndBackground() {
        // "a `code` b" — code content at location 3
        let storage = makeStorage("a `code` b")
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font, "Inline code content must have a font attribute")
        let bg = storage.attribute(.backgroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(bg, "Inline code content must have a backgroundColor attribute")
    }

    // MARK: - Link attribute tests (D-T-02, HYBRID-07 storage layer)

    func test_linkMarkers_tagged_sidekickHiddenMarker() {
        // body "[foo](x)" — indices: [ 0, f 1, o 2, o 3, ] 4, ( 5, x 6, ) 7
        let storage = makeStorage("[foo](x)")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                        "'[' at index 0 must be hidden")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 1, effectiveRange: nil),
                     "label 'f' at index 1 must NOT be hidden")
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 3, effectiveRange: nil),
                     "label 'o' at index 3 must NOT be hidden")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 4, effectiveRange: nil),
                        "']' at index 4 must be hidden")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 5, effectiveRange: nil),
                        "'(' at index 5 must be hidden")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 6, effectiveRange: nil),
                        "URL 'x' at index 6 must be hidden")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 7, effectiveRange: nil),
                        "')' at index 7 must be hidden")
    }

    func test_linkLabel_tagged_linkAttribute() {
        // "[Google](https://google.com)" — label "Google" at index 1, length 6
        let storage = makeStorage("[Google](https://google.com)")
        let linkValue = storage.attribute(.link, at: 1, effectiveRange: nil) as? URL
        XCTAssertNotNil(linkValue, "Label must carry AppKit .link attribute (D-LR-05)")
        XCTAssertEqual(linkValue?.absoluteString, "https://google.com")
        // And underline + foreground
        let underline = storage.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue, "Label must carry single underline")
        let color = storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.linkColor, "Label must carry link foreground color")
    }

    func test_invalidURL_hidesMarkersButOmitsLinkAttribute() {
        // "[foo](http://bad\turl)" — URL(string:) returns nil for strings with embedded tabs
        // (Foundation rejects control characters in URLs; spaces are percent-encoded on some
        // platforms, so we use a tab character which is reliably rejected — D-LR-06 fallback)
        // Per D-LR-06 fallback: markers still hidden, label styled, but .link is NIL
        let storage = makeStorage("[foo](http://bad\turl)")
        XCTAssertNotNil(storage.attribute(.sidekickHiddenMarker, at: 0, effectiveRange: nil),
                        "'[' hidden even when URL invalid (D-LR-06)")
        XCTAssertNil(storage.attribute(.link, at: 1, effectiveRange: nil),
                     "Label must NOT carry .link when URL(string:) returns nil (D-LR-06 fallback)")
    }

    func test_link_roundTrip_preservesBytes() {
        // STORAGE-01 extended to links: storage.string == input body byte-for-byte
        let input = "Before [label](https://example.com) middle [empty]() end"
        let storage = makeStorage(input)
        XCTAssertEqual(storage.string, input,
                       "Round-trip must preserve raw markdown byte-for-byte (STORAGE-01 for links)")
    }

    // MARK: - First-line styling (post-2026-05-01 title-shift)
    //
    // The "first body line is auto-H1" convention was deleted when title became
    // an explicit field on Note. First body line now renders at plain body 15pt.

    func test_firstLine_plainProse_isPlainBodyFont() {
        // No more auto-H1 — first body line is plain body 15pt (no bold).
        let storage = makeStorage("Shopping List\n\nmilk\neggs")
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font, "First line must have a font attribute")
        XCTAssertEqual(Double(font?.pointSize ?? 0), 15, accuracy: 0.01,
                       "Plain first line renders at body 15pt — no auto-H1")
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
                       "Plain first line is not bold")
    }

    func test_explicitH2_contentAt22pt() {
        // Explicit `## ` heading content renders at H2 (22pt semibold).
        let storage = makeStorage("## Subtitle\n\nbody")
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertEqual(Double(font?.pointSize ?? 0), 22, accuracy: 0.01,
                       "## heading content renders at H2 22pt")
    }

    func test_firstLine_bulletPrefix_contentAtBodySize() {
        // First body line carrying a bullet renders at plain body size — no
        // auto-heading promotion.
        let storage = makeStorage("- first item\nmore")
        let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertEqual(Double(font?.pointSize ?? 0), 15, accuracy: 0.01,
                       "Bullet first-line content stays at body 15pt")
    }

    func test_firstLine_whitespaceOnly_atBodySize() {
        // Whitespace-only first line stays at body size — no styling applied.
        let storage = makeStorage("   \nhello")
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(Double(font?.pointSize ?? 0), 15, accuracy: 0.01,
                       "Whitespace-only first line stays at body 15pt")
    }

    func test_explicitH1_survivesEditOnLaterLine() {
        // Regression guard: editing paragraph 3 must not strip line 0's
        // explicit `# Title` heading style.
        let storage = makeStorage("# Title\n\npara 2\n\npara 3")
        // Heading content at offset 2 (past `# `).
        let fontBefore = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(Double(fontBefore?.pointSize ?? 0), 28, accuracy: 0.01,
                       "Explicit H1 is 28pt before the edit")

        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "X")

        let fontAfter = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(Double(fontAfter?.pointSize ?? 0), 28, accuracy: 0.01,
                       "Edits on later lines must not drop explicit H1 style")
    }

    // MARK: - Checklist attribute tests (Wave 0 regression guards — EDIT-01)

    func test_checklistPrefix_tagged_sidekickChecklistMarker() {
        let unchecked = makeStorage("- [ ] task\n")
        let uValue = unchecked.attribute(.sidekickChecklistMarker, at: 0, effectiveRange: nil)
        XCTAssertNotNil(uValue, "Marker char must carry .sidekickChecklistMarker")
        XCTAssertEqual(uValue as? Bool, false, "Unchecked line tags marker false")

        let checked = makeStorage("- [x] task\n")
        let cValue = checked.attribute(.sidekickChecklistMarker, at: 0, effectiveRange: nil)
        XCTAssertNotNil(cValue, "Marker char must carry .sidekickChecklistMarker")
        XCTAssertEqual(cValue as? Bool, true, "Checked line tags marker true")
    }

    func test_checkedItem_hasStrikethroughAndDim() {
        // "- [x] done\n" — content "done" is at indices 6..<10
        let checkedStorage = makeStorage("- [x] done\n")
        let strike = checkedStorage.attribute(.strikethroughStyle, at: 6, effectiveRange: nil)
        XCTAssertEqual(strike as? Int, NSUnderlineStyle.single.rawValue,
                       "D-04: checked-item content must be struck through")
        let color = checkedStorage.attribute(.foregroundColor, at: 6, effectiveRange: nil)
        XCTAssertEqual(color as? NSColor, NSColor.tertiaryLabelColor,
                       "D-04: checked-item content must be dimmed to tertiaryLabelColor")

        // Unchecked content must NOT be struck through.
        let openStorage = makeStorage("- [ ] open\n")
        let openStrike = openStorage.attribute(.strikethroughStyle, at: 6, effectiveRange: nil)
        XCTAssertNil(openStrike, "Unchecked content must not be struck through")
    }

    // MARK: - SF Pro body font (aesthetic pass)

    func test_baseFont_isSFPro_notMono() {
        // Plain body text on line 2+ uses SF Pro (not SF Mono).
        let storage = makeStorage("Title\nplain body text")
        // Index past the H1 first line — points into "plain body text".
        let bodyIdx = ("Title\n" as NSString).length + 2  // mid "plain"
        let font = storage.attribute(.font, at: bodyIdx, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font, "Body must have a font attribute")
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true,
                       "Body font must not carry the .monoSpace trait — SF Pro, not SF Mono")
    }

    func test_inlineCode_staysMonospaced_underSFProBody() {
        // Inline code keeps its mono font even though the body is now SF Pro.
        let storage = makeStorage("Title\nbefore `code` after")
        // Find the offset of the 'c' in `code`.
        let codeIdx = (storage.string as NSString).range(of: "code").location
        let font = storage.attribute(.font, at: codeIdx, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true,
                      "Inline code must remain monospaced")
    }

    // MARK: - Heading paragraph spacing
    //
    // Live constants in MarkdownTextStorage.h{1,2,3}ParagraphStyle:
    //   H1: paragraphSpacing = 4
    //   H2: paragraphSpacing = 3
    //   H3: paragraphSpacing = 2

    func test_explicitH1_hasParagraphSpacing() {
        let storage = makeStorage("# Title\nbody line")
        // Inspect the paragraph style at the heading content (index 2 — past `# `).
        let style = storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(style, "Explicit H1 must carry a paragraphStyle")
        XCTAssertEqual(Double(style?.paragraphSpacing ?? 0), 4, accuracy: 0.01,
                       "Explicit H1 paragraphSpacing is 4pt")
    }

    func test_explicitH2_hasParagraphSpacing() {
        let storage = makeStorage("# H1 line\n## Sub\nbody")
        let h2Start = ("# H1 line\n" as NSString).length + 3  // past `## `
        let style = storage.attribute(.paragraphStyle, at: h2Start, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(style, "Explicit H2 must carry a paragraphStyle")
        XCTAssertEqual(Double(style?.paragraphSpacing ?? 0), 3, accuracy: 0.01,
                       "Explicit H2 paragraphSpacing is 3pt")
    }

    func test_explicitH1_paragraphSpacing_survivesEditOnLaterLine() {
        let storage = makeStorage("# Title\n\npara 2\n\npara 3")
        let styleBefore = storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(Double(styleBefore?.paragraphSpacing ?? 0), 4, accuracy: 0.01)

        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "X")

        let styleAfter = storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(Double(styleAfter?.paragraphSpacing ?? 0), 4, accuracy: 0.01,
                       "Edits on later lines must not drop H1 paragraph spacing")
    }
}
