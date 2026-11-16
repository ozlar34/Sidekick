import XCTest
import AppKit
@testable import Sidekick

/// Ticket 04 lesson (from 03 review c1): the buffer must carry code blocks and tables losslessly in both
/// directions, so that typing in one block never changes the bytes of another. Real key events in a real window.
@MainActor
final class NewEditorCodeTablesTests: XCTestCase {

    /// Blocks that span several lines or hold markup-looking text, each as its file bytes.
    static let blocks = [
        "```swift\n# comment\nlet x = **y**\n```",
        "~~~\n- item\n> q\n~~~~~  ",
        "````  info words\n```\n`````",
        "```\n```",
        "```\n\n\n  indented\n```",
        "| a | b |\n|---|---|\n| **1** | 2 |",
        "|x|y|z|\n| :-- | :-: | --: |\n|1|\n| [l](http://x.y) | a \\| b | https://a.b |",
        "```c\nunclosed fence is text\n**not bold?**",
    ]

    func testTypingInAnotherBlockLeavesCodeBlocksAndTablesByteIdentical() {
        for (index, block) in Self.blocks.enumerated() {
            let source = "first\n\(block)\nlast\n"
            let h = NewEditorHost(markdown: source)
            XCTAssertEqual(h.markdown, source, "no edit, block \(index)")
            h.select(0)
            h.type("Z")
            XCTAssertEqual(h.savedMarkdown, "Zfirst\n\(block)\nlast\n", "type before block \(index)")
            h.select(h.length - 1)
            h.type("!")
            XCTAssertEqual(h.savedMarkdown, "Zfirst\n\(block)\nlast!\n", "type after block \(index)")
        }
    }

    func testAllBlocksTogetherWithCRLFAndNoFinalNewline() {
        let source = "first\r\n" + Self.blocks.prefix(7).joined(separator: "\r\n\r\n").replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "\r\r\n", with: "\r\n") + "\r\nlast"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.markdown, source)
        h.select(2)
        h.type("Z")
        XCTAssertEqual(h.savedMarkdown, "fiZrst" + source.dropFirst(5))
    }

    func testTypingInsideACodeBlockChangesOnlyThatBlock() {
        let source = "a\n```swift\n# comment\n**x**\n```\nz\n"
        let h = NewEditorHost(markdown: source)
        let at = NSString(string: h.string).range(of: "comment").upperBound
        h.select(at)
        h.type("s")
        XCTAssertEqual(h.savedMarkdown, "a\n```swift\n# comments\n**x**\n```\nz\n")
    }

    func testTypingInsideATableCellChangesOnlyThatTable() {
        let source = "a\n|a|b|\n|-|-|\n| x | y |\nz\n"
        let h = NewEditorHost(markdown: source)
        h.select(NSString(string: h.string).range(of: "x").upperBound)
        h.type("1")
        XCTAssertEqual(h.savedMarkdown, "a\n| a | b |\n|-|-|\n| x1 | y |\nz\n")
    }
}
