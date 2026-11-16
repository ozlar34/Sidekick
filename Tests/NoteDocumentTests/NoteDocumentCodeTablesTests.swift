import XCTest
import Foundation
import NoteDocument

/// Criterion -> test map (ticket 04-note-document-code-blocks-and-tables)
/// 1. all properties of ticket 02 hold with code blocks and tables in the generator
///      -> the ticket-02/03 property tests (NoteDocumentTests, NoteDocumentLineBlocksTests) now draw fences and tables
///         from `DocumentGenerator` and the corpus; testGeneratorAndCorpusReachCodeBlocksAndTables pins that they do;
///         testSaveLoadEqualsDocument_codeAndTableEdits_generated adds edits aimed at those blocks
/// 2. `# x` and `**x**` inside a code block load as plain code text and save unchanged
///      -> testCodeContentIsNeverReadForMarksOrBlocks, testCodeBlockEditsKeepOtherBytes
/// 3. the fence lines and the language word survive an edit of the code content
///      -> testFenceLinesAndInfoSurviveContentEdits (example), testFenceLinesSurviveContentEdits_generated (property)
/// 4. a cell text edit changes only the table block's bytes and gives a valid pipe table
///      -> testCellEditChangesOnlyTheTable, testCellEditsGiveValidPipeTables_generated
/// 5. a table with inline marks in cells keeps them
///      -> testTableCellsKeepTheirMarks
/// Also: unterminated fence is not a code block (testUnclosedFenceIsText); rule 3 corner cases that need more than
/// per-block escapes (testCornerCasesStayStable).
final class NoteDocumentCodeTablesTests: XCTestCase {

