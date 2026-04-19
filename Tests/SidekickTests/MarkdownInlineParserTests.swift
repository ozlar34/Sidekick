import XCTest
@testable import Sidekick

/// Pins the pure string-transformation contract that backs the hybrid
/// editor's inline parser. Tests exercise MarkdownInlineParser.* without
/// involving NSTextStorage or NSLayoutManager, so they run fast and
/// deterministically on any CI.
///
/// Pattern source: FormattingToolbarTests.swift (pure-function XCTest style).
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md D-T-01.
final class MarkdownInlineParserTests: XCTestCase {

    // MARK: - Bold happy path

    func test_bold_simplePair() {
        let body = "hello **world** bar"
        let matches = MarkdownInlineParser.findBoldRanges(in: body)
        XCTAssertEqual(matches.count, 1, "Should find exactly one bold pair")
        let m = matches[0]
        XCTAssertEqual(m.markerOpenRange, NSRange(location: 6, length: 2), "Open marker '**' starts at index 6")
        XCTAssertEqual(m.contentRange, NSRange(location: 8, length: 5), "Content 'world' is 5 chars at index 8")
        XCTAssertEqual(m.markerCloseRange, NSRange(location: 13, length: 2), "Close marker '**' starts at index 13")
    }

    // MARK: - Bold edge cases

    func test_bold_unclosed_returnsEmpty() {
        let matches = MarkdownInlineParser.findBoldRanges(in: "**foo")
        XCTAssertTrue(matches.isEmpty, "Unclosed bold marker must return empty (D-MH-04 pair-only-hide)")
    }

    func test_bold_adjacentPairs() {
        let body = "**a****b**"
        let matches = MarkdownInlineParser.findBoldRanges(in: body)
        XCTAssertEqual(matches.count, 2, "Adjacent pairs **a** and **b** should produce two matches")
        // First match: **a** → open={0,2} content={2,1} close={3,2}
        XCTAssertEqual(matches[0].contentRange.length, 1, "First content 'a' should be length 1")
        // Second match: **b** → content is 'b'
        XCTAssertEqual(matches[1].contentRange.length, 1, "Second content 'b' should be length 1")
    }

    func test_bold_emptyPair_handled() {
        // "** **" is a degenerate empty pair. Per D-T-01, the parser either skips it
        // (empty contentRange) or returns a match with zero-length content.
        // This test pins whatever Task 1 chose — it must not crash and
        // must be deterministic.
        let matches = MarkdownInlineParser.findBoldRanges(in: "** **")
        // Accept either 0 or 1 match; the important invariant is no crash and no
        // hidden text that shouldn't be. If the parser skips degenerate pairs, count is 0.
        // If it returns empty-content, we verify the content range is zero-length.
        if matches.count == 1 {
            XCTAssertEqual(matches[0].contentRange.length, 0, "Degenerate pair: content range must be empty")
        } else {
            XCTAssertEqual(matches.count, 0, "Degenerate pair: either skipped (0) or empty-content (1)")
        }
    }

    // MARK: - Italic happy paths

    func test_italic_asteriskPair() {
        let body = "a *foo* b"
        let matches = MarkdownInlineParser.findItalicRanges(in: body)
        XCTAssertEqual(matches.count, 1, "Should find one italic *foo* pair")
        XCTAssertEqual(matches[0].contentRange, NSRange(location: 3, length: 3), "Content 'foo' at index 3, length 3")
    }

    func test_italic_underscorePair() {
        let body = "a _foo_ b"
        let matches = MarkdownInlineParser.findItalicRanges(in: body)
        XCTAssertEqual(matches.count, 1, "Should find one italic _foo_ pair")
        XCTAssertEqual(matches[0].contentRange, NSRange(location: 3, length: 3), "Content 'foo' at index 3, length 3")
    }

    // MARK: - Italic edge cases

    func test_italic_doesNotMatchBold() {
        // **bold** — the * chars are paired as bold, italic's look-around must not claim them
        let matches = MarkdownInlineParser.findItalicRanges(in: "**bold**")
        XCTAssertTrue(matches.isEmpty, "Bold markers must not be claimed by italic parser")
    }

    func test_italic_mixedDelimiters_noMatch() {
        // *foo_ is a mismatched delimiter — should produce no match
        let matches = MarkdownInlineParser.findItalicRanges(in: "*foo_")
        XCTAssertTrue(matches.isEmpty, "Mismatched italic delimiters must return empty")
    }

    // MARK: - Inline code happy path

    func test_inlineCode_simplePair() {
        let body = "a `code` b"
        let matches = MarkdownInlineParser.findInlineCodeRanges(in: body)
        XCTAssertEqual(matches.count, 1, "Should find one inline code pair")
        XCTAssertEqual(matches[0].markerOpenRange, NSRange(location: 2, length: 1), "Open backtick at index 2")
        XCTAssertEqual(matches[0].contentRange, NSRange(location: 3, length: 4), "Content 'code' at index 3, length 4")
        XCTAssertEqual(matches[0].markerCloseRange, NSRange(location: 7, length: 1), "Close backtick at index 7")
    }

    // MARK: - Heading happy paths

