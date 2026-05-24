import XCTest
import AppKit
@testable import Sidekick

/// Pins the pure string-transformation contract that backs the
/// markdown formatting toolbar. Tests exercise
/// `FormattingToolbarView.applyMarkdownWrap(prefix:suffix:body:range:)`
/// without involving NSTextView or SwiftUI, so they run fast and
/// deterministically on any CI.
final class FormattingToolbarTests: XCTestCase {

    func test_nonEmptySelection_boldWrap() {
        let (newBody, cursor) = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "hello world",
            range: NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(newBody, "**hello** world")
        XCTAssertEqual(cursor, 9, "Cursor after inserted **hello**")
    }

    func test_emptySelection_boldInsertsMarkersAndCursorBetween() {
        let (newBody, cursor) = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "hello",
            range: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(newBody, "hello****")
        XCTAssertEqual(cursor, 7, "Cursor between the two ** markers (5 + prefix.utf16=2 = 7)")
    }

    func test_italicWrap_singleCharMarkers() {
        let (newBody, cursor) = FormattingToolbarView.applyMarkdownWrap(
            prefix: "*", suffix: "*",
            body: "abc",
            range: NSRange(location: 0, length: 3)
        )
        XCTAssertEqual(newBody, "*abc*")
        XCTAssertEqual(cursor, 5)
    }

    func test_linkEmptySelection_cursorLandsInsideBrackets() {
        let (newBody, cursor) = FormattingToolbarView.applyMarkdownWrap(
            prefix: "[", suffix: "]()",
            body: "",
            range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(newBody, "[]()")
        XCTAssertEqual(cursor, 1, "Cursor inside [] so user can type link text first")
    }

    func test_inlineCode_emojiSelectionUsesUTF16Units() {
        // "café 🎉" — emoji is a surrogate pair (2 UTF-16 units).
        // We select just the emoji: starts at index 5 (after "café "), length 2.
        let body = "café 🎉"
        XCTAssertEqual((body as NSString).length, 7, "Sanity: body is 7 UTF-16 units")
        let (newBody, cursor) = FormattingToolbarView.applyMarkdownWrap(
            prefix: "`", suffix: "`",
            body: body,
            range: NSRange(location: 5, length: 2)
        )
        XCTAssertEqual(newBody, "café `🎉`")
        XCTAssertEqual(cursor, 9, "5 + prefix=1 + selection=2 + suffix=1 = 9")
    }

    func test_midBodySelection_preservesSurroundingText() {
        let (newBody, cursor) = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "hello world foo",
            range: NSRange(location: 6, length: 5)   // "world"
        )
        XCTAssertEqual(newBody, "hello **world** foo")
        XCTAssertEqual(cursor, 15, "6 + prefix=2 + selection=5 + suffix=2 = 15")
    }

    // MARK: - applyBulletedList (bulleted-list toggle)
    //
    // Apple Notes / Bear convention: ⌘⇧8 prepends "- " to every line in the
    // selection; if every non-empty line in the selection ALREADY starts with
    // "- ", it strips the prefix (toggle off). Mixed lines → all get a prefix
    // (spec case 5 — NOT toggle off).

    func test_applyBulletedList_emptySelection_cursorMidWord_insertsPrefixAtLineStart() {
        // Caret sits at index 6 (between "hello " and "world"). The prefix
        // must land at the START of the enclosing line, NOT at the caret.
        let (newBody, newSelection) = FormattingToolbarView.applyBulletedList(
            body: "hello world",
            range: NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(newBody, "- hello world",
                       "Prefix lands at line start — caret position does NOT affect insertion point")
        XCTAssertEqual(newSelection.location, 0, "newSelection starts at line-block start")
        XCTAssertEqual(newSelection.length, 13, "newSelection covers the transformed line")
    }

    func test_applyBulletedList_singleLineSelection_addsPrefix() {
        let (newBody, newSelection) = FormattingToolbarView.applyBulletedList(
            body: "hello",
            range: NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(newBody, "- hello")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 7))
    }

