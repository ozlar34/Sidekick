import XCTest
import Foundation
import NoteDocument

/// Ticket 13, note-document seam: blocks made from file bytes keep their literal spellings (paste), and a range of
/// blocks can be written as it is in the file (copy).
final class NoteDocumentSourceBlocksTests: XCTestCase {

    func testMarkdownOfBlocksIsTheFileBytesOfThoseBlocks() {
        let source = "# H\n* a\n3) b\r\n***\n```x\n# c\n```\nlast"
        let doc = NoteDocument(markdown: source)
        XCTAssertEqual(doc.markdown(blocks: 0..<doc.blocks.count), source)
        XCTAssertEqual(doc.markdown(blocks: 1..<2), "* a\n")
        XCTAssertEqual(doc.markdown(blocks: 4..<5), "```x\n# c\n```\n")
        XCTAssertEqual(doc.markdown(blocks: 2..<2), "")
    }

    func testANewBlockIsWrittenWithDefaultSpelling() {
        XCTAssertEqual(NoteDocument.markdown(kind: .bullet, runs: [Run("x", bold: .asterisks)]), "- **x**")
        XCTAssertEqual(NoteDocument.markdown(kind: .heading(level: 2), runs: [Run("t")]), "## t")
        XCTAssertEqual(NoteDocument.markdown(kind: .paragraph, runs: []), "")
    }

    func testInsertSourceKeepsTheLiteralSpelling() {
        for (source, at) in [("* a", 1), ("7) b", 0), ("___", 2), ("```x\n# c\n```", 1), ("|a|b|\n|-|-|\n|1|2|", 0)] {
            let read = NoteDocument(markdown: source).blocks[0]
            var doc = NoteDocument(markdown: "one\ntwo\n")
            doc.apply(.insertSource(at: at, source: source, kind: read.kind, runs: read.runs))
            var lines = ["one\n", "two\n"]
            lines.insert(source + "\n", at: at)
            XCTAssertEqual(doc.markdown(), lines.joined(), source.debugDescription)
        }
    }

    func testInsertAtTheEndOfANoteWithoutFinalLineBreakKeepsItWithoutOne() {
        var doc = NoteDocument(markdown: "one")
        let read = NoteDocument(markdown: "* a").blocks[0]
        doc.apply(.insertSource(at: 1, source: "* a", kind: read.kind, runs: read.runs))
        XCTAssertEqual(doc.markdown(), "one\n* a")
    }

    func testReplaceSourceKeepsTheLineEndingOfTheBlockItReplaces() {
        var doc = NoteDocument(markdown: "one\r\ntwo\r\n")
        let read = NoteDocument(markdown: "* a").blocks[0]
        doc.apply(.replaceSource(at: 0, source: "* a", kind: read.kind, runs: read.runs))
        XCTAssertEqual(doc.markdown(), "* a\r\ntwo\r\n")
        // A code block takes the file's line ending inside too.
        let fence = NoteDocument(markdown: "```\nx\n```").blocks[0]
        doc.apply(.insertSource(at: 1, source: "```\nx\n```", kind: fence.kind, runs: fence.runs))
        XCTAssertEqual(doc.markdown(), "* a\r\n```\r\nx\r\n```\r\ntwo\r\n")
    }

    func testSourceThatDoesNotReadAsTheGivenBlockFallsBackToAPlainInsert() {
        var doc = NoteDocument(markdown: "one\n")
        doc.apply(.insertSource(at: 1, source: "# nope", kind: .bullet, runs: [Run("x")]))
        XCTAssertEqual(doc.markdown(), "one\n- x\n")
        doc.apply(.replaceSource(at: 0, source: "- two lines\n- x", kind: .bullet, runs: [Run("y")]))
        XCTAssertEqual(doc.markdown(), "- y\n- x\n")
    }
}
