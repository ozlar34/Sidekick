import AppKit
import XCTest
@testable import Sidekick

/// A quote has a bar on its left: one bar for quote lines in a row, inside the quote's indent.
@MainActor
final class NewEditorQuoteBarTests: XCTestCase {
    func testQuoteLinesInARowShareOneBar() {
        let h = NewEditorHost(markdown: "text\n> one\n> two\nmore\n> three\n")
        let bars = NoteTextEngine.quoteBars(in: h.textView)
        XCTAssertEqual(bars.count, 2, "two runs of quote lines: two bars")
        guard bars.count == 2 else { return }
        XCTAssertGreaterThan(bars[0].height, bars[1].height, "the first bar spans both of its lines")
        XCTAssertLessThan(bars[1].minX + bars[1].width, h.textView.textContainerOrigin.x + NoteBuffer.indent(for: .quote),
                          "the bar stays left of the quote's text")
    }

    func testNoQuoteNoBar() {
        let h = NewEditorHost(markdown: "text\n- item\n")
        XCTAssertTrue(NoteTextEngine.quoteBars(in: h.textView).isEmpty)
    }
}
