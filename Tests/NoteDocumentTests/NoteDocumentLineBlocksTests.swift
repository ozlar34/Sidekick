import XCTest
import Foundation
import NoteDocument

/// Criterion -> test map (ticket 03-note-document-line-blocks-and-marks)
/// 1. all properties of ticket 02 hold with the extended generator
///      -> the ticket-02 tests in NoteDocumentTests.swift, now fed bullets, numbers, checklists, quotes, dividers and
///         every mark by `DocumentGenerator`, plus the new corpus entries (testEveryLineBlockAndMarkLoadsAsItsKind
///         pins that the generator and corpus really reach the new kinds and marks)
/// 2. `*` bullets, `_` italics, `1)` numbers, `[X]` keep their spelling after an edit elsewhere in the same block kind
///      -> testSpellingsSurviveEditsInTheSameBlockKind (example), testLiteralPrefixSurvivesTextEdits_generated (property)
/// 3. toggling a checklist item changes only the bracket character
///      -> testToggleChangesOnlyTheBracketCharacter (example), testToggleChangesOnlyTheBracketCharacter_generated
/// 4. a bare URL and a link whose label equals its address load as a pill and save in their original form
///      -> testPillsLoadAndKeepTheirForm
/// 5. a line of three or more `-`, `*`, `_` is a divider and saves with its spelling
///      -> testDividerSpellingsAreKept
/// 6. edits (visible text is kept by mark and kind edits: testMarkAndKindEditsKeepTheVisibleText_generated): insert/delete text, set/clear mark on a range, set block kind, toggle checkbox, split, join
///      -> testInsertAndDeleteText, testSetAndClearMarks, testSetBlockKind, testSplitAndJoin (examples);
///         the stability property in NoteDocumentTests (testSaveLoadEqualsDocument_afterEdits) draws every edit
final class NoteDocumentLineBlocksTests: XCTestCase {

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

    // MARK: 1. generator and corpus reach everything

    func testEveryLineBlockAndMarkLoadsAsItsKind() {
        var kinds = Set<Int>()
        var marks = Set<String>()
        func note(_ doc: NoteDocument) {
            for b in doc.blocks {
                switch b.kind {
                case .paragraph: kinds.insert(0)
                case .heading: kinds.insert(1)
                case .bullet: kinds.insert(2)
                case .numbered: kinds.insert(3)
                case .checklist(let c): kinds.insert(c ? 5 : 4)
                case .quote: kinds.insert(6)
                case .divider: kinds.insert(7)
                }
                for r in b.runs {
                    if r.bold != nil { marks.insert("bold") }
                    if r.italic != nil { marks.insert("italic") }
                    if r.underline { marks.insert("underline") }
                    if r.strikethrough { marks.insert("strike") }
                    if r.code { marks.insert("code") }
                    if r.link != nil { marks.insert("link") }
                    if r.pill == .bare { marks.insert("bare") }
                    if r.pill == .link { marks.insert("pilllink") }
                }
            }
        }
        for e in Corpus.all { note(NoteDocument(markdown: e.text)) }
        XCTAssertEqual(kinds, Set(0...7), "corpus kinds")
        XCTAssertEqual(marks, ["bold", "italic", "underline", "strike", "code", "link", "bare", "pilllink"], "corpus marks")
        kinds = []; marks = []
        for seed in 1...200 { var g = DocumentGenerator(seed: UInt64(seed)); note(NoteDocument(markdown: g.markdown())) }
        XCTAssertEqual(kinds, Set(0...7), "generator kinds")
        XCTAssertEqual(marks, ["bold", "italic", "underline", "strike", "code", "link", "bare", "pilllink"], "generator marks")
    }

