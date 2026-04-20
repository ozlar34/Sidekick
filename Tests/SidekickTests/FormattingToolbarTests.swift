import XCTest
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

    func test_toggleOff_nonMatchingWrapper_additive() {
        // body "*foo*" — invoke ⌘B (prefix/suffix "**") — outer wrapper is "*" not "**" → no strip, falls through additive
        let result = FormattingToolbarView.applyMarkdownWrap(
            prefix: "**", suffix: "**",
            body: "*foo*",
            range: NSRange(location: 1, length: 3)
        )
        XCTAssertEqual(result.newBody, "***foo***", "No strip — wrapper mismatch; additive insert wraps the selected 'foo'")
        // Cursor = safeLocation + insert.length = 1 + len("**foo**") = 1 + 7 = 8
        XCTAssertEqual(result.cursorLocation, 8)
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
}
