import XCTest
import AppKit
@testable import Sidekick

/// Regression for review finding c1 (ticket 03): the buffer must carry every mark of the note document, so that
/// an edit in one block never changes the bytes of another block. Real key events in a real window.
@MainActor
final class NewEditorMarksTests: XCTestCase {

    /// One line per mark kind and spelling, every block kind, and the pills in both forms.
    static let lines = [
        "*it* and _it_ here", "<u>under</u> line", "~~gone~~ text", "`code` span", "[label](http://x.y/z) link",
        "see https://example.com/a_b now", "[https://x.y](https://x.y) pill", "**b *i* b** ***bi*** __b _i_ b__",
        "<u>**bold under**</u> ~~*it strike*~~ [**b**](u)", "* star bullet with *it*", "1) paren number", "  - [X] big X **b**",
        "> quote ~~s~~", "***", "- [ ] todo `c`", "# Head *it*", "plain \\* escaped \\_ text", "![img](x.png)",
    ]

    func testTypingInFirstBlockLeavesEveryOtherBlockByteIdentical() {
        let source = "first block\n" + Self.lines.joined(separator: "\n") + "\ntail\n"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.markdown, source, "no edit")
        h.select(5)
        h.type("Z")
        XCTAssertEqual(h.savedMarkdown, source.replacingOccurrences(of: "first block", with: "firstZ block"))
    }

    func testEachMarkLineSurvivesAnEditElsewhere() {
        for line in Self.lines {
            let source = "first\r\n\(line)\r\nlast"
            let h = NewEditorHost(markdown: source)
            h.select(0)
            h.type("Z")
            XCTAssertEqual(h.savedMarkdown, "Zfirst\r\n\(line)\r\nlast", line)
        }
    }

    func testEditingAfterMarkedBlocksKeepsThem() {
        let source = Self.lines.joined(separator: "\n") + "\nlast\n"
        let h = NewEditorHost(markdown: source)
        h.select(h.length - 1)
        h.type("!")
        XCTAssertEqual(h.savedMarkdown, source.replacingOccurrences(of: "last\n", with: "last!\n"))
    }

    func testTypingNextToAPillDoesNotSwallowTheTextIntoIt() {
        let h = NewEditorHost(markdown: "go [https://x.y](https://x.y)\nrest\n")
        h.select(NSString(string: h.string).range(of: "\u{FFFC}").upperBound)   // a pill is one object in the buffer
        h.type("abc")
        XCTAssertEqual(h.savedMarkdown, "go [https://x.y](https://x.y)abc\nrest\n")
    }
}