    func testMarksReadAsInTheApp() {
        func runs(_ s: String) -> [Run] { NoteDocument(markdown: s).blocks[0].runs }
        XCTAssertEqual(runs("*a* _b_"), [Run("a", italic: .asterisk), Run(" "), Run("b", italic: .underscore)])
        XCTAssertEqual(runs("<u>a</u> ~~b~~ `c`"), [Run("a", underline: true), Run(" "), Run("b", strikethrough: true), Run(" "), Run("c", code: true)])
        XCTAssertEqual(runs("[t](http://x.y)"), [Run("t", link: "http://x.y")])
        // Nested marks.
        XCTAssertEqual(runs("***a***"), [Run("a", bold: .asterisks, italic: .asterisk)])
        XCTAssertEqual(runs("**a *b* c**"), [Run("a", bold: .asterisks), Run(" "), Run("b", bold: .asterisks, italic: .asterisk), Run(" "), Run("c", bold: .asterisks)])
        XCTAssertEqual(runs("<u>**a**</u>"), [Run("a", bold: .asterisks, underline: true)])
        XCTAssertEqual(runs("[**a**](u)"), [Run("a", bold: .asterisks, link: "u")])
        // Inline code excludes other marks inside it.
        XCTAssertEqual(runs("`**a** *b*`"), [Run("**a** *b*", code: true)])
        // snake_case is text; an image stays literal.
        XCTAssertEqual(runs("snake_case_name"), [Run("snake_case_name")])
        XCTAssertEqual(runs("![i](x.png)"), [Run("![i](x.png)")])
    }

    // MARK: 2. spellings

    func testInsertedNumberedItemContinuesTheNumberOfTheItemAbove() {
        var doc = NoteDocument(markdown: "3) x\n  9. y\n- z\n")
        doc.apply(.insert(at: 1, kind: .numbered, runs: [Run("new")]))
        doc.apply(.insert(at: 3, kind: .numbered, runs: [Run("after y")]))
        doc.apply(.insert(at: 5, kind: .numbered, runs: [Run("after bullet")]))
        XCTAssertEqual(doc.markdown(), "3) x\n4) new\n  9. y\n  10. after y\n- z\n1. after bullet\n")
    }

    func testSpellingsSurviveEditsInTheSameBlockKind() {
        let md = "* star a\n* star b\n1) one\n2) two\n- [X] done\n- [ ] open\n_it_ and __b__\n  - indented\n"
        var doc = NoteDocument(markdown: md)
        // Edit one block of each kind; the others are untouched and the edited ones keep their literal forms.
        doc.apply(.insertText(block: 1, offset: 0, text: "new "))
        doc.apply(.insertText(block: 3, offset: 0, text: "x"))
        doc.apply(.insertText(block: 4, offset: 4, text: "!"))
        doc.apply(.insertText(block: 5, offset: 0, text: "re"))
        doc.apply(.insertText(block: 6, offset: 8, text: "!"))
        doc.apply(.insertText(block: 7, offset: 0, text: "more "))
        XCTAssertEqual(doc.markdown(), "* star a\n* new star b\n1) one\n2) xtwo\n- [X] done!\n- [ ] reopen\n_it_ and __b!__\n  - more indented\n")
        // A block of the same kind added later takes the document's defaults, not the file's spelling.
        doc.apply(.insert(at: 8, kind: .bullet, runs: [Run("d")]))
        doc.apply(.insert(at: 9, kind: .checklist(checked: false), runs: [Run("c")]))
        doc.apply(.insert(at: 10, kind: .numbered, runs: [Run("n")]))
        doc.apply(.insert(at: 11, kind: .divider, runs: []))
        doc.apply(.insert(at: 12, kind: .quote, runs: [Run("q", italic: .asterisk, strikethrough: true)]))
        XCTAssertEqual(lines(doc.markdown()).suffix(6), ["- d", "- [ ] c", "1. n", "---", "> ~~*q*~~", ""])
    }

