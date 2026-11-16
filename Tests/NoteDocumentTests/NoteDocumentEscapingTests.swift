import XCTest
import Foundation
import NoteDocument

/// Criterion -> test map (ticket 05-note-document-escaping)
/// 1. property: for any document and any edit sequence, load(save(document)) equals the document
///      -> testSaveLoadEqualsDocument_afterEdits (NoteDocumentTests; now draws the shapes below from the generator),
///         testGeneratorReachesEveryEscapeShape pins that the generator and the corpus reach them
/// 2. a paragraph whose typed text is `- not a list` stays a paragraph after save and load
///      -> testTypedMarkupStaysAParagraph (replace and insertText routes, every marker of the ticket body)
/// 3. an unedited block that contains backslash escapes round-trips byte for byte
///      -> testUneditedEscapesKeepTheirBytes
/// 4. a corpus file with images, HTML and footnotes round-trips byte for byte and shows that content as text
///      -> testUnsupportedMarkdownRoundTripsAndShowsAsText
/// Also: setext pairs stay literal (testSetextPairsStayLiteral), reader understands each escape (testReaderUnderstandsEscapes).
final class NoteDocumentEscapingTests: XCTestCase {

    /// Every marker the ticket names, typed as plain text, alone and with surrounding words.
    static let typed = ["*", "_", "`", "[", "# not a heading", "## x", "- not a list", "* star", "> not a quote", "1. not numbered",
                        "1) paren", "---", "***", "___", "- [ ] box", "- [x] done", "a * b * c", "snake_case_name", "__x__", "**x**",
                        "`code`", "[l](u)", "[a][b]", "[b]: http://u", "[^1]", "[^1]: note", "![img](u)", "<div>", "<u>x</u>",
                        "~~s~~", "https://a.b/c", "\\", "\\*", "\\# x", "===", "|", "| a | b |", "```", "~~~", "text\u{2028}more"]

    private func roundTrip(_ doc: NoteDocument, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let md = doc.markdown()
        let back = NoteDocument(markdown: md)
        XCTAssertEqual(back, doc, "\(why): \(md.debugDescription)", file: file, line: line)
        XCTAssertEqual(back.markdown(), md, "\(why): second save", file: file, line: line)
    }