    private func forEachSeed(_ body: (UInt64, inout DocumentGenerator) -> Bool) {
        let start = Date()
        for i in 0..<FuzzConfig.seedCount {
            let seed = FuzzConfig.firstSeed &+ UInt64(i)
            var gen = DocumentGenerator(seed: seed)
            if !body(seed, &gen) { return }
        }
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(start), Double(FuzzConfig.budgetSeconds), "Property budget overrun")
    }

    private func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    // MARK: 1

    func testGeneratorAndCorpusReachCodeBlocksAndTables() {
        func kinds(_ docs: [NoteDocument]) -> Set<String> {
            var out = Set<String>()
            for d in docs { for b in d.blocks { if b.kind == .fence { out.insert("fence") }; if b.kind == .table { out.insert("table") } } }
            return out
        }
        XCTAssertEqual(kinds(Corpus.all.map { NoteDocument(markdown: $0.text) }), ["fence", "table"])
        XCTAssertEqual(kinds((1...200).map { var g = DocumentGenerator(seed: UInt64($0)); return NoteDocument(markdown: g.markdown()) }), ["fence", "table"])
        // Edits reach them too.
        var seen = Set<String>()
        for seed in 1...200 {
            var g = DocumentGenerator(seed: UInt64(seed))
            var doc = NoteDocument(markdown: g.markdown())
            for _ in 0..<12 { doc.apply(g.edit(in: doc)); seen.formUnion(kinds([doc])) }
        }
        XCTAssertEqual(seen, ["fence", "table"])
    }

    func testSaveLoadEqualsDocument_codeAndTableEdits_generated() {
        forEachSeed { seed, gen in
            var doc = NoteDocument(markdown: gen.markdown())
            for step in 0..<FuzzConfig.stepsPerSeed {
                let edit: Edit
                let targets = doc.blocks.indices.filter { doc.blocks[$0].kind.isMultiline }
                if let i = targets.isEmpty ? nil : targets[gen.int(targets.count)], gen.int(2) == 0 {
                    let len = doc.blocks[i].text.utf16.count
                    switch gen.int(4) {
                    case 0: edit = .insertText(block: i, offset: gen.int(len + 2), text: gen.plainText())
                    case 1: let a = gen.int(len + 2), b = gen.int(len + 2); edit = .deleteText(block: i, range: min(a, b)..<max(a, b))
                    case 2: edit = .replace(at: i, kind: gen.int(2) == 0 ? .fence : .table, runs: gen.runs())
                    default: edit = .split(block: i, offset: gen.int(len + 2))
                    }
                } else { edit = gen.edit(in: doc) }
                doc.apply(edit)
                let md = doc.markdown()
                let reloaded = NoteDocument(markdown: md)
                if reloaded != doc {
                    XCTFail("seed \(seed) step \(step) edit \(edit): \(md.debugDescription) reloads as \(reloaded.blocks) not \(doc.blocks)")
                    return false
                }
                if reloaded.markdown().utf8.elementsEqual(md.utf8) == false { XCTFail("seed \(seed) step \(step): second save differs"); return false }
            }
            return true
        }
    }

    // MARK: 2

    func testCodeContentIsNeverReadForMarksOrBlocks() {
        let md = "before\n```swift\n# x\n**x** and `y` [l](http://a.b) https://c.d\n- item\n> q\n---\n| a | b |\n|---|---|\n```\n~~~\n# t\n~~~\n"
        let doc = NoteDocument(markdown: md)
        XCTAssertEqual(doc.blocks.map(\.kind), [.paragraph, .fence, .fence])
        XCTAssertEqual(doc.blocks[1].runs, [Run("# x\n**x** and `y` [l](http://a.b) https://c.d\n- item\n> q\n---\n| a | b |\n|---|---|")])
        XCTAssertEqual(doc.blocks[1].fenceInfo, "swift")
        XCTAssertEqual(doc.blocks[2].runs, [Run("# t")])
        XCTAssertEqual(doc.markdown(), md)
    }

    func testCodeBlockEditsKeepOtherBytes() {
        let md = "# T\r\n```\r\n# x\r\n**x**\r\n```\r\n__b__ tail"
        var doc = NoteDocument(markdown: md)
        doc.apply(.replace(at: 0, kind: .heading(level: 2), runs: [Run("U")]))
        XCTAssertEqual(doc.markdown(), "## U\r\n```\r\n# x\r\n**x**\r\n```\r\n__b__ tail")
        doc.apply(.insertText(block: 1, offset: 3, text: "ab"))
        XCTAssertEqual(doc.markdown(), "## U\r\n```\r\n# xab\r\n**x**\r\n```\r\n__b__ tail")
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
    }

    // MARK: 3

    func testFenceLinesAndInfoSurviveContentEdits() {
        var doc = NoteDocument(markdown: "~~~~ rust {a}\nfn main() {}\n~~~~~~  \nx\n")
        doc.apply(.insertText(block: 0, offset: 0, text: "// "))
        XCTAssertEqual(doc.markdown(), "~~~~ rust {a}\n// fn main() {}\n~~~~~~  \nx\n")
        doc.apply(.replace(at: 0, kind: .fence, runs: [Run("a\nb")]))
        XCTAssertEqual(doc.markdown(), "~~~~ rust {a}\na\nb\n~~~~~~  \nx\n")
        doc.apply(.split(block: 0, offset: 1))     // Enter inside code adds a line
        XCTAssertEqual(doc.markdown(), "~~~~ rust {a}\na\n\nb\n~~~~~~  \nx\n")
        doc.apply(.setMark(block: 0, range: 0..<2, mark: .bold))   // marks do not exist in code
        XCTAssertEqual(doc.blocks[0].runs, [Run("a\n\nb")])
        doc.apply(.deleteText(block: 0, range: 0..<4))
        XCTAssertEqual(doc.markdown(), "~~~~ rust {a}\n\n~~~~~~  \nx\n".replacingOccurrences(of: "\n\n~~~~~~", with: "\n~~~~~~"))
        // Content that looks like the closing line makes the fence longer instead of ending it.
        doc.apply(.replace(at: 0, kind: .fence, runs: [Run("a\n~~~~~~\nb")]))
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[0].text, "a\n~~~~~~\nb")
        XCTAssertEqual(doc.blocks[0].fenceInfo, "rust {a}")
        // A new code block uses the default fence.
        var fresh = NoteDocument(markdown: "")
        fresh.apply(.insert(at: 0, kind: .fence, runs: [Run("x")]))
        XCTAssertEqual(fresh.markdown(), "```\nx\n```\n")
    }

    func testFenceLinesSurviveContentEdits_generated() {
        forEachSeed { seed, gen in
            let md = gen.markdown()
            var doc = NoteDocument(markdown: md)
            guard let i = doc.blocks.indices.first(where: { doc.blocks[$0].kind == .fence }) else { return true }
            let before = doc.blocks[i]
            let typed = gen.pick(["x", "// c", "\nz"])
            doc.apply(.insertText(block: i, offset: gen.int(before.text.utf16.count + 1), text: typed))
            let after = doc.blocks[i]
            // A line break can cut a content line so that its front reads as a closing fence: the fence is then longer
            // (same character, same info word, closing line still there), never changed otherwise.
            func fenceChar(_ b: Block) -> Character? { b.prefix.first }
            func fenceLength(_ b: Block) -> Int { b.prefix.prefix(while: { $0 == b.prefix.first }).count }
            let sameFence = fenceChar(after) == fenceChar(before) && fenceLength(after) >= fenceLength(before)
                && after.fenceInfo == before.fenceInfo && !after.trailer.isEmpty == !before.trailer.isEmpty
                && after.trailer.first == before.trailer.first
            let unchanged = after.prefix == before.prefix && after.trailer == before.trailer
            let ok = after.kind == .fence && sameFence && (unchanged || typed.contains("\n"))
            XCTAssertTrue(ok, "seed \(seed) \(md.debugDescription): \(before.prefix.debugDescription)/\(before.trailer.debugDescription) -> \(after.prefix.debugDescription)/\(after.trailer.debugDescription)")
            return ok
        }
    }

    // MARK: 4

    func testCellEditChangesOnlyTheTable() {
        let md = "# Head\n\n|a|b|\n|:-|-:|\n| x | **y** |\n\n__tail__\n"
        var doc = NoteDocument(markdown: md)
        XCTAssertEqual(doc.blocks.map(\.kind), [.heading(level: 1), .paragraph, .table, .paragraph, .paragraph])
        // "a\tb\u{2028}x\ty" - insert in the first body cell
        let t = doc.blocks[2].text
        XCTAssertEqual(t, "a\tb\u{2028}x\ty")
        doc.apply(.insertText(block: 2, offset: 5, text: "1"))
        let out = lines(doc.markdown())
        XCTAssertEqual(out, ["# Head", "", "| a | b |", "|:-|-:|", "| x1 | **y** |", "", "__tail__", ""])
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        // An unedited table keeps its bytes, also next to an edited one.
        var other = NoteDocument(markdown: md)
        other.apply(.insertText(block: 4, offset: 0, text: "z"))
        XCTAssertEqual(lines(other.markdown()).prefix(6), ["# Head", "", "|a|b|", "|:-|-:|", "| x | **y** |", ""])
    }

    func testCellEditsGiveValidPipeTables_generated() {
        forEachSeed { seed, gen in
            let md = gen.markdown()
            var doc = NoteDocument(markdown: md)
            guard let i = doc.blocks.indices.first(where: { doc.blocks[$0].kind == .table }) else { return true }
            let text = doc.blocks[i].text
            func withoutTable(_ d: NoteDocument) -> String { var c = d; c.apply(.remove(at: i)); return c.markdown() }
            let before = withoutTable(doc)
            // Type a character at a random place inside the text of one cell (not on a separator).
            let units = Array(text.utf16)
            let places = (0...units.count).filter { p in p == units.count || (units[p] != 9 && units[p] != 0x2028) }
            doc.apply(.insertText(block: i, offset: places[gen.int(places.count)], text: "k"))
            var ok = withoutTable(doc).utf8.elementsEqual(before.utf8)
            XCTAssertTrue(ok, "seed \(seed): another block changed in \(md.debugDescription)")
            // Valid pipe table: it reads back as a table with the same cells.
            let reloaded = NoteDocument(markdown: doc.markdown())
            XCTAssertTrue(doc.blocks[i].kind == .table && reloaded.blocks[i].kind == .table, "seed \(seed): \(doc.markdown().debugDescription)")
            XCTAssertEqual(reloaded, doc, "seed \(seed)")
            return ok && reloaded == doc
        }
    }

    // MARK: 5

    func testTableCellsKeepTheirMarks() {
        let md = "| **b** | *i* `c` |\n|---|---|\n| [l](http://x.y) ~~s~~ | <u>u</u> https://a.b |\n"
        var doc = NoteDocument(markdown: md)
        let marks = doc.blocks[0].runs
        XCTAssertTrue(marks.contains { $0.bold != nil } && marks.contains { $0.italic != nil } && marks.contains { $0.code }
                      && marks.contains { $0.link != nil } && marks.contains { $0.strikethrough } && marks.contains { $0.underline }
                      && marks.contains { $0.pill != nil })
        doc.apply(.insertText(block: 0, offset: 0, text: "n"))      // edit a cell: the table is regenerated
        XCTAssertEqual(doc.markdown(), "| **nb** | *i* `c` |\n|---|---|\n| [l](http://x.y) ~~s~~ | <u>u</u> https://a.b |\n")
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()).blocks[0].runs.filter { $0.bold != nil }.map(\.text), ["nb"])
        doc.apply(.setMark(block: 0, range: 0..<1, mark: .underline))
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        // A pipe inside a cell is written escaped and read back.
        doc.apply(.insertText(block: 0, offset: 1, text: "|"))
        XCTAssertTrue(doc.markdown().contains("\\|"), doc.markdown())
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
    }

    // MARK: table shapes of the old editor (MarkdownInlineParser.findTableBlocks)

    /// Every shape the old detector drew as a grid: a line with a pipe, then a delimiter line of `| - :` and blanks with
    /// a pipe and a dash, then lines with a pipe. Header and delimiter widths need not agree there.
    static let oldTableShapes: [(name: String, md: String, rows: Int)] = [
        ("outer pipes", "| a | b |\n|---|---|\n| 1 | 2 |\n", 2),
        ("no outer pipes", "a | b\n--|--\n1 | 2\n", 2),
        ("no outer pipes, spaced", "x | y\n--- | ---\nbody | row\nmore | rows\n", 3),
        ("alignment colons", "| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |\n", 2),
        ("colons without outer pipes", "x | y\n:--- | ---:\n1 | 2", 2),
        ("indented rows", "  | a | b |\n  |---|---|\n  | 1 | 2 |\n", 2),
        ("tab indented, pipe-less", "\ta | b\n\t-|-\n\t1 | 2\n", 2),
        ("leading pipe only", "| a | b\n|---|---\n| 1 | 2\n", 2),
        ("trailing pipe only", "a | b |\n--|--|\n1 | 2 |\n", 2),
        ("header only", "a|b\n-|-\n", 1),
        ("width mismatch", "| a | b |\n|---|\n| 1 |\n", 2),
        ("ragged body", "|x|y|z|\n|-|-|-|\n|1|\n| 1 | 2 | 3 | 4 |\n", 3),
        ("single column", "| a |\n|---|\n| 1 |\n", 2),
        ("crlf", "a | b\r\n--|--\r\n1 | 2\r\n", 2),
    ]

    func testEveryTableShapeOfTheOldEditorLoadsAsATableAndKeepsItsBytes() {
        for (name, md, _) in Self.oldTableShapes {
            for text in [md, "before\n\n" + md + "\nafter\n"] {
                let doc = NoteDocument(markdown: text)
                XCTAssertEqual(doc.blocks.filter { $0.kind == .table }.count, 1, "\(name): \(text.debugDescription)")
                XCTAssertEqual(doc.markdown(), text, name)
                // An edit elsewhere leaves the table's bytes alone.
                var other = doc
                if let i = other.blocks.firstIndex(where: { $0.kind == .paragraph && !$0.runs.isEmpty }) {
                    other.apply(.insertText(block: i, offset: 0, text: "Z"))
                    XCTAssertEqual(other.markdown(), text.replacingOccurrences(of: "before", with: "Zbefore"), name)
                }
            }
        }
    }

    func testCellEditKeepsAValidTableOfTheSameShape() {
        for (name, md, rows) in Self.oldTableShapes {
            var doc = NoteDocument(markdown: md)
            guard let t = doc.blocks.firstIndex(where: { $0.kind == .table }) else { XCTFail(name); continue }
            let before = doc.blocks[t].text.components(separatedBy: "\u{2028}")
            doc.apply(.insertText(block: t, offset: 0, text: "K"))
            let reloaded = NoteDocument(markdown: doc.markdown())
            XCTAssertEqual(reloaded, doc, name)
            XCTAssertEqual(reloaded.blocks.map(\.kind), [.table], "\(name): \(doc.markdown().debugDescription)")
            let after = reloaded.blocks[t].text.components(separatedBy: "\u{2028}")
            XCTAssertEqual(after.count, rows, name)
            XCTAssertEqual(after.dropFirst().joined(), before.dropFirst().joined(), "\(name): only the edited cell changes")
            XCTAssertTrue(after[0].hasPrefix("K"), name)
            // Written in the regular layout, with a delimiter row as wide as the header.
            let lines = doc.markdown().components(separatedBy: "\n")
            XCTAssertTrue(lines[0].hasPrefix("| K"), "\(name): \(lines[0])")
            func width(_ l: String) -> Int {
                var cells = l.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if l.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("|") { cells.removeFirst() }
                if cells.count > 1, cells.last!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cells.removeLast() }
                return cells.count
            }
            XCTAssertEqual(width(lines[1]), width(lines[0]), name)
        }
    }

    func testALineWithAPipeWithoutADelimiterRowStaysAParagraph() {
        for md in ["a | b\nc | d\n", "a | b\n", "a | b\n\n--|--\n", "x | y\n--\n", "x | y\n---\n1 | 2\n", "a \\| b\n--|--\n",
                   "`a|b`\n-|-\n", "- a | b\n--|--\n", "# a | b\n--|--\n", "> a | b\n--|--\n"] {
            let doc = NoteDocument(markdown: md)
            XCTAssertFalse(doc.blocks.contains { $0.kind == .table }, md.debugDescription)
            XCTAssertEqual(doc.markdown(), md)
        }
        // A text line with a pipe directly below a table is a row of it (as in the old editor); after a blank it is text.
        XCTAssertEqual(NoteDocument(markdown: "a|b\n-|-\nrow | x\n").blocks.map(\.kind), [.table])
        XCTAssertEqual(NoteDocument(markdown: "a|b\n-|-\n\nrow | x\n").blocks.map(\.kind), [.table, .paragraph, .paragraph])
    }

    func testPipeLinesAreWrittenEscapedWhenTheyWouldJoinATable() {
        var doc = NoteDocument(markdown: "a|b\n-|-\n\nnote | x\n")
        doc.apply(.remove(at: 1))                    // the blank line between the table and the text goes
        XCTAssertEqual(doc.blocks.map(\.kind), [.table, .paragraph])
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        XCTAssertTrue(doc.markdown().contains("note \\| x"), doc.markdown())
        // Text typed into a paragraph above a delimiter-looking line.
        var two = NoteDocument(markdown: "x\n--|--\n")
        two.apply(.insertText(block: 0, offset: 1, text: " | y"))
        XCTAssertEqual(NoteDocument(markdown: two.markdown()), two)
        XCTAssertEqual(two.blocks.map(\.kind), [.paragraph, .paragraph])
    }

    func testRewrittenLookalikeLineKeepsItsMarkDelimiters() {
        var doc = NoteDocument(markdown: "a | _x ___b__ y_\n```swift **b**\n")
        doc.apply(.insert(at: 1, kind: .paragraph, runs: [Run("-|-")]))
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        XCTAssertEqual(doc.markdown(), "a \\| _x ___b__ y_\n-|-\n```swift **b**\n")   // one line is enough
        doc.apply(.insert(at: 3, kind: .fence, runs: [Run("c")]))      // a code block below an unclosed fence line
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        XCTAssertEqual(lines(doc.markdown())[2], "\\```swift **b**")
    }

    // MARK: unclosed fence, corner cases

    func testUnclosedFenceIsText() {
        let md = "```swift\n# h\n**b**\n"
        let doc = NoteDocument(markdown: md)
        XCTAssertEqual(doc.blocks.map(\.kind), [.paragraph, .heading(level: 1), .paragraph])
        XCTAssertEqual(doc.markdown(), md)
        // A header row without a delimiter row is text as well.
        XCTAssertEqual(NoteDocument(markdown: "| a | b |\n| c | d |\n").blocks.map(\.kind), [.paragraph, .paragraph])
    }

    func testLookalikeLinesAreEscapedWhenAFenceArrives() {
        // "```" alone is text (unclosed). A code block added below would close it, so the text line is written escaped.
        var doc = NoteDocument(markdown: "```\nnote\n")
        XCTAssertEqual(doc.blocks.map(\.kind), [.paragraph, .paragraph])
        doc.apply(.insert(at: 2, kind: .fence, runs: [Run("code")]))
        XCTAssertEqual(doc.blocks.map(\.kind), [.paragraph, .paragraph, .fence])
        XCTAssertEqual(doc.markdown(), "\\```\nnote\n```\ncode\n```\n")
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        // Lines of text start with `|` but are not a table; a table next to them must not swallow them.
        var rows = NoteDocument(markdown: "|a|\n\n|-|\n")
        XCTAssertEqual(rows.blocks.map(\.kind), [.paragraph, .paragraph, .paragraph])
        rows.apply(.remove(at: 1))                       // the blank line between them goes
        XCTAssertEqual(rows.blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(NoteDocument(markdown: rows.markdown()), rows)
        // Without any code block or table nothing is rewritten.
        var plain = NoteDocument(markdown: "```\n| a |\n# x\n")
        plain.apply(.replace(at: 2, kind: .paragraph, runs: [Run("y")]))
        XCTAssertEqual(plain.markdown(), "```\n| a |\ny\n")
    }

    func testCornerCasesStayStable() {
        // Text that looks like a fence or a table row is escaped on write.
        var doc = NoteDocument(markdown: "")
        for (i, t) in ["```", "~~~ x", "| a |", "|---|"].enumerated() { doc.apply(.insert(at: i, kind: .paragraph, runs: [Run(t)])) }
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        XCTAssertEqual(doc.blocks.map(\.kind), [.paragraph, .paragraph, .paragraph, .paragraph])
        // Two tables made to touch read back as one.
        var tables = NoteDocument(markdown: "|a|\n|-|\n\n|b|\n|-|\n")
        XCTAssertEqual(tables.blocks.map(\.kind), [.table, .paragraph, .table])
        tables.apply(.remove(at: 1))
        XCTAssertEqual(tables.blocks.map(\.kind), [.table])
        XCTAssertEqual(NoteDocument(markdown: tables.markdown()), tables)
        // Join never mixes text into a code block or table; a blank next to one is taken away.
        var j = NoteDocument(markdown: "x\n```\nc\n```\n\ny\n")
        j.apply(.join(block: 0)); XCTAssertEqual(j.markdown(), "x\n```\nc\n```\n\ny\n")
        j.apply(.join(block: 1)); XCTAssertEqual(j.markdown(), "x\n```\nc\n```\ny\n")
        // Empty code block and an empty one-line block read alike; an edit writes the regular form.
        var e = NoteDocument(markdown: "```\n```\n```\n\n```\n")
        XCTAssertEqual(e.blocks.map(\.text), ["", ""])
        e.apply(.insertText(block: 1, offset: 0, text: "x"))
        XCTAssertEqual(e.markdown(), "```\n```\n```\nx\n```\n")
    }
}
