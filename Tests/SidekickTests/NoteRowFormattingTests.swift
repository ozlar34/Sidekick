import XCTest
@testable import Sidekick

final class NoteRowFormattingTests: XCTestCase {
    func testTitleFromHeading() {
        XCTAssertEqual(NoteRowFormatting.title(for: "# Hello\nbody"), "Hello")
    }
    func testTitleFallsBackToUntitled() {
        XCTAssertEqual(NoteRowFormatting.title(for: "no heading body"), "Untitled")
    }
    func testPreviewFirstNonHeadingLine() {
        XCTAssertEqual(NoteRowFormatting.preview(for: "# Heading\nfirst body line\nsecond"), "first body line")
    }
    func testPreviewStripsBulletDash() {
        XCTAssertEqual(NoteRowFormatting.preview(for: "# Heading\n- bullet item"), "bullet item")
    }
    func testPreviewStripsBulletStar() {
        XCTAssertEqual(NoteRowFormatting.preview(for: "# Heading\n* star item"), "star item")
    }
    func testPreviewStripsQuote() {
        XCTAssertEqual(NoteRowFormatting.preview(for: "# Heading\n> quote item"), "quote item")
    }
    // IN-02: lines starting with `-`/`*`/`>` but no following space are
    // legitimate content (e.g. negative numbers) and must NOT be stripped.
    func testPreviewPreservesLiteralDash() {
        XCTAssertEqual(NoteRowFormatting.preview(for: "# Heading\n-42 is the answer"), "-42 is the answer")
    }
    func testPreviewPreservesLiteralStar() {
        XCTAssertEqual(NoteRowFormatting.preview(for: "# Heading\n*bold*"), "*bold*")
    }
    func testPreviewPreservesLiteralGreaterThan() {
        XCTAssertEqual(NoteRowFormatting.preview(for: "# Heading\n>=42 matches"), ">=42 matches")
    }
    func testPreviewNilWhenOnlyHeading() {
        XCTAssertNil(NoteRowFormatting.preview(for: "# Heading\n"))
    }
    func testPreviewTruncatedAt50() {
        let long = "# Heading\n" + String(repeating: "x", count: 80)
        XCTAssertEqual(NoteRowFormatting.preview(for: long)?.count, 50)
    }
    func testPreviewNilForEmpty() {
        XCTAssertNil(NoteRowFormatting.preview(for: ""))
    }

    // MARK: - Title derivation chain (G-04)

    func test_title_plainFirstLine_returnsThatLine() {
        XCTAssertEqual(NoteRowFormatting.title(for: "Hello world\nmore text"), "Hello world")
    }

    func test_title_leadingH1_returnsHeading() {
        XCTAssertEqual(NoteRowFormatting.title(for: "# My Note\nbody"), "My Note")
    }

    func test_title_leadingH2_returnsHeading() {
        XCTAssertEqual(NoteRowFormatting.title(for: "## Subsection\nbody"), "Subsection")
    }

    func test_title_bodyStartsWithBullet_stripsBulletPrefix() {
        XCTAssertEqual(NoteRowFormatting.title(for: "- Item one\n- Item two"), "Item one")
    }

    func test_title_emptyBody_returnsUntitled() {
        XCTAssertEqual(NoteRowFormatting.title(for: ""), "Untitled")
    }

    func test_title_allWhitespaceBody_returnsUntitled() {
        XCTAssertEqual(NoteRowFormatting.title(for: "   \n\n\t\n   "), "Untitled")
    }

    func test_title_and_preview_shareFirstMeaningfulLine() {
        let body = "- Shared line\nsecond line"
        XCTAssertEqual(NoteRowFormatting.title(for: body), "Shared line")
        XCTAssertEqual(NoteRowFormatting.preview(for: body), "Shared line")
    }
}
