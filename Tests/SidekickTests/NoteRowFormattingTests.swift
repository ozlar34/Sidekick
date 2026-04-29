import XCTest
@testable import Sidekick

final class NoteRowFormattingTests: XCTestCase {
    func testTitleFromHeading() {
        XCTAssertEqual(NoteRowFormatting.title(for: "# Hello\nbody"), "Hello")
    }
    func testTitleFallsBackToUntitled() {
        // G-04: plain text is now derived from body (not "Untitled"); only empty/whitespace falls back.
        XCTAssertEqual(NoteRowFormatting.title(for: "no heading body"), "no heading body")
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

    // When no heading exists, title is the first meaningful line and preview
    // must be the SECOND meaningful line — never the same line as the title.
    func test_noHeading_previewIsSecondMeaningfulLine() {
        let body = "- Shared line\nsecond line"
        XCTAssertEqual(NoteRowFormatting.title(for: body), "Shared line")
        XCTAssertEqual(NoteRowFormatting.preview(for: body), "second line")
    }

    func test_noHeading_singleLine_previewIsNil() {
        XCTAssertEqual(NoteRowFormatting.title(for: "only line"), "only line")
        XCTAssertNil(NoteRowFormatting.preview(for: "only line"))
    }

    func test_noHeading_blankSecondLine_previewIsNil() {
        XCTAssertNil(NoteRowFormatting.preview(for: "first line\n   \n"))
    }

    // MARK: - formattedModifiedTime

    private func makeDate(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func test_formattedModifiedTime_today_returnsTimeOfDay() {
        let now = makeDate("2026-04-30T15:00:00Z")
        let earlier = makeDate("2026-04-30T13:00:00Z")
        let result = NoteRowFormatting.formattedModifiedTime(earlier, now: now)
        // Locale-dependent format; just assert it isn't a weekday/month name.
        XCTAssertFalse(result.contains("Yesterday"))
        XCTAssertFalse(result.isEmpty)
    }

    func test_formattedModifiedTime_yesterday_returnsYesterday() {
        let now = makeDate("2026-04-30T15:00:00Z")
        let yesterday = makeDate("2026-04-29T13:00:00Z")
        XCTAssertEqual(NoteRowFormatting.formattedModifiedTime(yesterday, now: now), "Yesterday")
    }

    func test_formattedModifiedTime_thisWeek_returnsWeekday() {
        let now = makeDate("2026-04-30T15:00:00Z")
        let threeDaysAgo = makeDate("2026-04-27T13:00:00Z")
        let result = NoteRowFormatting.formattedModifiedTime(threeDaysAgo, now: now)
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEEE"
        XCTAssertEqual(result, f.string(from: threeDaysAgo))
    }

    func test_formattedModifiedTime_lastYear_includesYear() {
        let now = makeDate("2026-04-30T15:00:00Z")
        let lastYear = makeDate("2024-08-15T13:00:00Z")
        let result = NoteRowFormatting.formattedModifiedTime(lastYear, now: now)
        XCTAssertTrue(result.contains("2024"), "expected year in older-than-this-year label, got: \(result)")
    }
}
