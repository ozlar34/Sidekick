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

    // MARK: - Row preview

    /// The preview is the text the editor shows: no markdown markers, a link by its label, headings skipped.
    func test_preview_isTheFirstShownLineWithoutMarkdown() {
        let body = "# Title\n\n---\nSome *italic* and a [link](https://x.io) here.\nSecond line"
        XCTAssertEqual(NoteRowFormatting.firstMeaningfulLine(for: body), "Some italic and a link here.")
    }

    func test_preview_ofAChecklistOrQuote_dropsTheMarker() {
        XCTAssertEqual(NoteRowFormatting.firstMeaningfulLine(for: "- [ ] Coffee beans\n"), "Coffee beans")
        XCTAssertEqual(NoteRowFormatting.firstMeaningfulLine(for: "> Small steps\n"), "Small steps")
    }

    /// A code block or a table at the top is skipped: the preview is the first line of text after it.
    func test_preview_skipsALeadingCodeBlockOrTable() {
        XCTAssertEqual(NoteRowFormatting.firstMeaningfulLine(for: "```\nlet x = 1\n```\nAfter the code.\n"), "After the code.")
        XCTAssertEqual(NoteRowFormatting.firstMeaningfulLine(for: "| A | B |\n| --- | --- |\n| 1 | 2 |\nAfter the table.\n"),
                       "After the table.")
    }

    /// A quote or a checklist at the top is the preview, not the paragraph after it.
    func test_preview_ofALeadingQuoteOrChecklist_isThatLine() {
        XCTAssertEqual(NoteRowFormatting.firstMeaningfulLine(for: "> Small steps\nA paragraph.\n"), "Small steps")
        XCTAssertEqual(NoteRowFormatting.firstMeaningfulLine(for: "- [x] Book dentist\nA paragraph.\n"), "Book dentist")
    }

    func test_preview_isNil_whenOnlyHeadingsOrEmpty() {
        XCTAssertNil(NoteRowFormatting.firstMeaningfulLine(for: ""))
        XCTAssertNil(NoteRowFormatting.firstMeaningfulLine(for: "# Only a heading\n\n"))
    }
}