    func test_heading_level1() {
        let matches = MarkdownInlineParser.findHeadingPrefixes(in: "# Title")
        XCTAssertEqual(matches.count, 1, "Should find H1")
        XCTAssertEqual(matches[0].level, 1, "Level must be 1")
        XCTAssertEqual(matches[0].prefixRange, NSRange(location: 0, length: 2), "Prefix '# ' is 2 UTF-16 units")
        XCTAssertEqual(matches[0].contentRange, NSRange(location: 2, length: 5), "Content 'Title' at index 2, length 5")
    }

    // MARK: - Heading edge cases

    func test_heading_level6() {
        let matches = MarkdownInlineParser.findHeadingPrefixes(in: "###### H6")
        XCTAssertEqual(matches.count, 1, "Should find H6")
        XCTAssertEqual(matches[0].level, 6, "Level must be 6")
    }

    func test_heading_level7_doesNotMatch() {
        let matches = MarkdownInlineParser.findHeadingPrefixes(in: "####### nope")
        XCTAssertTrue(matches.isEmpty, "H7+ must not match")
    }

    func test_heading_noTrailingSpace_doesNotMatch() {
        let matches = MarkdownInlineParser.findHeadingPrefixes(in: "#foo")
        XCTAssertTrue(matches.isEmpty, "Heading without trailing space must not match")
    }

    func test_heading_midLine_doesNotMatch() {
        // Leading whitespace before # means it's not at line start
        let matches = MarkdownInlineParser.findHeadingPrefixes(in: "   # Title")
        XCTAssertTrue(matches.isEmpty, "Heading with leading whitespace must not match")
    }

    // MARK: - Bullet happy path

    func test_bullet_dashPrefix() {
        let matches = MarkdownInlineParser.findBulletPrefixes(in: "- item")
        XCTAssertEqual(matches.count, 1, "Should find one bullet prefix")
        XCTAssertEqual(matches[0], NSRange(location: 0, length: 2), "Bullet prefix '- ' at index 0, length 2")
    }

    // MARK: - Bullet edge cases

    func test_bullet_asteriskPrefix() {
        let matches = MarkdownInlineParser.findBulletPrefixes(in: "* item")
        XCTAssertEqual(matches.count, 1, "Should find one bullet prefix with *")
        XCTAssertEqual(matches[0], NSRange(location: 0, length: 2), "Bullet prefix '* ' at index 0, length 2")
    }

    func test_bullet_noTrailingSpace_doesNotMatch() {
        let matches = MarkdownInlineParser.findBulletPrefixes(in: "-foo")
        XCTAssertTrue(matches.isEmpty, "Bullet without trailing space must not match")
    }

    // MARK: - Fenced code happy path

    func test_fenced_simpleBlock() {
        let body = "```\ncode\n```\n"
        let matches = MarkdownInlineParser.findFencedCodeBlocks(in: body)
        XCTAssertEqual(matches.count, 1, "Should find one fenced code block")
        // fenceOpenRange covers "```\n" (4 chars)
        XCTAssertEqual(matches[0].fenceOpenRange, NSRange(location: 0, length: 4), "Open fence '```\\n' at index 0, length 4")
        // contentRange covers "code\n" (5 chars)
        XCTAssertEqual(matches[0].contentRange, NSRange(location: 4, length: 5), "Content 'code\\n' at index 4, length 5")
        // fenceCloseRange covers "```\n" (4 chars)
        XCTAssertEqual(matches[0].fenceCloseRange, NSRange(location: 9, length: 4), "Close fence '```\\n' at index 9, length 4")
    }

    // MARK: - Fenced code edge cases

    func test_fenced_unterminated_returnsEmpty() {
        let matches = MarkdownInlineParser.findFencedCodeBlocks(in: "```\ncode")
        XCTAssertTrue(matches.isEmpty, "Unterminated fenced code block must return empty")
    }

    // MARK: - UTF-16 sanity (mandatory)

    func test_bold_emojiContentUsesUTF16Units() {
        // "pre **🎉** post"
        // "pre " = 4 UTF-16 units
        // "**"   = 2 UTF-16 units (open marker, at index 4)
        // "🎉"   = 2 UTF-16 units (surrogate pair, content at index 6)
        // "**"   = 2 UTF-16 units (close marker, at index 8)
        // " post" = 5 UTF-16 units
        let body = "pre **🎉** post"
        XCTAssertEqual((body as NSString).length, 15, "Sanity: body is 15 UTF-16 units (4+2+2+2+5)")
        let matches = MarkdownInlineParser.findBoldRanges(in: body)
        XCTAssertEqual(matches.count, 1, "Should find one bold pair containing emoji")
        XCTAssertEqual(matches[0].markerOpenRange.location, 4, "Open marker starts at UTF-16 index 4")
        XCTAssertEqual(matches[0].contentRange.location, 6, "Emoji content starts at UTF-16 index 6")
        XCTAssertEqual(matches[0].contentRange.length, 2, "Emoji 🎉 is 2 UTF-16 units (surrogate pair), NOT 1")
        XCTAssertEqual(matches[0].markerCloseRange.location, 8, "Close marker starts at UTF-16 index 8")
    }
}
