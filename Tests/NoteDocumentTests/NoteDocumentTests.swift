import XCTest
import Foundation
import NoteDocument

/// Criterion -> test map (ticket 02-note-document-first-path; ticket 03 is in NoteDocumentLineBlocksTests.swift)
/// 1. byte-identical no-edit round trip (generated, corpus, CRLF, no final newline)
///      -> testRoundTripIsByteIdentical_corpus, testRoundTripIsByteIdentical_generated
/// 2. an edit in one block changes only that block's bytes
///      -> testReplaceChangesOnlyThatBlock_generated, testInsertAndRemoveKeepOtherBlocksUntouched
/// 3. heading level and bold survive load, edit, save, load
///      -> testHeadingLevelAndBoldSurviveEditSaveLoad (example), testSaveLoadEqualsDocument_afterEdits (property)
/// 4. text the module does not understand stays literal and round-trips
///      -> testUnsupportedMarkdownLoadsAsLiteralParagraphs, (and the round-trip tests above)
/// 5. property suite takes seed + budget from the environment
///      -> FuzzConfig (FuzzSupport.swift), used by every *_generated test; budget asserted in testBudgetNotExceeded helper
/// 6. no type imports a view framework
///      -> testModuleImportsOnlyFoundation (scans Sources/NoteDocument)
/// Text that could read as a fence opener or table row (a pipe or a fence character): a test-side approximation.
private func BlockSyntax_looksLikeFenceOrRow(_ text: String) -> Bool { text.contains("|") || text.hasPrefix("`") || text.hasPrefix("~") }

final class NoteDocumentTests: XCTestCase {

