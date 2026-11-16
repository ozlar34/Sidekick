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

    // MARK: ticket 12: look, grid, Enter, caret at cell starts

    private func font(_ h: NewEditorHost, at location: Int) -> NSFont {
        h.textView.textStorage!.attribute(.font, at: location, effectiveRange: nil) as! NSFont
    }

    func testMarkdownInsideACodeBlockIsShownAsWritten() {
        let source = "```\n# x\n**x**\n```\n"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.string, "# x\u{2028}**x**\n", "fence lines are not shown, the lines are as written")
        XCTAssertEqual(h.textView.blockKinds, ["code"])
        XCTAssertEqual(h.markdown, source)
        for location in 0..<(h.length - 1) {
            let f = font(h, at: location)
            XCTAssertTrue(f.isFixedPitch, "code is monospaced at \(location)")
            XCTAssertFalse(NSFontManager.shared.traits(of: f).contains(.boldFontMask), "no bold at \(location)")
        }
    }

    func testCodeBlockHasAFullWidthBackgroundAndNoFenceLines() {
        let h = NewEditorHost(markdown: "text\n```swift\nlet a = 1\nlet b = 2\n```\nmore\n")
        XCTAssertFalse(h.string.contains("`"))
        XCTAssertFalse(h.string.contains("swift"))
        let boxes = NoteTextEngine.codeBackgrounds(in: h.textView)
        XCTAssertEqual(boxes.count, 1)
        guard boxes.count == 1 else { return }
        let origin = h.textView.textContainerOrigin
        let width = h.textView.textContainer!.size.width
        XCTAssertLessThanOrEqual(boxes[0].minX, origin.x + 0.5)
        XCTAssertGreaterThanOrEqual(boxes[0].maxX, origin.x + width - 0.5, "as wide as the text column, not as wide as the text")
        XCTAssertGreaterThanOrEqual(boxes[0].height, 40, "covers both code lines")
        // The background is behind the code block only.
        let codeTop = NoteTextEngine.caretRect(in: h.textView, at: NSString(string: h.string).range(of: "let a").location).minY
        let textTop = NoteTextEngine.caretRect(in: h.textView, at: 0).minY
        XCTAssertGreaterThanOrEqual(boxes[0].minY, textTop + 10)
        XCTAssertLessThanOrEqual(boxes[0].minY, codeTop + 0.5)
    }

    func testEnterInsideACodeBlockAddsACodeLine() {
        for (source, at, expected) in [
            ("```\nab\n```\n", 1, "```\na\nb\n```\n"),
            ("```\nab\n```\n", 0, "```\n\nab\n```\n"),
            ("```\nab\n```\n", 2, "```\nab\n\n```\n"),
            ("x\n```swift\n# h\nab\n```\ny\n", 7, "x\n```swift\n# h\na\nb\n```\ny\n"),
        ] {
            let h = NewEditorHost(markdown: source)
            h.select(at)
            h.press(.enter)
            XCTAssertEqual(h.textView.blockKinds.filter { $0 == "code" }.count, 1, "still one code block: \(source)")
            XCTAssertEqual(h.savedMarkdown, expected, source)
            h.type("Z")
            XCTAssertEqual(h.textView.blockKinds.filter { $0 == "code" }.count, 1)
            h.textView.undoManager?.undo()
            h.textView.undoManager?.undo()
            XCTAssertEqual(h.markdown, source, "undo restores the original bytes")
        }
    }

    func testEnterMidLineInACodeBlockKeepsOneFenceAndIsOneUndoStep() {
        let source = "intro\n```swift\nfirst line\nsecond line\n```\nafter\n"
        let h = NewEditorHost(markdown: source)
        h.select(NSString(string: h.string).range(of: "second").location + 3)   // mid-line
        h.press(.enter)
        h.type("x")
        let saved = h.savedMarkdown!
        XCTAssertEqual(saved, "intro\n```swift\nfirst line\nsec\nxond line\n```\nafter\n")
        XCTAssertEqual(saved.components(separatedBy: "```").count - 1, 2, "one opening and one closing fence")
        XCTAssertEqual(h.textView.blockKinds, ["p", "code", "p"])
        h.textView.undoManager?.undo()   // the typed x
        h.textView.undoManager?.undo()   // Enter: one step
        XCTAssertEqual(h.markdown, source, "exact original bytes")
        XCTAssertEqual(h.textView.blockKinds, ["p", "code", "p"])
    }

    /// Fixed example of a seed that failed once (generator seed 54): a heading as the last line, no final newline.
    /// The caret at the end of the note must be where AppKit puts it, not 50 pt past the text.
    func testCaretAtTheEndOfALastHeadingMatchesAppKit() {
        let h = NewEditorHost(markdown: "snake_case 42 caf\u{e9}\n\u{65E5}\u{672C} alpha\nsnake_case alpha **alpha x** a*b 42\nbeta beta x\n# 42")
        h.select(h.length)
        XCTAssertEqual(h.caret.minX, h.appKitCaretRect.minX, accuracy: 1.5)
        XCTAssertEqual(h.caret.minY, h.appKitCaretRect.minY, accuracy: 1.5)
    }

    func testTypedMarkdownInACodeBlockStaysLiteral() {
        let h = NewEditorHost(markdown: "```\n\n```\n")
        h.select(0)
        for text in ["# ", "- ", "> ", "1. ", "- [ ] ", "---", "```", "**x**", "*x*", "`x`", "~~x~~"] {
            h.type(text)
            h.press(.enter)
        }
        XCTAssertEqual(h.textView.blockKinds, ["code"])
        let md = h.savedMarkdown!
        XCTAssertTrue(md.contains("# \n- \n> \n1. \n- [ ] \n---\n"), md)
        XCTAssertTrue(md.contains("**x**\n*x*\n`x`\n~~x~~\n"), md)
        XCTAssertEqual(NewEditorHost(markdown: md).textView.blockKinds, ["code"])
    }

    func testEditingACellChangesOnlyTheTableBlockInTheFile() {
        let source = "# t\n\ntext\n| a | b |\n|---|---|\n| x | y |\n| p | q |\nafter  \n```\ncode\n```\nend"
        let h = NewEditorHost(markdown: source)
        let y = NSString(string: h.string).range(of: "y")
        h.select(y.upperBound)
        h.type("Z")
        let saved = h.savedMarkdown!
        let lines = source.components(separatedBy: "\n"), now = saved.components(separatedBy: "\n")
        XCTAssertEqual(Array(now.prefix(3)), Array(lines.prefix(3)))
        XCTAssertEqual(Array(now.suffix(4)), Array(lines.suffix(4)), "blocks after the table keep their bytes")
        XCTAssertTrue(saved.contains("| x | yZ |"), saved)
        XCTAssertEqual(now.count, lines.count)
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.markdown, source, "undo restores the original bytes")
    }

    func testTableIsAGridAndArrowKeysWalkTheCellsInReadingOrder() {
        let source = "| a | bb | c |\n|---|---|---|\n| d | | f |\n| g | h |\n"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.textView.blockKinds, ["table"])
        let grids = NoteTextEngine.tableGrids(in: h.textView)
        XCTAssertEqual(grids.count, 1)
        guard grids.count == 1, grids[0].rows.count == 3, grids[0].columnEdges.count == 4 else { return XCTFail("no grid") }
        XCTAssertEqual(grids[0].rows.count, 3, "header and two body rows; the delimiter row is not shown")
        XCTAssertEqual(grids[0].columnEdges.count, 4, "three columns")
        XCTAssertEqual(grids[0].columnEdges, grids[0].columnEdges.sorted())
        for i in 1..<grids[0].rows.count { XCTAssertGreaterThan(grids[0].rows[i].minY, grids[0].rows[i - 1].minY) }
        // Every cell start is inside its own column, and Right visits them left to right, then the next row.
        let starts = h.tableCellStarts()
        XCTAssertEqual(starts.count, 3 + 3 + 2)
        h.select(0)
        var visited: [Int] = [0]
        while h.location < h.length - 1 {
            h.press(.right)
            if starts.contains(h.location) { visited.append(h.location) }
        }
        XCTAssertEqual(visited, starts, "reading order")
        let edges = grids[0].columnEdges
        for (i, s) in starts.enumerated() {
            let column = [0, 1, 2, 0, 1, 2, 0, 1][i]
            let x = NoteTextEngine.caretRect(in: h.textView, at: s).minX
            XCTAssertGreaterThan(x, edges[column], "cell \(i) starts inside its column")
            XCTAssertLessThan(x, edges[column + 1], "cell \(i) starts inside its column")
        }
    }

    func testEnterInATableCellDoesNothing() {
        let source = "| a | b |\n|---|---|\n| x | y |\n"
        let h = NewEditorHost(markdown: source)
        h.select(NSString(string: h.string).range(of: "x").upperBound)
        h.press(.enter)
        XCTAssertEqual(h.markdown, source)
        XCTAssertEqual(h.textView.blockKinds, ["table"])
    }

    /// The prototype risk: on TextKit 1 the caret rectangle read as zero at the start of table cells while typing
    /// landed correctly. Every cell start (also empty cells and cells of short rows) must have a drawn caret that
    /// AppKit agrees with, and typing there must land at it.
    func testTheCaretIsVisibleAtTheFirstPositionOfEveryTableCell() {
        var sources = [
            "| a | bb | c |\n|---|---|---|\n| d | | f |\n| | h |\n",
            "| |\n|-|\n| x |\n",
            "para\n| \u{65E5}\u{672C} | caf\u{e9} |\n|---|---|\n| **b** | `c` |\n",
        ]
        for seed in 1...UInt64(ProcessInfo.processInfo.environment["SIDEKICK_FUZZ_SEEDS"].flatMap { UInt64($0) } ?? 40) {
            var gen = NewEditorNoteGenerator(seed: seed)
            sources.append(gen.markdown())
        }
        var cells = 0
        for (n, source) in sources.enumerated() {
            let h = NewEditorHost(markdown: source)
            for s in h.tableCellStarts() {
                cells += 1
                h.select(s)
                let mine = h.caret, theirs = h.appKitCaretRect
                XCTAssertGreaterThan(mine.height, 0, "source \(n) cell start \(s)")
                XCTAssertGreaterThan(theirs.height, 0, "source \(n) cell start \(s): AppKit reports no caret rectangle")
                XCTAssertNotEqual(theirs.origin, .zero, "source \(n) cell start \(s): AppKit reports a zero rectangle")
                XCTAssertEqual(mine.minX, theirs.minX, accuracy: 1.5, "source \(n) cell start \(s) x")
                XCTAssertEqual(mine.minY, theirs.minY, accuracy: 1.5, "source \(n) cell start \(s) y")
                let before = h.caret
                let original = h.string
                h.type("Z")
                let start = NoteTextEngine.caretRect(in: h.textView, at: s)
                XCTAssertEqual(start.minX, before.minX, accuracy: 4, "source \(n) cell start \(s): typed character not at the caret")
                XCTAssertEqual(start.minY, before.minY, accuracy: 0.5)
                h.press(.backspace)
                XCTAssertEqual(h.string, original)
            }
        }
        XCTAssertGreaterThan(cells, 20, "the property saw table cells")
    }
}
