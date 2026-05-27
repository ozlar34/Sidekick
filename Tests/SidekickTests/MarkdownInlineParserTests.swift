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
        // "** **" is a degenerate whitespace-only pair. The implementation skips it
        // (whitespace-only content guard in findBoldRanges). Pinning the chosen
        // behavior: skip = 0 matches. No crash, deterministic.
        let matches = MarkdownInlineParser.findBoldRanges(in: "** **")
        XCTAssertEqual(matches.count, 0, "Degenerate whitespace-only pair must be skipped (D-T-01)")
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

    // MARK: - Link tests (D-T-01, HYBRID-07 parser layer)

    func test_link_basicPair() {
        let body = "prefix [Google](https://google.com) suffix"
        let matches = MarkdownInlineParser.findLinkRanges(in: body)
        XCTAssertEqual(matches.count, 1, "Should find exactly one link pair")
        let m = matches[0]
        XCTAssertEqual(m.openBracketRange, NSRange(location: 7, length: 1))
        XCTAssertEqual(m.labelRange, NSRange(location: 8, length: 6), "Label 'Google' at index 8, length 6")
        XCTAssertEqual(m.closeBracketRange, NSRange(location: 14, length: 1))
        XCTAssertEqual(m.openParenRange, NSRange(location: 15, length: 1))
        XCTAssertEqual(m.urlRange, NSRange(location: 16, length: 18), "URL 'https://google.com' at 16, length 18")
        XCTAssertEqual(m.closeParenRange, NSRange(location: 34, length: 1))
    }

    func test_link_unclosed_returnsEmpty() {
        let matches = MarkdownInlineParser.findLinkRanges(in: "[foo](")
        XCTAssertTrue(matches.isEmpty, "Unclosed link must return empty (D-LR-01 pair-only-hide)")
    }

    func test_link_missingURLParens_returnsEmpty() {
        let matches = MarkdownInlineParser.findLinkRanges(in: "[foo]")
        XCTAssertTrue(matches.isEmpty, "[foo] with no paren group must return empty")
    }

    func test_link_emptyURL_stillMatches() {
        let body = "[foo]()"
        let matches = MarkdownInlineParser.findLinkRanges(in: body)
        XCTAssertEqual(matches.count, 1, "[foo]() is a valid closed pair with empty URL")
        let m = matches[0]
        XCTAssertEqual(m.urlRange.length, 0, "Empty URL has length 0")
        XCTAssertEqual(m.closeParenRange, NSRange(location: 6, length: 1))
    }

    func test_link_newlineInURL_rejected() {
        let body = "[foo](http://\nx)"
        let matches = MarkdownInlineParser.findLinkRanges(in: body)
        XCTAssertTrue(matches.isEmpty, "Newline in URL must reject per D-LR-06 pattern")
    }

    func test_link_unescapedCloseBracket_breaksLabel() {
        // D-LR-01 pair-only-hide: label group [^\]\n]+ excludes ']', so the first ']'
        // terminates the label capture. Input "[fo]o](x)" traces as follows:
        //   pos 0: '[' matches; label consumes "fo" (stops at ']' at pos 3);
        //   ']' at pos 3 matches; regex needs '(' at pos 4 but finds 'o' — fails.
        //   Engine retries at later positions: no other '[' remains → 0 matches overall.
        // This documents the behavior: an unescaped ']' inside what the user intended
        // as the label truncates the pattern, keeping the whole string as plain text
        // (matches D-LR-01 pair-only-hide intent).
        let matches = MarkdownInlineParser.findLinkRanges(in: "[fo]o](x)")
        XCTAssertTrue(matches.isEmpty,
                      "Unescaped ']' inside intended label must break the pattern (D-LR-01 pair-only-hide)")
    }

    func test_link_emojiLabelUTF16Safe() {
        // Emoji 🎉 is 2 UTF-16 code units
        let body = "[🎉](x)"
        let matches = MarkdownInlineParser.findLinkRanges(in: body)
        XCTAssertEqual(matches.count, 1)
        let m = matches[0]
        XCTAssertEqual(m.openBracketRange, NSRange(location: 0, length: 1))
        XCTAssertEqual(m.labelRange.length, 2, "Emoji label is 2 UTF-16 code units")
        XCTAssertEqual(m.urlRange.location, 5, "URL starts after '[🎉](' = 5 UTF-16 code units in")
    }

    // MARK: - Tables happy path

    func test_table_simple() {
        // Header  "| h1 | h2 |" + "\n"        → 12 UTF-16 units
        // Sep     "| --- | --- |" + "\n"      → 14 UTF-16 units (location 12, length 14)
        // Body    "| a | b |" + "\n"          → 10 UTF-16 units (location 26, length 10)
        let body = "| h1 | h2 |\n| --- | --- |\n| a | b |\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertEqual(matches.count, 1, "Should find exactly one table block")
        let m = matches[0]
        XCTAssertEqual(m.headerRange, NSRange(location: 0, length: 11),
                       "Header excludes its trailing newline")
        XCTAssertEqual(m.separatorRange, NSRange(location: 12, length: 14),
                       "Separator INCLUDES its trailing newline so the layout collapses the row")
        XCTAssertEqual(m.bodyRange, NSRange(location: 26, length: 10),
                       "Body covers the trailing pipe-line including its newline")
        XCTAssertEqual(m.pipeRanges.count, 6, "3 pipes in header + 3 pipes in body = 6 total")
    }

    func test_table_headerSeparatorOnly_emptyBody() {
        let body = "| h1 | h2 |\n| --- | --- |\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].bodyRange.length, 0, "Body must be length 0 when no body rows present")
    }

    func test_table_alignmentColons_recognized() {
        // GFM alignment markers (`:---`, `:---:`, `---:`) must still parse as separator.
        let body = "| left | center | right |\n| :--- | :---: | ---: |\n| a | b | c |\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertEqual(matches.count, 1, "Alignment colons are valid separator syntax")
    }

    func test_table_noOuterPipes_recognized() {
        // GFM allows separator and body lines without outer pipes.
        let body = "h1 | h2\n--- | ---\na | b\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertEqual(matches.count, 1, "Tables without outer pipes still parse")
    }

    // MARK: - Tables negative cases

    func test_table_noSeparator_rejected() {
        // Two pipe lines with no separator between them are NOT a table.
        let body = "| h1 | h2 |\n| a | b |\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertTrue(matches.isEmpty, "Pair without separator must not parse as table (D-MH-04 pair principle)")
    }

    func test_table_horizontalRule_notSeparator() {
        // A line that's just "---" (no pipes) is a horizontal rule, not a separator.
        let body = "h1 | h2\n---\na | b\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertTrue(matches.isEmpty, "`---` without `|` must not be treated as table separator")
    }

    func test_table_pipesOnly_notSeparator() {
        // A line that's "|||" has pipes but no dashes — not a separator.
        let body = "| h1 | h2 |\n|||\n| a | b |\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertTrue(matches.isEmpty, "Pipes-without-dashes must not be treated as separator")
    }

    func test_table_insideFencedBlock_ignored() {
        // Table syntax inside a fenced code block must NOT parse as a table —
        // fenced blocks must preserve their content visually (no row collapse).
        let body = "```\n| h1 | h2 |\n| --- | --- |\n| a | b |\n```\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertTrue(matches.isEmpty, "Tables inside fenced code blocks must be ignored")
    }

    // MARK: - Tables — UTF-16 / multi-table

    func test_table_multipleTablesInDocument() {
        let body = """
        | a | b |
        | --- | --- |
        | 1 | 2 |

        Some text between tables.

        | x | y |
        | --- | --- |
        | 9 | 8 |
        """
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertEqual(matches.count, 2, "Two distinct tables in one document must produce two matches")
    }

    func test_table_emojiInCell_utf16Safe() {
        // 🎉 is 2 UTF-16 code units. Pipe positions must remain UTF-16-correct.
        let body = "| 🎉 | x |\n| --- | --- |\n"
        let matches = MarkdownInlineParser.findTableBlocks(in: body)
        XCTAssertEqual(matches.count, 1)
        let m = matches[0]
        // Header: "| 🎉 | x |" = 1 + 1 + 2 + 1 + 1 + 1 + 1 + 1 + 1 = 10 UTF-16 units
        XCTAssertEqual(m.headerRange.length, 10, "Emoji header must measure in UTF-16 units")
        // 3 pipes in header (no body in this fixture)
        XCTAssertEqual(m.pipeRanges.count, 3)
    }

    // MARK: - Thematic breaks (`---` / `***` / `___`)

    func test_thematicBreak_dashes_atDocStart() {
        // First line of a doc: prev-line check passes via the location==0 short-circuit.
        let matches = MarkdownInlineParser.findThematicBreaks(in: "---\n")
        XCTAssertEqual(matches.count, 1, "Dashes at doc start must match")
        XCTAssertEqual(matches[0], NSRange(location: 0, length: 3), "Range covers `---` without trailing newline")
    }

    func test_thematicBreak_afterBlankLine() {
        // Standard usage: paragraph, blank line, ---, blank line.
        let body = "Paragraph.\n\n---\n\nAfter."
        let matches = MarkdownInlineParser.findThematicBreaks(in: body)
        XCTAssertEqual(matches.count, 1, "Thematic break separated by blank lines must match")
        // `---` starts at offset 12: "Paragraph.\n\n" = 10 + 1 + 1 = 12
        XCTAssertEqual(matches[0], NSRange(location: 12, length: 3))
    }

    func test_thematicBreak_underNonEmptyLine_stillMatches() {
        // CommonMark would treat `Title\n---` as a setext H2 underline, but
        // Sidekick does not render setext headings — and a user-visible bug
        // (HR appears then vanishes on note switch) followed from the earlier
        // prev-line-empty guard. We now treat any qualifying `---` line as
        // an HR regardless of what's above.
        let matches = MarkdownInlineParser.findThematicBreaks(in: "Title\n---\n")
        XCTAssertEqual(matches.count, 1, "`---` under a non-empty line must still match (no setext-H2 guard)")
        XCTAssertEqual(matches[0], NSRange(location: 6, length: 3))
    }

    func test_thematicBreak_dashesOnly_asterisksAndUnderscoresExcluded() {
        // We deliberately diverge from CommonMark: only `-` runs create an HR.
        // `***` was indistinguishable from a bold-italic transition (`**` +
        // `**`) and produced surprise rules.
        XCTAssertTrue(MarkdownInlineParser.findThematicBreaks(in: "***\n").isEmpty,
                      "Asterisks must NOT create a thematic break")
        XCTAssertTrue(MarkdownInlineParser.findThematicBreaks(in: "****\n").isEmpty,
                      "Four asterisks must NOT create a thematic break")
        XCTAssertTrue(MarkdownInlineParser.findThematicBreaks(in: "___\n").isEmpty,
                      "Underscores must NOT create a thematic break")
        XCTAssertEqual(MarkdownInlineParser.findThematicBreaks(in: "----\n").count, 1,
                       "Four dashes still qualify")
    }

    func test_thematicBreak_mixedChars_doesNotMatch() {
        // Mixed character classes (e.g. `-*-`) are not a thematic break.
        XCTAssertTrue(MarkdownInlineParser.findThematicBreaks(in: "-*-\n").isEmpty)
        XCTAssertTrue(MarkdownInlineParser.findThematicBreaks(in: "--\n").isEmpty,
                      "Two dashes is not enough — minimum is three")
    }

    // MARK: - Thematic breaks — fenced-code-block fence awareness (260524-hul)

    func test_thematicBreak_insideFence_blankLineBefore_doesNotMatch() {
        // Exact repro shape from the bug report: a fenced code block whose
        // content contains a blank line followed by `---`. The parser must
        // NOT tag the `---` as a thematic break — it is source text inside
        // a code block. Pre-fix this returned 1 range and the storage layer
        // drew a hairline through the code block.
        let body = "```\ncode\n\n---\nmore code\n```\n"
        let matches = MarkdownInlineParser.findThematicBreaks(in: body)
        XCTAssertTrue(matches.isEmpty,
                      "`---` inside a fence content range must not be a thematic break")
    }

    func test_thematicBreak_outsideFence_stillMatches_aroundFence() {
        // Closing fence, blank line, then `---`. The filter only excludes
        // fence *content*, so a `---` that lives strictly after the closing
        // fence line must still be tagged as a thematic break.
        let body = "```\ncode\n```\n\n---\n"
        let matches = MarkdownInlineParser.findThematicBreaks(in: body)
        XCTAssertEqual(matches.count, 1,
                       "`---` after the closing fence must still match — filter only excludes fence *content*")
        // `---` starts at offset 13: "```\ncode\n```\n\n" = 4 + 5 + 4 + 1 = 14? Recompute:
        // "```\n" = 4, "code\n" = 5, "```\n" = 4, "\n" = 1 → total before `---` = 14? Let's compute UTF-16 length precisely.
        // ns.length of prefix "```\ncode\n```\n\n" = 14. So `---` at 14.
        XCTAssertEqual(matches[0], NSRange(location: 14, length: 3),
                       "Range covers `---` line content after the closing fence")
    }

    func test_thematicBreak_unterminatedFence_blankDashLine_stillMatches() {
        // Per findFencedCodeBlocks doc (line 791), an unterminated fence
        // yields NO match. The thematic-break filter therefore has nothing
        // to subtract, and the `---` is still an HR. Consistent with how
        // findTableBlocks (line ~875) treats unterminated fences.
        let body = "```\n\n---\n"
        let matches = MarkdownInlineParser.findThematicBreaks(in: body)
        XCTAssertEqual(matches.count, 1,
                       "Unterminated fence yields no FencedCodeMatch → `---` outside any tracked fence is still a thematic break")
    }
}