    func test_applyBulletedList_multiLineSelection_prefixesEveryLine() {
        // Body is 13 UTF-16 units: "one\ntwo\nthree" → (3 + 1 + 3 + 1 + 5) = 13
        let (newBody, newSelection) = FormattingToolbarView.applyBulletedList(
            body: "one\ntwo\nthree",
            range: NSRange(location: 0, length: 13)
        )
        XCTAssertEqual(newBody, "- one\n- two\n- three")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 19),
                       "3 lines × 2 extra chars per line = +6 over 13 = 19")
    }

    func test_applyBulletedList_allLinesPrefixed_stripsPrefix() {
        // All lines prefixed → toggle off.
        let (newBody, newSelection) = FormattingToolbarView.applyBulletedList(
            body: "- one\n- two\n- three",
            range: NSRange(location: 0, length: 19)
        )
        XCTAssertEqual(newBody, "one\ntwo\nthree")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 13))
    }

    func test_applyBulletedList_mixedLines_addsPrefixToAll_doesNotToggleOff() {
        // Spec case 5: mixed → ALL get another "- " prefix (NOT toggle off).
        // Body: "- one\ntwo\n- three" → 6 + 1 + 3 + 1 + 7 = 18 UTF-16 units.
        // Wait: "- one" = 5 units, + "\n" = 6, + "two" = 9, + "\n" = 10, + "- three" = 17.
        let (newBody, newSelection) = FormattingToolbarView.applyBulletedList(
            body: "- one\ntwo\n- three",
            range: NSRange(location: 0, length: 17)
        )
        XCTAssertEqual(newBody, "- - one\n- two\n- - three",
                       "Mixed → every line (including already-prefixed ones) gets an extra '- ' prepended")
        // Original 17 units + 3 lines × 2 chars = 17 + 6 = 23 units.
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 23))
    }

    func test_applyBulletedList_midBodySelection_preservesSurroundingText() {
        // Body: "intro\nfoo\nbar\noutro" → 5 + 1 + 3 + 1 + 3 + 1 + 5 = 19 units.
        // Selection covers "foo\nbar" at loc=6 len=7.
        let (newBody, newSelection) = FormattingToolbarView.applyBulletedList(
            body: "intro\nfoo\nbar\noutro",
            range: NSRange(location: 6, length: 7)
        )
        XCTAssertEqual(newBody, "intro\n- foo\n- bar\noutro",
                       "Only the foo/bar block is transformed; intro/outro lines untouched")
        // lineRange(for:) expands the block to include the trailing "\n" after
        // "bar" (standard NSString line-range contract). The transformed block
        // is "- foo\n- bar\n" = 12 UTF-16 units starting at index 6.
        XCTAssertEqual(newSelection, NSRange(location: 6, length: 12))
    }

    // MARK: - Toggle-off tests (D-T-03, UI-AUDIT-P1-4)

    func test_toggleOff_bold_wrappedSelection_strips() {
        // body "**foo**" — selection of "foo" at (2, 3)
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "**foo**",
            range: NSRange(location: 2, length: 3)
        )
        XCTAssertEqual(result.newBody, "foo", "Bold wrap stripped from wrapped selection")
        XCTAssertEqual(result.cursorLocation, 0, "Cursor at start of stripped span")
    }

    func test_toggleOff_italicAsterisk_strips() {
        // body "*foo*" — selection "foo" at (1, 3), invoke with prefix/suffix "*"
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "*", suffix: "*",
            body: "*foo*",
            range: NSRange(location: 1, length: 3)
        )
        XCTAssertEqual(result.newBody, "foo")
        XCTAssertEqual(result.cursorLocation, 0)
    }

    func test_toggleOff_italicUnderscore_stripsViaCmdI() {
        // body "_foo_" — user hits ⌘I (which inserts "*"); D-TG-04 allows strip of "_" wrapper
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "*", suffix: "*",
            body: "_foo_",
            range: NSRange(location: 1, length: 3)
        )
        XCTAssertEqual(result.newBody, "foo", "⌘I on _foo_ strips underscores per D-TG-04")
        XCTAssertEqual(result.cursorLocation, 0)
    }

    func test_toggleOff_inlineCode_strips() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "`", suffix: "`",
            body: "`foo`",
            range: NSRange(location: 1, length: 3)
        )
        XCTAssertEqual(result.newBody, "foo")
        XCTAssertEqual(result.cursorLocation, 0)
    }

    // F-01 — Underline `<u>…</u>` toggle-off. Pre-fix, repeated ⌘U stacked
    // tags `<u><u>foo</u></u>` because the parser hookup was missing.
    func test_toggleOff_underline_strips() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "<u>", suffix: "</u>",
            body: "<u>foo</u>",
            range: NSRange(location: 3, length: 3)
        )
        XCTAssertEqual(result.newBody, "foo", "Underline pair stripped from wrapped selection")
        XCTAssertEqual(result.cursorLocation, 0, "Cursor at start of stripped span")
    }

    func test_toggleOff_underline_caretOnly_insideTags_strips() {
        // Caret between the two o's of `<u>foo</u>` (body index 5). ⌘U strips.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "<u>", suffix: "</u>",
            body: "<u>foo</u>",
            range: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(result.newBody, "foo")
        // Caret at index 5 in old body sits between the o's; after stripping
        // the 3-char open marker, that gap sits at index 2 in the new body.
        XCTAssertEqual(result.cursorLocation, 2)
    }

    // F-02 — Strikethrough `~~…~~` toggle-off.
    func test_toggleOff_strikethrough_strips() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "~~", suffix: "~~",
            body: "~~foo~~",
            range: NSRange(location: 2, length: 3)
        )
        XCTAssertEqual(result.newBody, "foo", "Strikethrough pair stripped")
        XCTAssertEqual(result.cursorLocation, 0)
    }

    func test_toggleOff_strikethrough_caretOnly_insideTags_strips() {
        // Caret at body index 4 (between o's of `~~foo~~`).
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "~~", suffix: "~~",
            body: "~~foo~~",
            range: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(result.newBody, "foo")
        XCTAssertEqual(result.cursorLocation, 2)
    }

    // Strikethrough/underline are orthogonal to the bold/italic/code mutex
    // set — pressing ⌘B on `~~foo~~` content must NOT swap markers; it
    // should fall through to the wrap path so the new bold markers stack
    // around the existing strikethrough span.
    func test_strikethroughPair_boldWrap_doesNotSwap_stacks() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "~~foo~~",
            range: NSRange(location: 2, length: 3)
        )
        // The wrap path runs against the selected content "foo", inserting
        // `**foo**` in place of the selection — leaving the surrounding
        // `~~ ~~` markers untouched.
        XCTAssertEqual(result.newBody, "~~**foo**~~",
                       "Bold wrap on strike-enclosed selection stacks; does not swap")
    }

    func test_underlinePair_boldWrap_doesNotSwap_stacks() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "<u>foo</u>",
            range: NSRange(location: 3, length: 3)
        )
        XCTAssertEqual(result.newBody, "<u>**foo**</u>",
                       "Bold wrap on underline-enclosed selection stacks; does not swap")
    }

    // activeInlineKind reports underline/strikethrough so the popover
    // buttons can highlight when the caret sits inside the corresponding pair.
    func test_activeInlineKind_reportsUnderline_whenCaretInsideUTags() {
        let kind = FormattingToolbarView.activeInlineKind(
            body: "<u>foo</u>",
            selection: NSRange(location: 4, length: 0)  // mid 'foo'
        )
        XCTAssertEqual(kind, .underline)
    }

    func test_activeInlineKind_reportsStrikethrough_whenCaretInsideTildes() {
        let kind = FormattingToolbarView.activeInlineKind(
            body: "~~foo~~",
            selection: NSRange(location: 4, length: 0)  // mid 'foo'
        )
        XCTAssertEqual(kind, .strikethrough)
    }

    func test_swap_italicToBold_replacesMarkers() {
        // body "*foo*" — invoke ⌘B (prefix/suffix "**") — different inline kind on
        // the selection → swap the markers, keep inner text. Inline formats are
        // mutually exclusive at toggle time (no ***foo*** compose).
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "*foo*",
            range: NSRange(location: 1, length: 3)
        )
        XCTAssertEqual(result.newBody, "**foo**", "Swap: italic pair replaced by bold markers, inner 'foo' preserved")
        // Cursor lands inside the new bold pair at the same offset within
        // 'foo' that the user's caret had in the old inner (here: start).
        // pair.whole.location (0) + newPrefixLen (2) + caretOffsetInInner (0) = 2
        XCTAssertEqual(result.cursorLocation, 2)
    }

    func test_toggleOff_caretOnly_insideBoldPair_strips() {
        // Caret between the two o's of "**foo**" (position 4). ⌘B should strip
        // the surrounding `**` pair; caret stays against the same character.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "**foo**",
            range: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(result.newBody, "foo")
        // Caret was at body index 4 (between the two o's); after stripping the
        // two-char open marker the same gap sits at index 2 in the new body.
        XCTAssertEqual(result.cursorLocation, 2)
    }

    func test_toggleOff_caretOnly_outsideBold_isAdditive() {
        // Caret at body start (before any bold span) — no enclosing pair, so
        // falls through to additive `****` insert.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "hello",
            range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(result.newBody, "****hello")
        XCTAssertEqual(result.cursorLocation, 2)
    }

    func test_toggleOff_selectionWrapsBoldMarkers_strips() {
        // Triple-click / ⌘A case: selection covers "**foo**" including markers.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "**foo**",
            range: NSRange(location: 0, length: 7)
        )
        XCTAssertEqual(result.newBody, "foo")
        XCTAssertEqual(result.cursorLocation, 0)
    }

    func test_toggleOff_selectionWrapsItalicUnderscore_cmdI_strips() {
        // Selection covers "_foo_" (with underscores); user hits ⌘I (prefix="*").
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "*", suffix: "*",
            body: "_foo_",
            range: NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(result.newBody, "foo")
        XCTAssertEqual(result.cursorLocation, 0)
    }

    func test_toggleOff_caretOnly_insideInlineCode_strips() {
        // Caret inside `` `foo` ``.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "`", suffix: "`",
            body: "`foo`",
            range: NSRange(location: 3, length: 0)
        )
        XCTAssertEqual(result.newBody, "foo")
        XCTAssertEqual(result.cursorLocation, 2)
    }

    // MARK: - Link cursor UX tests (D-T-04, D-UX-01)

    func test_link_nonEmptySelection_cursorLandsInsideParens() {
        // body "hello world" — selection "hello" at (0, 5) — prefix "[" suffix "]()"
        // Expected: insert "[hello]()" → newBody "[hello]() world"
        // Cursor inside () = 0 + 1 (for "[") + 5 (for "hello") + 2 (for "](") = 8
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "[", suffix: "]()",
            body: "hello world",
            range: NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(result.newBody, "[hello]() world")
        XCTAssertEqual(result.cursorLocation, 8, "Cursor inside () at position 8 (between ]( and ))")
    }

    func test_link_emptySelection_preservesExistingBracketsCursor() {
        // Ensures existing empty-selection behavior unchanged (test_linkEmptySelection_cursorLandsInsideBrackets equivalent)
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "[", suffix: "]()",
            body: "abc",
            range: NSRange(location: 3, length: 0)
        )
        XCTAssertEqual(result.newBody, "abc[]()")
        XCTAssertEqual(result.cursorLocation, 4, "Empty-selection cursor stays between [] — unchanged from pre-Phase-10")
    }

    // MARK: - Inline-format swap (different-kind toggle)

    func test_swap_boldToItalic_replacesMarkers() {
        // "**hello**" + ⌘I → "*hello*". Selection covers inner 'hello'.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "*", suffix: "*",
            body: "**hello**",
            range: NSRange(location: 2, length: 5)
        )
        XCTAssertEqual(result.newBody, "*hello*")
        XCTAssertEqual(result.cursorLocation, 1, "Cursor inside the new italic pair at the inner offset (0)")
    }

    func test_swap_boldToCode_replacesMarkers() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "`", suffix: "`",
            body: "**hello**",
            range: NSRange(location: 2, length: 5)
        )
        XCTAssertEqual(result.newBody, "`hello`")
        XCTAssertEqual(result.cursorLocation, 1)
    }

    func test_swap_codeToBold_replacesMarkers() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "`hello`",
            range: NSRange(location: 1, length: 5)
        )
        XCTAssertEqual(result.newBody, "**hello**")
        XCTAssertEqual(result.cursorLocation, 2)
    }

    func test_swap_italicUnderscoreToBold_replacesMarkers() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "_hello_",
            range: NSRange(location: 1, length: 5)
        )
        XCTAssertEqual(result.newBody, "**hello**")
        XCTAssertEqual(result.cursorLocation, 2)
    }

    func test_swap_boldToItalic_caretOnly_insidePair() {
        // Caret-only selection inside a bolded word also triggers swap.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "*", suffix: "*",
            body: "**hello**",
            range: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(result.newBody, "*hello*")
        // Caret was at inner offset 2 (inside "he|llo"); preserved inside new pair.
        XCTAssertEqual(result.cursorLocation, 3)
    }

    func test_swap_preservesSurroundingText() {
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "*", suffix: "*",
            body: "pre **hello** post",
            range: NSRange(location: 6, length: 5)
        )
        XCTAssertEqual(result.newBody, "pre *hello* post")
    }

    func test_link_overBold_doesNotSwap_additiveWrap() {
        // ⌘K over a bolded selection should NOT strip the bold — link is not
        // an inline-format kind and participates only in additive wrap.
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "[", suffix: "]()",
            body: "**hello**",
            range: NSRange(location: 2, length: 5)
        )
        XCTAssertEqual(result.newBody, "**[hello]()**", "Link wraps inside bold; bold markers preserved")
    }

    // MARK: - activeInlineKind (toolbar active-state highlight detector)

    func test_activeInlineKind_caretInsideBold_returnsBold() {
        // "**bold**" — caret inside the inner text. Expect .bold.
        let kind = FormattingToolbarView.activeInlineKind(
            body: "**bold**",
            selection: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(kind, .bold)
    }

    func test_activeInlineKind_caretInsideItalic_returnsItalic() {
        // "*it*" — caret between the markers. Expect .italic.
        let kind = FormattingToolbarView.activeInlineKind(
            body: "hello *it* world",
            selection: NSRange(location: 8, length: 0)
        )
        XCTAssertEqual(kind, .italic)
    }

    func test_activeInlineKind_caretInsideCode_returnsCode() {
        // "`code`" — caret inside backticks. Expect .code.
        let kind = FormattingToolbarView.activeInlineKind(
            body: "before `code` after",
            selection: NSRange(location: 9, length: 0)
        )
        XCTAssertEqual(kind, .code)
    }

    func test_activeInlineKind_caretInPlainText_returnsNil() {
        // No formatting markers around the caret. Expect nil — no button
        // should highlight as active.
        let kind = FormattingToolbarView.activeInlineKind(
            body: "plain unformatted text",
            selection: NSRange(location: 5, length: 0)
        )
        XCTAssertNil(kind)
    }

    // MARK: - applyHeadingLevel (heading dropdown)
    //
    // Heading dropdown spec:
    //   • level=1..3 on plain line  → prepend "# ", "## ", or "### ".
    //   • level=N on line already at level N → strip (toggle off, mirrors bullet).
    //   • level=N on line at different level → swap prefix (level change).
    //   • level=nil on heading line → strip (force Body).
    //   • level=nil on plain line → no-op.
    //   • Multi-line: same rules applied per line as a block.

    func test_applyHeadingLevel_emptySelectionPlainLine_appliesH1() {
        let (newBody, newSelection) = FormattingToolbarView.applyHeadingLevel(
            body: "hello",
            range: NSRange(location: 3, length: 0),
            level: 1
        )
        XCTAssertEqual(newBody, "# hello")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 7))
    }

    func test_applyHeadingLevel_emptySelectionH2Line_levelTwo_togglesOffToBody() {
        // Caret on "## foo" line, picking Heading 2 → strip back to body.
        let (newBody, newSelection) = FormattingToolbarView.applyHeadingLevel(
            body: "## foo",
            range: NSRange(location: 4, length: 0),
            level: 2
        )
        XCTAssertEqual(newBody, "foo", "Re-pick same level → toggle off (mirrors bullet)")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 3))
    }

    func test_applyHeadingLevel_h1Line_levelTwo_swapsPrefix() {
        // Caret on "# foo" line, picking Heading 2 → swap to "## foo".
        let (newBody, newSelection) = FormattingToolbarView.applyHeadingLevel(
            body: "# foo",
            range: NSRange(location: 3, length: 0),
            level: 2
        )
        XCTAssertEqual(newBody, "## foo", "Different level → swap, not toggle")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 6))
    }

    func test_applyHeadingLevel_multiLineMixed_appliesH3ToAll() {
        // Mixed: plain, H1, H2 → all become H3 (not toggle, prefix swaps per line).
        // "plain\n# h1\n## h2" → 5 + 1 + 4 + 1 + 5 = 16 UTF-16 units.
        let (newBody, _) = FormattingToolbarView.applyHeadingLevel(
            body: "plain\n# h1\n## h2",
            range: NSRange(location: 0, length: 16),
            level: 3
        )
        XCTAssertEqual(newBody, "### plain\n### h1\n### h2",
                       "Mixed levels → all swapped to requested level")
    }

    func test_applyHeadingLevel_multiLineAllH2_levelTwo_togglesOff() {
        // All non-empty lines at H2 → picking H2 strips them all.
        // "## a\n## b\n## c" = 4 + 1 + 4 + 1 + 4 = 14 UTF-16 units.
        let (newBody, _) = FormattingToolbarView.applyHeadingLevel(
            body: "## a\n## b\n## c",
            range: NSRange(location: 0, length: 14),
            level: 2
        )
        XCTAssertEqual(newBody, "a\nb\nc", "All-same-level → toggle off whole block")
    }

    func test_applyHeadingLevel_levelNil_onHeadingLine_stripsToBody() {
        let (newBody, newSelection) = FormattingToolbarView.applyHeadingLevel(
            body: "### foo",
            range: NSRange(location: 4, length: 0),
            level: nil
        )
        XCTAssertEqual(newBody, "foo", "Body action strips heading prefix")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 3))
    }

    func test_applyHeadingLevel_levelNil_onPlainLine_isNoOp() {
        let body = "already plain"
        let (newBody, _) = FormattingToolbarView.applyHeadingLevel(
            body: body,
            range: NSRange(location: 5, length: 0),
            level: nil
        )
        XCTAssertEqual(newBody, body, "Body action on plain line leaves the line unchanged")
    }

    func test_applyHeadingLevel_emptyBody_levelOne_producesPrefixOnly() {
        let (newBody, newSelection) = FormattingToolbarView.applyHeadingLevel(
            body: "",
            range: NSRange(location: 0, length: 0),
            level: 1
        )
        XCTAssertEqual(newBody, "# ", "Empty body + H1 → just the prefix")
        XCTAssertEqual(newSelection, NSRange(location: 0, length: 2))
    }

    func test_applyHeadingLevel_midBodySelection_preservesSurroundingLines() {
        // Body: "intro\nfoo\nbar\noutro" → 5+1+3+1+3+1+5 = 19 units.
        // Selection covers "foo\nbar" at loc=6 len=7.
        let (newBody, _) = FormattingToolbarView.applyHeadingLevel(
            body: "intro\nfoo\nbar\noutro",
            range: NSRange(location: 6, length: 7),
            level: 2
        )
        XCTAssertEqual(newBody, "intro\n## foo\n## bar\noutro",
                       "Only the foo/bar block is transformed; intro/outro lines untouched")
    }

    func test_applyHeadingLevel_h4Line_levelThree_swapsToH3() {
        // H4 line (above the dropdown's offered range). Picking H3 should
        // swap the prefix to H3 — not stack hashes, not strip.
        let (newBody, _) = FormattingToolbarView.applyHeadingLevel(
            body: "#### deep",
            range: NSRange(location: 5, length: 0),
            level: 3
        )
        XCTAssertEqual(newBody, "### deep", "H4 → H3 swaps cleanly (existing prefix stripped before new added)")
    }

    // MARK: - F-03 — activeLinePrefix classifier

    func test_activeLinePrefix_bulletLine() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "- item",
            selection: NSRange(location: 3, length: 0)
        )
        XCTAssertEqual(prefix, .bullet)
    }

    func test_activeLinePrefix_starBulletLine() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "* item",
            selection: NSRange(location: 3, length: 0)
        )
        XCTAssertEqual(prefix, .bullet, "Asterisk-bullet recognized as bullet")
    }

    func test_activeLinePrefix_numberedLine() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "1. item",
            selection: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(prefix, .numbered)
    }

    func test_activeLinePrefix_multiDigitNumberedLine() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "42. item",
            selection: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(prefix, .numbered, "Multi-digit numeric prefix still classified as numbered")
    }

    func test_activeLinePrefix_uncheckedChecklist() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "- [ ] task",
            selection: NSRange(location: 7, length: 0)
        )
        XCTAssertEqual(prefix, .checklist, "Checklist wins over bullet (more specific match)")
    }

    func test_activeLinePrefix_checkedChecklist() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "- [x] task",
            selection: NSRange(location: 7, length: 0)
        )
        XCTAssertEqual(prefix, .checklist)
    }

    func test_activeLinePrefix_blockquoteLine() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "> quoted",
            selection: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(prefix, .blockquote)
    }

    func test_activeLinePrefix_plainLine_returnsNil() {
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "plain text",
            selection: NSRange(location: 4, length: 0)
        )
        XCTAssertNil(prefix)
    }

    func test_activeLinePrefix_classifiesEachLineIndependently() {
        // Caret on line 2 (a numbered line) of a 3-line buffer; answer must
        // be .numbered, not .bullet from line 1.
        let body = "- bullet\n1. numbered\n> quote"
        let line2Start = ("- bullet\n" as NSString).length
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: body,
            selection: NSRange(location: line2Start + 4, length: 0)
        )
        XCTAssertEqual(prefix, .numbered)
    }

    func test_activeLinePrefix_caretAtLineEnd_stillClassifies() {
        // Caret at the trailing newline boundary still resolves to the
        // line it just left.
        let prefix = FormattingToolbarView.activeLinePrefix(
            body: "- item\n",
            selection: NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(prefix, .bullet)
    }

    // MARK: - F-05 — wrap inside fenced code block is no-op

    func test_applyMarkdownWrap_insideFencedBlock_caretOnly_isNoOp() {
        // Body: "```\nfoo\n```\n" — caret mid-content (offset 5, between f/o/o).
        // ⌘B inside the fence must NOT mutate bytes.
        let body = "```\nfoo\n```\n"
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: body,
            range: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(result.newBody, body, "Wrap inside fenced block must be inert")
        XCTAssertEqual(result.cursorLocation, 5, "Cursor unchanged inside fenced block")
    }

    func test_applyMarkdownWrap_insideFencedBlock_selection_isNoOp() {
        // Selection covers "foo" (offset 4..7) inside the fence.
        let body = "```\nfoo\n```\n"
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: body,
            range: NSRange(location: 4, length: 3)
        )
        XCTAssertEqual(result.newBody, body, "Wrap on selection inside fenced block must be inert")
    }

    func test_applyMarkdownWrap_outsideFencedBlock_unaffected() {
        // Body has a fence, selection is in surrounding prose. Wrap proceeds.
        let body = "before\n```\ncode\n```\nafter"
        let beforeStart = 0
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: body,
            range: NSRange(location: beforeStart, length: 6)  // "before"
        )
        XCTAssertEqual(result.newBody, "**before**\n```\ncode\n```\nafter",
                       "Wrap outside the fence works as usual")
    }

    func test_applyMarkdownWrap_strikeInsideFencedBlock_isNoOp() {
        let body = "```\nfoo\n```\n"
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "~~", suffix: "~~",
            body: body,
            range: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(result.newBody, body, "Strikethrough wrap also inert inside fence")
    }

    // MARK: - performInsertThematicBreak fence awareness (260524-hul)

    /// Builds the minimum TextKit assembly so `performInsertThematicBreak`
    /// can be invoked against a real NSTextView. Mirrors the wiring used by
    /// `EditorInteractionTests.makeStack` (storage + MarkdownLayoutManager +
    /// container + NSTextView; `isRichText = false`).
    @MainActor
    private func makeTextViewStack(body: String, selection: NSRange) -> NSTextView {
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 400))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            textContainer: container
        )
        textView.isRichText = false
        if !body.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: body)
        }
        textView.setSelectedRange(selection)
        return textView
    }

    @MainActor
    func test_performInsertThematicBreak_caretInsideFence_noEdit() {
        // Caret placed inside the fence content (between `code` and the
        // closing fence). The toolbar HR button must be a silent no-op —
        // no string change, no selection change. Pre-fix, this manufactured
        // the bug by inserting `\n---\n\n`, which the parser then tagged
        // as an HR straight through the code block.
        let body = "```\ncode\n```\n"
        // contentRange covers "code\n" at offsets 4..9. Place caret at 8
        // (end of "code", before its trailing newline) — squarely inside.
        let caret = NSRange(location: 8, length: 0)
        let textView = makeTextViewStack(body: body, selection: caret)

        let stringBefore = textView.string
        let selectionBefore = textView.selectedRange()

        FormattingToolbarView.performInsertThematicBreak(in: textView)

        XCTAssertEqual(textView.string, stringBefore,
                       "Caret inside fence: no body mutation")
        XCTAssertEqual(textView.selectedRange(), selectionBefore,
                       "Caret inside fence: no selection mutation")
    }

    @MainActor
    func test_performInsertThematicBreak_caretOutsideFence_stillInserts() {
        // Caret at the end of the closing-fence line (location 12, just
        // before the trailing newline). Outside every fence content range
        // (contentRange spans offsets 4..<9), so normal insertion proceeds.
        // Pins no regression on the happy path.
        //   "```\n"  = 0..<4
        //   "code\n" = 4..<9   ← contentRange
        //   "```"   = 9..<12   ← closing fence line text
        //   "\n"    = 12..<13
        let body = "```\ncode\n```\n"
        let caret = NSRange(location: 12, length: 0)
        let textView = makeTextViewStack(body: body, selection: caret)

        let lengthBefore = (textView.string as NSString).length

        FormattingToolbarView.performInsertThematicBreak(in: textView)

        XCTAssertTrue(textView.string.contains("---"),
                      "Caret outside fence: `---` must be inserted")
        // Closing fence line has content + trailing newline → insertion is
        // "\n---\n\n" (length 6).
        let lengthAfter = (textView.string as NSString).length
        XCTAssertEqual(lengthAfter - lengthBefore, 6,
                       "Insertion shape `\\n---\\n\\n` adds exactly 6 UTF-16 units")
    }

    // MARK: - handleThematicBreakReturn (right-edge fix)
    //
    // The HR's `---` glyphs are zero-width; the caret-shift in
    // `HybridTextView.drawInsertionPoint` makes any offset > 0 visually anchor
    // to the right edge of the hairline. The handler must branch on offset:
    //   • offset 0 (left edge): escape UP to the empty separator above
    //   • offset > 0 (right edge): escape DOWN by inserting `\n` at lineEnd
    //     and parking the caret on the new blank line
    //
    // Pre-fix the handler always escaped UP regardless of offset, which felt
    // wrong on the right edge (the user expected end-of-block behavior).

    @MainActor
    func test_handleThematicBreakReturn_caretAtRightEdge_insertsBlankLineBelow() {
        // "Foo\n\n---\nBar"
        //  0123 4 567 8 9..11
        // HR line = [5, 4] (chars "---\n"); right edge caret = 8 (before HR's \n).
        let body = "Foo\n\n---\nBar"
        let textView = makeTextViewStack(body: body, selection: NSRange(location: 8, length: 0))

        let handled = FormattingToolbarView.handleThematicBreakReturn(in: textView)

        XCTAssertTrue(handled, "Handler must consume Enter on an HR line")
        XCTAssertEqual(textView.string, "Foo\n\n---\n\nBar",
                       "Right edge Enter inserts `\\n` at lineEnd (position 9)")
        XCTAssertEqual(textView.selectedRange(),
                       NSRange(location: 9, length: 0),
                       "Caret parks on the new blank line")
    }

    @MainActor
    func test_handleThematicBreakReturn_caretInMiddleOfHR_treatedAsRightEdge() {
        // Caret at offset 1 within `---` (between first and second dash).
        // The zero-width-glyph design makes offsets 1, 2, 3 visually
        // indistinguishable from the right edge — all take the same branch.
        let body = "Foo\n\n---\nBar"
        let textView = makeTextViewStack(body: body, selection: NSRange(location: 6, length: 0))

        let handled = FormattingToolbarView.handleThematicBreakReturn(in: textView)

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "Foo\n\n---\n\nBar",
                       "Mid-HR Enter behaves identically to right-edge Enter")
        XCTAssertEqual(textView.selectedRange(),
                       NSRange(location: 9, length: 0))
    }

    @MainActor
    func test_handleThematicBreakReturn_caretAtLeftEdge_stillEscapesUp() {
        // Offset 0 keeps the existing escape-UP behavior. This locks in that
        // the right-edge split didn't regress the left-edge case.
        let body = "Foo\n\n---\nBar"
        let textView = makeTextViewStack(body: body, selection: NSRange(location: 5, length: 0))

        let handled = FormattingToolbarView.handleThematicBreakReturn(in: textView)

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, body,
                       "Left edge Enter is a pure caret move — no text mutation")
        XCTAssertEqual(textView.selectedRange(),
                       NSRange(location: 4, length: 0),
                       "Caret moves to lineRange.location - 1 (the empty separator above)")
    }

    @MainActor
    func test_handleThematicBreakReturn_caretAtRightEdge_noTrailingNewline() {
        // HR as the final block with no trailing `\n`. lineEnd == storage.length,
        // so the insert appends a `\n` and the caret lands at the new EOL.
        let body = "Foo\n\n---"
        let textView = makeTextViewStack(body: body, selection: NSRange(location: 8, length: 0))

        let handled = FormattingToolbarView.handleThematicBreakReturn(in: textView)

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "Foo\n\n---\n",
                       "Trailing `\\n` appended after the HR")
        XCTAssertEqual(textView.selectedRange(),
                       NSRange(location: 8, length: 0),
                       "Caret lands on the new EOL")
    }

    @MainActor
    func test_handleThematicBreakReturn_caretAtRightEdge_noHairlineStacking() {
        // Regression guard: after the right-edge Enter, the storage must still
        // carry exactly ONE contiguous `.sidekickThematicBreak` run of length 3
        // (just the `---` chars). Any leakage onto the inserted `\n` would
        // paint a second hairline.
        let body = "Foo\n\n---\nBar"
        let textView = makeTextViewStack(body: body, selection: NSRange(location: 8, length: 0))

        _ = FormattingToolbarView.handleThematicBreakReturn(in: textView)

        guard let storage = textView.textStorage else {
            return XCTFail("textView must have a textStorage")
        }
        var tbRuns: [NSRange] = []
        storage.enumerateAttribute(
            .sidekickThematicBreak,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, attrRange, _ in
            if (value as? Bool) == true { tbRuns.append(attrRange) }
        }
        XCTAssertEqual(tbRuns.count, 1, "Exactly one TB run survives the edit")
        XCTAssertEqual(tbRuns.first?.length, 3, "TB run covers only the `---` chars")
    }
}