    // MARK: helpers

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Independent line splitter: segments keep their terminator ("\n" or "\r\n").
    private func segments(_ s: String) -> [[UInt8]] {
        var out: [[UInt8]] = [], cur: [UInt8] = []
        for b in s.utf8 { cur.append(b); if b == 10 { out.append(cur); cur = [] } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func forEachSeed(_ body: (UInt64, inout DocumentGenerator) -> Bool) {
        let start = Date()
        for i in 0..<FuzzConfig.seedCount {
            let seed = FuzzConfig.firstSeed &+ UInt64(i)
            var gen = DocumentGenerator(seed: seed)
            if !body(seed, &gen) { return }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(elapsed, Double(FuzzConfig.budgetSeconds),
            "Property budget overrun - raise SIDEKICK_FUZZ_BUDGET or lower SIDEKICK_FUZZ_SEEDS / SIDEKICK_FUZZ_STEPS")
    }

    // MARK: 1. round trip

    func testRoundTripIsByteIdentical_corpus() {
        let all = Corpus.all
        XCTAssertTrue(all.contains { $0.name.hasPrefix("fixture/") }, "debug-harness fixtures not found")
        XCTAssertTrue(all.contains { $0.name.hasSuffix("[crlf]") })
        XCTAssertTrue(all.contains { $0.name.hasSuffix("[no-final-newline]") })
        for e in all {
            let out = NoteDocument(markdown: e.text).markdown()
            XCTAssertEqual(bytes(out), bytes(e.text), "corpus entry \(e.name)")
        }
    }

    func testRoundTripIsByteIdentical_generated() {
        forEachSeed { seed, gen in
            let md = gen.markdown()
            let out = NoteDocument(markdown: md).markdown()
            XCTAssertEqual(bytes(out), bytes(md), "seed \(seed) input \(md.debugDescription)")
            return bytes(out) == bytes(md)
        }
    }

    // MARK: 2. one edit, one block

    func testReplaceChangesOnlyThatBlock_generated() {
        forEachSeed { seed, gen in
            let md = gen.markdown()
            var doc = NoteDocument(markdown: md)
            guard !doc.blocks.isEmpty else { return true }
            let i = gen.int(doc.blocks.count)
            let count = doc.blocks.count
            let kind = gen.kind()
            // A new code block or table can pair with a text line that only looks like a fence or a row (an unclosed
            // fence, a row without delimiter row); that line is then written escaped, see testLookalikeLinesAreEscapedWhenAFenceArrives.
            let lookalike = doc.blocks.contains { $0.kind == .paragraph && (BlockSyntax_looksLikeFenceOrRow($0.text)) }
            doc.apply(.replace(at: i, kind: kind, runs: gen.runs()))
            guard doc.blocks.count == count else { return true }   // adjacent tables become one block
            // A block spans one or more lines: compare the file without block `i`, before and after. Text lines that
            // look like a table row or fence may be rewritten escaped (their visible text is unchanged; settle may drop a
            // mark that cannot be written back).
            let pristine = NoteDocument(markdown: md)
            var before = pristine, after = doc
            before.apply(.remove(at: i)); after.apply(.remove(at: i))
            let ok = lookalike
                ? (0..<before.blocks.count).allSatisfy { j in j >= after.blocks.count || before.blocks[j].kind == after.blocks[j].kind && before.blocks[j].text == after.blocks[j].text }
                : bytes(before.markdown()) == bytes(after.markdown())
            XCTAssertTrue(ok, "seed \(seed) edit block \(i) of \(md.debugDescription) -> \(doc.markdown().debugDescription)")
            return ok
        }
    }

    func testInsertAndRemoveKeepOtherBlocksUntouched() {
        // Concrete: untouched blocks keep non-canonical forms while a neighbour changes.
        var doc = NoteDocument(markdown: "#   odd **a****b**\r\n__x__ \\_ y\r\nlast")
        doc.apply(.replace(at: 1, kind: .paragraph, runs: [Run("new")]))
        XCTAssertEqual(doc.markdown(), "#   odd **a****b**\r\nnew\r\nlast")
        doc.apply(.insert(at: 3, kind: .paragraph, runs: [Run("tail")]))   // after a no-final-newline block
        XCTAssertEqual(doc.markdown(), "#   odd **a****b**\r\nnew\r\nlast\r\ntail")
        doc.apply(.remove(at: 0))
        XCTAssertEqual(doc.markdown(), "new\r\nlast\r\ntail")
    }

    func testEditBackToLoadStateKeepsOriginalBytes() {
        var doc = NoteDocument(markdown: "__a__ and \\_ \n")
        let original = doc.blocks[0].runs
        doc.apply(.replace(at: 0, kind: .paragraph, runs: [Run("changed")]))
        doc.apply(.replace(at: 0, kind: .paragraph, runs: original))
        XCTAssertEqual(doc.markdown(), "__a__ and \\_ \n")
    }

    // MARK: 3. heading level + bold

    func testHeadingLevelAndBoldSurviveEditSaveLoad() {
        var doc = NoteDocument(markdown: "# Title\n\nbody\n")
        doc.apply(.replace(at: 0, kind: .heading(level: 3), runs: [Run("Big "), Run("bold", bold: .asterisks), Run(" end")]))
        doc.apply(.replace(at: 2, kind: .paragraph, runs: [Run("x", bold: .underscores), Run(" y")]))
        XCTAssertEqual(doc.markdown(), "### Big **bold** end\n\n__x__ y\n")
        let reloaded = NoteDocument(markdown: doc.markdown())
        XCTAssertEqual(reloaded, doc)
        XCTAssertEqual(reloaded.blocks[0].kind, .heading(level: 3))
        XCTAssertEqual(reloaded.blocks[0].runs, [Run("Big "), Run("bold", bold: .asterisks), Run(" end")])
        XCTAssertEqual(reloaded.blocks[2].runs, [Run("x", bold: .underscores), Run(" y")])
    }

    func testHeadingLevelChangeKeepsSpacing() {
        var doc = NoteDocument(markdown: "##   spaced\n")
        doc.apply(.replace(at: 0, kind: .heading(level: 4), runs: [Run("spaced!")]))
        XCTAssertEqual(doc.markdown(), "####   spaced!\n")
    }

    func testSaveLoadEqualsDocument_afterEdits() {
        forEachSeed { seed, gen in
            var doc = NoteDocument(markdown: gen.markdown())
            for step in 0..<FuzzConfig.stepsPerSeed {
                let e = gen.edit(in: doc)
                doc.apply(e)
                let md = doc.markdown()
                let reloaded = NoteDocument(markdown: md)
                if reloaded != doc {
                    let first = doc.blocks.indices.first { $0 >= reloaded.blocks.count || doc.blocks[$0] != reloaded.blocks[$0] } ?? 0
                    let line = md.components(separatedBy: "\n").dropFirst(first).first.map { $0.debugDescription } ?? "?"
                    XCTFail("seed \(seed) step \(step) edit \(e): block \(first) written as \(line) reloads differently\n\(doc.blocks[first])\nvs\n\(first < reloaded.blocks.count ? "\(reloaded.blocks[first])" : "missing")")
                    return false
                }
                if reloaded.markdown().utf8.elementsEqual(md.utf8) == false {
                    XCTFail("seed \(seed) step \(step): second save differs"); return false
                }
            }
            return true
        }
    }

    // MARK: 4. unknown markdown stays literal

    func testUnsupportedMarkdownLoadsAsLiteralParagraphs() {
        let lines = ["```swift", "| a | b |", "![i](x.png)", "<div>x</div>", "[^1]: n", "  # indented", "#######", "#nospace",
                     "+ plus", "-x", "1.x", ">x", "- []", "- [ ]x", "--", "* * *x", "- - -x"]
        let doc = NoteDocument(markdown: lines.joined(separator: "\n") + "\n")
        XCTAssertEqual(doc.blocks.count, lines.count)
        for (b, l) in zip(doc.blocks, lines) {
            // `* * *x`, `- - -x`, `- []`, `- [ ]x` are bullets whose text starts with brackets or dashes; the rest stay paragraphs.
            if l.hasPrefix("* ") || l.hasPrefix("- ") { XCTAssertEqual(b.kind, .bullet, l); continue }
            XCTAssertEqual(b.kind, .paragraph, l)
            XCTAssertEqual(b.text, l.hasPrefix("![") ? "![i](x.png)" : l, l)
        }
    }

    func testCodeFenceContentIsNotInterpretedAsHeading() {
        let md = "```\n# comment\n```\n"
        let doc = NoteDocument(markdown: md)
        XCTAssertEqual(doc.blocks.map(\.kind), [.fence])
        XCTAssertEqual(doc.blocks[0].text, "# comment")
        XCTAssertEqual(doc.markdown(), md)
    }

    func testBlankLinesAreEmptyParagraphs() {
        let doc = NoteDocument(markdown: "a\n\n\nb")
        XCTAssertEqual(doc.blocks.map(\.kind), [.paragraph, .paragraph, .paragraph, .paragraph])
        XCTAssertEqual(doc.blocks[1].runs, [])
    }

    func testEditCannotInjectLineBreaks() {
        var doc = NoteDocument(markdown: "a\nb\n")
        doc.apply(.replace(at: 0, kind: .paragraph, runs: [Run("x\ny\r")]))
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.markdown(), "xy\nb\n")
    }

    func testAppendingToEmptyAndTailEdges() {
        var doc = NoteDocument(markdown: "")
        doc.apply(.insert(at: 0, kind: .heading(level: 1), runs: [Run("T")]))
        XCTAssertEqual(doc.markdown(), "# T\n")
        var d2 = NoteDocument(markdown: "a")
        d2.apply(.replace(at: 0, kind: .paragraph, runs: []))       // would be an empty unterminated tail
        XCTAssertEqual(NoteDocument(markdown: d2.markdown()), d2)
    }

    // MARK: 6. purity

    func testModuleImportsOnlyFoundation() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NoteDocument")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") || line.contains("@_exported import") {
                XCTAssertEqual(line.trimmingCharacters(in: .whitespaces), "import Foundation", "\(f): \(line)")
            }
        }
    }
}
