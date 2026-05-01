import XCTest
@testable import Sidekick

final class NoteRowFormattingTests: XCTestCase {
    // NoteRowFormatting.title(for:) was removed in the 2026-05-01 title-field
    // shift — title now lives on Note.title directly. Tests that exercised
    // the old derivation chain were dropped along with the API.
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
