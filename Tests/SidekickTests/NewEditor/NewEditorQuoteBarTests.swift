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

    func testWrappingQuoteLineGetsOneBarOverAllItsLines() {
        let words = String(repeating: "a quote long enough to wrap ", count: 8)
        let h = NewEditorHost(markdown: "text\n> \(words)\nmore\n", size: CGSize(width: 320, height: 600))
        let bars = NoteTextEngine.quoteBars(in: h.textView)
        XCTAssertEqual(bars.count, 1, "one quote line: one bar")
        guard let bar = bars.first, let lm = h.textView.layoutManager else { return }
        let ns = h.string as NSString
        let quote = ns.paragraphRange(for: ns.range(of: "a quote long"))
        let glyphs = lm.glyphRange(forCharacterRange: quote, actualCharacterRange: nil)
        var lines: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in lines.append(rect) }
        XCTAssertGreaterThan(lines.count, 1, "the quote wraps")
        let y = h.textView.textContainerOrigin.y
        XCTAssertEqual(bar.minY, lines[0].minY + y, accuracy: 0.5, "the bar starts at the quote's first line")
        XCTAssertEqual(bar.maxY, lines[lines.count - 1].maxY + y, accuracy: 0.5, "the bar ends at the quote's last wrapped line")
    }
}
