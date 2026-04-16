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
}