    func testLiteralPrefixSurvivesTextEdits_generated() {
        forEachSeed { seed, gen in
            var doc = NoteDocument(markdown: gen.markdown())
            guard !doc.blocks.isEmpty else { return true }
            let i = gen.int(doc.blocks.count)
            let before = doc.blocks[i]
            guard before.kind != .divider else { return true }
            doc.apply(.insertText(block: i, offset: gen.int(before.text.utf16.count + 1), text: "z"))
            let after = doc.blocks[i]
            // An empty heading or list item gains the blank that separates its marker from the first text.
            let grown = after.prefix.hasPrefix(before.prefix) && after.prefix.dropFirst(before.prefix.count).allSatisfy { $0 == " " || $0 == "\t" }
            let ok = after.kind == before.kind && (after.prefix.utf8.elementsEqual(before.prefix.utf8) || (before.runs.isEmpty && grown))
            XCTAssertTrue(ok, "seed \(seed) block \(i): \(before.prefix.debugDescription) -> \(after.prefix.debugDescription) \(before.runs) -> \(after.runs)")
            return ok
        }
    }

    func testMarkDelimitersSurviveEditsInTheSameBlock() {
        var doc = NoteDocument(markdown: "_it_ __bo__ end\n")
        doc.apply(.insertText(block: 0, offset: 15, text: "!"))
        XCTAssertEqual(doc.markdown(), "_it_ __bo__ end!\n")
        doc.apply(.setMark(block: 0, range: 8..<11, mark: .bold))          // " end" -> reuse the file's bold style
        XCTAssertTrue(doc.markdown().hasPrefix("_it_ __bo__"), doc.markdown())
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
    }

    func testMarkAndKindEditsKeepTheVisibleText_generated() {
        forEachSeed { seed, gen in
            var doc = NoteDocument(markdown: gen.markdown())
            for _ in 0..<FuzzConfig.stepsPerSeed {
                let e = gen.edit(in: doc)
                var index: Int?
                switch e {
                case .setMark(let b, _, _), .clearMark(let b, _, _), .toggleCheckbox(let b): index = b
                case .setKind(let b, let k) where k != .divider && doc.blocks[b].kind != .divider: index = b
                default: break
                }
                let before = index.map { doc.blocks[$0].text }
                doc.apply(e)
                // Leading blanks of a list item or heading belong to its prefix.
                func lead(_ s: String) -> String { String(s.drop(while: { $0 == " " || $0 == "\t" })) }
                if let i = index, let b = before, lead(doc.blocks[i].text) != lead(b) {
                    XCTFail("seed \(seed) \(e): text \(b.debugDescription) -> \(doc.blocks[i].text.debugDescription)")
                    return false
                }
            }
            return true
        }
    }

