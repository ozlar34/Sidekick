import XCTest
@testable import Sidekick

final class NoteSearchTests: XCTestCase {
    private func note(_ title: String, _ body: String) -> Note {
        Note(id: UUID(), filename: title + ".md", title: title, body: body, pinned: false, order: 0)
    }

    private lazy var groceries = note("Groceries", "- milk\n- Café beans\n")
    private lazy var trip = note("Tbilisi trip", "Flights booked.\n> ask about the café near the hotel\n")
    private lazy var empty = note("Empty", "")

    func testEmptyOrBlankQueryShowsEveryNote() {
        XCTAssertEqual(NoteSearch.matches([groceries, trip, empty], query: "").count, 3)
        XCTAssertEqual(NoteSearch.matches([groceries, trip, empty], query: "   ").count, 3)
    }

    func testTitleOrTextMatchesIgnoringCaseAndAccents() {
        XCTAssertEqual(NoteSearch.matches([groceries, trip, empty], query: "tbilisi").map(\.title), ["Tbilisi trip"])
        XCTAssertEqual(NoteSearch.matches([groceries, trip, empty], query: "CAFE").map(\.title), ["Groceries", "Tbilisi trip"])
    }

    func testEveryWordMustMatchInAnyField() {
        // "trip" is in the title, "hotel" in the text: both words match, so the note matches.
        XCTAssertEqual(NoteSearch.matches([groceries, trip], query: "trip hotel").map(\.title), ["Tbilisi trip"])
        XCTAssertEqual(NoteSearch.matches([groceries, trip], query: "milk hotel"), [])
    }

    func testResultsPutPinnedNotesFirst() {
        var pinnedTrip = trip
        pinnedTrip.pinned = true
        XCTAssertEqual(NoteSearch.results([groceries, pinnedTrip], query: "cafe").map(\.title), ["Tbilisi trip", "Groceries"])
    }

    func testSnippetIsFirstMatchingLineWithoutMarkers() {
        XCTAssertEqual(NoteSearch.snippet(for: trip, query: "cafe"), "ask about the café near the hotel")
        XCTAssertEqual(NoteSearch.snippet(for: groceries, query: "beans"), "Café beans")
        XCTAssertNil(NoteSearch.snippet(for: trip, query: "tbilisi"), "a title-only match has no snippet")
        XCTAssertNil(NoteSearch.snippet(for: trip, query: ""))
    }

    func testSnippetStartsNearALateMatch() {
        let long = note("Long", "One two three four five six seven eight nine ten eleven needle here.\n")
        XCTAssertEqual(NoteSearch.snippet(for: long, query: "needle"), "…ten eleven needle here.")
    }

    /// Search sees the text the editor shows: a link's label, not its address; no markdown markers.
    func testMatchesShownTextNotMarkdown() {
        let linked = note("Linked", "- [ ] check **the** [docs](https://example.com/guide)\n")
        XCTAssertEqual(NoteSearch.snippet(for: linked, query: "docs"), "check the docs")
        XCTAssertEqual(NoteSearch.matches([linked], query: "example"), [], "a link's address is not shown, so it does not match")
        XCTAssertEqual(NoteSearch.matches([linked], query: "**"), [])
    }
}