    func testTypedMarkupStaysAParagraph() {
        for t in Self.typed {
            var doc = NoteDocument(markdown: "before\n\nafter\n")
            doc.apply(.replace(at: 1, kind: .paragraph, runs: [Run(t)]))
            roundTrip(doc, "replace \(t.debugDescription)")
            let b = NoteDocument(markdown: doc.markdown()).blocks[1]
            XCTAssertEqual(b.kind, .paragraph, t)
            XCTAssertEqual(b.text, doc.blocks[1].text, t)

            var doc2 = NoteDocument(markdown: "x\n\nz\n")
            doc2.apply(.insertText(block: 1, offset: 0, text: t))
            roundTrip(doc2, "insertText \(t.debugDescription)")
            XCTAssertEqual(NoteDocument(markdown: doc2.markdown()).blocks[1].kind, .paragraph, t)

            // typed in front of and behind an existing word
            var doc3 = NoteDocument(markdown: "word\n")
            doc3.apply(.insertText(block: 0, offset: 4, text: t))
            doc3.apply(.insertText(block: 0, offset: 0, text: t))
            roundTrip(doc3, "around word \(t.debugDescription)")
        }
        var doc = NoteDocument(markdown: "\n")
        doc.apply(.insertText(block: 0, offset: 0, text: "- not a list"))
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()).blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()).blocks[0].text, "- not a list")
    }

    func testTypedMarkupInsideOtherBlockKindsStaysStable() {
        for kind in [BlockKind.bullet, .numbered, .quote, .checklist(checked: false), .heading(level: 2)] {
            for t in Self.typed {
                var doc = NoteDocument(markdown: "a\n")
                doc.apply(.replace(at: 0, kind: kind, runs: [Run(t)]))
                roundTrip(doc, "\(kind) \(t.debugDescription)")
            }
        }
    }

    func testUneditedEscapesKeepTheirBytes() {
        let md = "\\*literal\\* snake_case \\_ \\\\ trailing\\\n\\# not a heading\n\\\\# also text\n\\- not bullet\n\\> not quote\n\\---\n\\1. not numbered\n\\[ \\] \\` \\~ \\< \\: https\\://x.y \\!\\[i](u)\n- [ ] \\*box\\*\n> \\# q\n"
        var doc = NoteDocument(markdown: md)
        XCTAssertEqual(doc.markdown(), md)
        // Editing another block must not touch these bytes.
        doc.apply(.insert(at: doc.blocks.count, kind: .paragraph, runs: [Run("new")]))
        XCTAssertTrue(doc.markdown().hasPrefix(md))
        // and the same inside a longer document, one edit per block
        for i in 0..<NoteDocument(markdown: md).blocks.count {
            var d = NoteDocument(markdown: md + "tail\n")
            let last = d.blocks.count - 1
            d.apply(.insertText(block: last, offset: 0, text: "x"))
            XCTAssertTrue(d.markdown().hasPrefix(md), "block \(i)")
        }
    }

    func testReaderUnderstandsEscapes() {
        let doc = NoteDocument(markdown: "\\*a\\* \\_b\\_ \\` \\[ \\# \\\\\n\\# h\n\\- x\n\\> q\n\\---\n\\1. n\n")
        XCTAssertEqual(doc.blocks.map(\.kind), [.paragraph, .paragraph, .paragraph, .paragraph, .paragraph, .paragraph])
        XCTAssertEqual(doc.blocks.map(\.text), ["*a* _b_ ` [ \\# \\", "# h", "- x", "> q", "---", "1. n"])
        XCTAssertTrue(doc.blocks.allSatisfy { $0.runs.allSatisfy { $0.bold == nil && $0.italic == nil && !$0.code && $0.link == nil } })
    }

    static let unsupported = "![alt](pic.png) and ![ref][r] inline\n<div class=\"x\">html</div>\n<span>**b**</span> <br> <!-- c -->\n[^1]: footnote text\nText with a note[^1].\n[a][b] reference\n[b]: http://example.com \"title\"\n![x](u)\n"

    func testUnsupportedMarkdownRoundTripsAndShowsAsText() {
        for (suffix, name) in [("", "lf"), ("\r", "crlf")] {
            let md = Self.unsupported.replacingOccurrences(of: "\n", with: suffix + "\n")
            var doc = NoteDocument(markdown: md)
            XCTAssertEqual(doc.markdown(), md, name)
            let texts = doc.blocks.map(\.text)
            for needle in ["![alt](pic.png)", "![ref][r]", "<div class=\"x\">html</div>", "<br>", "<!-- c -->", "[^1]: footnote text", "note[^1].", "[a][b] reference", "[b]: http://example.com \"title\"", "![x](u)"] {
                XCTAssertTrue(texts.contains { $0.contains(needle) }, "\(name): \(needle) shown as text")
            }
            XCTAssertTrue(doc.blocks.allSatisfy { $0.kind == .paragraph }, name)
            // Edit one block: the unsupported lines around it stay byte for byte.
            doc.apply(.insertText(block: 0, offset: 0, text: "x"))
            XCTAssertTrue(doc.markdown().hasSuffix(md.components(separatedBy: "\n").dropFirst().joined(separator: "\n")), name)
            roundTrip(doc, name)
        }
    }

    func testSetextPairsStayLiteral() {
        for under in ["===", "======", "---", "-----"] {
            let md = "Title\n\(under)\nafter\n"
            let doc = NoteDocument(markdown: md)
            XCTAssertEqual(doc.markdown(), md, under)
            XCTAssertEqual(doc.blocks[0].kind, .paragraph, under)
            XCTAssertEqual(doc.blocks[0].text, "Title", under)           // never a heading, never eaten
            if under.hasPrefix("=") { XCTAssertEqual(doc.blocks[1].kind, .paragraph); XCTAssertEqual(doc.blocks[1].text, under) }
            else { XCTAssertEqual(doc.blocks[1].kind, .divider, under) }  // a divider of its own, "Title" keeps its block
            // typed as two paragraphs, edited and saved
            var d = NoteDocument(markdown: "x\n")
            d.apply(.replace(at: 0, kind: .paragraph, runs: [Run("Title")]))
            d.apply(.insert(at: 1, kind: .paragraph, runs: [Run(under)]))
            roundTrip(d, "typed pair \(under)")
            XCTAssertEqual(NoteDocument(markdown: d.markdown()).blocks.map(\.kind), [.paragraph, .paragraph], under.debugDescription)
            // an edit of the first line of an unedited pair
            var e = NoteDocument(markdown: md)
            e.apply(.insertText(block: 0, offset: 0, text: "new "))
            roundTrip(e, "edited pair \(under)")
            XCTAssertEqual(NoteDocument(markdown: e.markdown()).blocks[0].kind, .paragraph)
        }
    }

    func testGeneratorReachesEveryEscapeShape() {
        let needles = ["[^1]", "![img](u)", "<div>", "[a][b]", "[b]: u", "===", "- not a list", "# not a heading", "> not a quote", "1. not numbered"]
        var seenText = Set<String>(), seenSetext = false
        for seed in 1...600 {
            var g = DocumentGenerator(seed: UInt64(seed))
            var doc = NoteDocument(markdown: g.markdown())
            for _ in 0..<12 {
                for b in doc.blocks where b.kind == .paragraph { for n in needles where b.text.contains(n) { seenText.insert(n) } }
                for (a, b) in zip(doc.blocks, doc.blocks.dropFirst()) where a.kind == .paragraph && !a.text.isEmpty && b.kind == .paragraph && (b.text == "===" || b.text == "---") { seenSetext = true }
                doc.apply(g.edit(in: doc))
            }
        }
        XCTAssertEqual(seenText, Set(needles))
        XCTAssertTrue(seenSetext, "no setext pair of paragraphs reached")
        let corpus = Corpus.all.map(\.text).joined()
        for n in ["![", "<div>", "[^1]", "[ref]: http", "======"] { XCTAssertTrue(corpus.contains(n), n) }
    }
}
