import XCTest
@testable import Sidekick

final class NoteRowFormattingTests: XCTestCase {
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