    /// Review finding B: an edited block never loses its marks to a catch-all fallback. These inputs used to need it
    /// (code content that looks like the closer of an outer mark; a link whose label is its address).
    func testPathologicalMarksAreKeptNotCollapsed() {
        let cases: [(BlockKind, [Run])] = [
            (.bullet, [Run("</u>xx", underline: true, code: true)]),
            (.paragraph, [Run("\\#  ~~", bold: .asterisks, strikethrough: true, code: true)]),
            (.numbered, [Run("[ ] t", italic: .asterisk, code: true, link: "u")]),
            (.paragraph, [Run("http://x.y", link: "http://x.y")]),
            (.paragraph, [Run("a", bold: .asterisks, code: true), Run("b ~~ c", strikethrough: true, code: true)]),
        ]
        for (kind, runs) in cases {
            var doc = NoteDocument(markdown: "")
            doc.apply(.insert(at: 0, kind: kind, runs: runs))
            let block = doc.blocks[0]
            XCTAssertEqual(block.text, runs.map(\.text).joined(), "\(runs)")
            XCTAssertTrue(block.runs.contains { !($0.bold == nil && $0.italic == nil && !$0.underline && !$0.strikethrough && !$0.code && $0.link == nil && $0.pill == nil) },
                          "marks dropped for \(runs): \(doc.markdown().debugDescription)")
            XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc, "\(runs)")
        }
        // Code content does not close an outer mark.
        XCTAssertEqual(NoteDocument(markdown: "<u>`</u>x`</u>\n").blocks[0].runs, [Run("</u>x", underline: true, code: true)])
    }

    // MARK: 3. checklist toggle

    func testToggleChangesOnlyTheBracketCharacter() {
        let md = "  * [ ] **a****b** \\_x  \r\n- [X] done\n"
        var doc = NoteDocument(markdown: md)
        doc.apply(.toggleCheckbox(block: 0))
        XCTAssertEqual(doc.markdown(), "  * [x] **a****b** \\_x  \r\n- [X] done\n")
        doc.apply(.toggleCheckbox(block: 1))
        XCTAssertEqual(doc.markdown(), "  * [x] **a****b** \\_x  \r\n- [ ] done\n")
        doc.apply(.toggleCheckbox(block: 1))      // checking again restores the file's own `X`
        XCTAssertEqual(doc.markdown(), "  * [x] **a****b** \\_x  \r\n- [X] done\n")
        doc.apply(.toggleCheckbox(block: 0)); doc.apply(.toggleCheckbox(block: 0))
        XCTAssertEqual(doc.markdown(), "  * [x] **a****b** \\_x  \r\n- [X] done\n")
        // On a block that is not a checklist item it does nothing.
        var other = NoteDocument(markdown: "- plain\n")
        other.apply(.toggleCheckbox(block: 0))
        XCTAssertEqual(other.markdown(), "- plain\n")
        // A new checklist item is unchecked and spelled `- [ ] `; toggling writes `x`.
        var fresh = NoteDocument(markdown: "")
        fresh.apply(.insert(at: 0, kind: .checklist(checked: false), runs: [Run("t")]))
        fresh.apply(.toggleCheckbox(block: 0))
        XCTAssertEqual(fresh.markdown(), "- [x] t\n")
    }

    func testToggleChangesOnlyTheBracketCharacter_generated() {
        forEachSeed { seed, gen in
            let md = gen.markdown()
            var doc = NoteDocument(markdown: md)
            let checklists = doc.blocks.indices.filter { if case .checklist = doc.blocks[$0].kind { return true } else { return false } }
            guard !checklists.isEmpty else { return true }
            let i = checklists[gen.int(checklists.count)]
            doc.apply(.toggleCheckbox(block: i))
            let a = Array(md.utf8), b = Array(doc.markdown().utf8)
            let diff = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }
            let sameLength = a.count == b.count
            // exactly one byte differs, and it is the x/X/space between `[` and `]`
            var ok = sameLength && diff.count == 1
            if ok, let d = diff.first { ok = d.offset > 0 && a[d.offset - 1] == UInt8(ascii: "[") && a[d.offset + 1] == UInt8(ascii: "]") }
            XCTAssertTrue(ok, "seed \(seed) block \(i) of \(md.debugDescription) -> \(doc.markdown().debugDescription)")
            return ok
        }
    }

    // MARK: 4. pills

    func testPillsLoadAndKeepTheirForm() {
        let md = "see https://example.com/a_b and [https://x.y](https://x.y) end\n[label](https://x.y) https://c.d.\n"
        var doc = NoteDocument(markdown: md)
        XCTAssertEqual(doc.blocks[0].runs, [Run("see "), Run("https://example.com/a_b", pill: .bare), Run(" and "),
                                            Run("https://x.y", pill: .link), Run(" end")])
        XCTAssertEqual(doc.blocks[1].runs, [Run("label", link: "https://x.y"), Run(" "), Run("https://c.d", pill: .bare), Run(".")])
        XCTAssertEqual(doc.markdown(), md)
        // An edit elsewhere in the same block regenerates it and still writes each pill in its own form.
        doc.apply(.insertText(block: 0, offset: 0, text: "go "))
        doc.apply(.insertText(block: 1, offset: 0, text: "> "))
        XCTAssertEqual(doc.markdown(), "go see https://example.com/a_b and [https://x.y](https://x.y) end\n> [label](https://x.y) https://c.d.\n".replacingOccurrences(of: "> [label]", with: "\\> [label]"))
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
    }

    func testPillIsOneObjectForTextEdits() {
        var doc = NoteDocument(markdown: "a https://x.y/z b\n")
        doc.apply(.deleteText(block: 0, range: 5..<7))                      // inside the pill: all of it goes
        XCTAssertEqual(doc.markdown(), "a  b\n")
        var d2 = NoteDocument(markdown: "a https://x.y/z b\n")
        d2.apply(.insertText(block: 0, offset: 8, text: "Q"))               // inside the pill: lands before it
        XCTAssertEqual(d2.blocks[0].runs.map(\.text), ["a Q", "https://x.y/z", " b"])
        // Text typed right after a bare pill must not be swallowed into it: the pill is respelled as a link.
        var d3 = NoteDocument(markdown: "https://x.y\n")
        d3.apply(.insertText(block: 0, offset: 11, text: "abc"))
        XCTAssertEqual(d3.blocks[0].runs, [Run("https://x.y", pill: .link), Run("abc")])
        XCTAssertEqual(d3.markdown(), "[https://x.y](https://x.y)abc\n")
        XCTAssertEqual(NoteDocument(markdown: d3.markdown()), d3)
    }

    // MARK: 5. dividers

    func testDividerSpellingsAreKept() {
        let spellings = ["---", "***", "___", "-----", "*****", "  ---  ", "\t___", "- - -x"]
        let md = spellings.joined(separator: "\n") + "\ntext\n"
        var doc = NoteDocument(markdown: md)
        XCTAssertEqual(doc.blocks.prefix(7).map(\.kind), Array(repeating: BlockKind.divider, count: 7))
        XCTAssertEqual(doc.blocks[7].kind, .bullet)
        doc.apply(.replace(at: 8, kind: .paragraph, runs: [Run("changed")]))
        doc.apply(.setKind(block: 1, kind: .divider))                      // same kind again: spelling stays
        doc.apply(.replace(at: 4, kind: .divider, runs: [Run("ignored")]))
        XCTAssertEqual(doc.markdown(), spellings.joined(separator: "\n") + "\nchanged\n")
        // A paragraph that reads like a divider is escaped; a new divider uses `---`.
        var d2 = NoteDocument(markdown: "")
        d2.apply(.insert(at: 0, kind: .paragraph, runs: [Run("---")]))
        d2.apply(.insert(at: 1, kind: .divider, runs: []))
        XCTAssertEqual(d2.markdown(), "\\---\n---\n")
        XCTAssertEqual(NoteDocument(markdown: d2.markdown()), d2)
    }

    // MARK: 6. edits

    func testInsertAndDeleteText() {
        var doc = NoteDocument(markdown: "a **bold** z\n")
        doc.apply(.insertText(block: 0, offset: 6, text: "er"))            // inside bold: takes its marks
        XCTAssertEqual(doc.markdown(), "a **bolder** z\n")
        doc.apply(.insertText(block: 0, offset: 0, text: "> "))            // would read as a quote: escaped
        XCTAssertEqual(doc.markdown(), "\\> a **bolder** z\n")
        doc.apply(.deleteText(block: 0, range: 0..<2))
        doc.apply(.deleteText(block: 0, range: 2..<8))
        XCTAssertEqual(doc.markdown(), "a  z\n")
        doc.apply(.insertText(block: 0, offset: 2, text: "line\nbreak"))   // line breaks are removed
        XCTAssertEqual(doc.markdown(), "a linebreak z\n")
        XCTAssertEqual(doc.blocks.count, 1)
        // Offsets count UTF-16 units; one inside a surrogate pair snaps down.
        var emoji = NoteDocument(markdown: "a\u{1F600}b\n")
        emoji.apply(.deleteText(block: 0, range: 1..<2))
        XCTAssertEqual(emoji.markdown(), "ab\n")
    }

    func testSetAndClearMarks() {
        var doc = NoteDocument(markdown: "one two three\n")
        doc.apply(.setMark(block: 0, range: 4..<7, mark: .bold))
        doc.apply(.setMark(block: 0, range: 4..<7, mark: .italic))
        doc.apply(.setMark(block: 0, range: 8..<13, mark: .link("http://x.y")))
        XCTAssertEqual(doc.markdown(), "one ***two*** [three](http://x.y)\n")
        doc.apply(.clearMark(block: 0, range: 4..<7, mark: .bold))
        XCTAssertEqual(doc.markdown(), "one *two* [three](http://x.y)\n")
        doc.apply(.setMark(block: 0, range: 0..<3, mark: .underline))
        doc.apply(.setMark(block: 0, range: 0..<3, mark: .strikethrough))
        XCTAssertEqual(doc.markdown(), "<u>~~one~~</u> *two* [three](http://x.y)\n")
        // Code replaces the other marks of its range; other marks skip code.
        doc.apply(.setMark(block: 0, range: 4..<7, mark: .code))
        doc.apply(.setMark(block: 0, range: 4..<7, mark: .bold))
        XCTAssertEqual(doc.markdown(), "<u>~~one~~</u> `two` [three](http://x.y)\n")
        doc.apply(.clearMark(block: 0, range: 0..<20, mark: .link("")))
        doc.apply(.clearMark(block: 0, range: 0..<3, mark: .underline))
        XCTAssertEqual(doc.markdown(), "~~one~~ `two` three\n")
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        // An empty range changes nothing.
        let before = doc.markdown()
        doc.apply(.setMark(block: 0, range: 3..<3, mark: .bold))
        XCTAssertEqual(doc.markdown(), before)
    }

    func testSetBlockKind() {
        var doc = NoteDocument(markdown: "* item\n## head\nplain\n")
        doc.apply(.setKind(block: 0, kind: .checklist(checked: false)))    // bullet char carried over
        doc.apply(.setKind(block: 1, kind: .heading(level: 4)))            // hashes change, spacing stays
        doc.apply(.setKind(block: 2, kind: .numbered))
        XCTAssertEqual(doc.markdown(), "* [ ] item\n#### head\n1. plain\n")
        doc.apply(.setKind(block: 0, kind: .paragraph))
        doc.apply(.setKind(block: 2, kind: .quote))
        XCTAssertEqual(doc.markdown(), "item\n#### head\n> plain\n")
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
    }

    func testSplitAndJoin() {
        var doc = NoteDocument(markdown: "- [x] ab**cd**\n# Head\n")
        doc.apply(.split(block: 0, offset: 2))
        XCTAssertEqual(doc.markdown(), "- [x] ab\n- [ ] **cd**\n# Head\n")
        doc.apply(.split(block: 2, offset: 4))                            // after a heading the next line is a paragraph
        XCTAssertEqual(doc.markdown(), "- [x] ab\n- [ ] **cd**\n# Head\n\n")
        doc.apply(.join(block: 1))
        XCTAssertEqual(doc.markdown(), "- [x] ab\n- [ ] **cd**Head\n\n")
        doc.apply(.join(block: 0))
        XCTAssertEqual(doc.blocks[0].text, "abcdHead")
        XCTAssertEqual(doc.blocks[0].kind, .checklist(checked: true))
        XCTAssertEqual(NoteDocument(markdown: doc.markdown()), doc)
        // A divider on either side of a join is dropped.
        var d = NoteDocument(markdown: "a\n---\nb\n")
        d.apply(.join(block: 0))
        XCTAssertEqual(d.markdown(), "a\nb\n")
        d.apply(.insert(at: 0, kind: .divider, runs: []))
        d.apply(.join(block: 0))
        XCTAssertEqual(d.markdown(), "a\nb\n")
        // Splitting a final line without newline keeps "no final newline" on the new last line.
        var tail = NoteDocument(markdown: "abcd")
        tail.apply(.split(block: 0, offset: 2))
        XCTAssertEqual(tail.markdown(), "ab\ncd")
    }
}
