import XCTest
import Foundation
import NoteDocument

/// Criterion -> test map (ticket 10-new-editor-typed-markdown), note-document seam (no window):
/// 1. each trigger converts
///      -> testEveryBlockTriggerConverts, testChecklistTriggersFireInABulletItemAndOnAPlainLine, testDividerTrigger,
///         testFenceTrigger, testEveryInlineTriggerConverts, testInlineTriggerInTheMiddleOfText, testBareURLBecomesAPillWhenCompleted,
///         testPasteTurnsEveryBareURLIntoAPill
/// 2. Cmd+Z (the document before the conversion) gives the typed characters, saved escaped, reloaded as literal text
///      -> testTheLiteralTextBeforeAConversionIsSavedEscapedAndReloadsLiteral, testLiteralTextStaysLiteralWhenTypingOn
/// 3. no trigger inside a code block, inline code or a table cell
///      -> testNoTriggerInACodeBlock, testNoTriggerInInlineCode, testNoTriggerInATableCell
/// 4. things that must not convert
///      -> testNearMissesStayLiteral
/// 5. typing sequences keep the document stable
///      -> testTypedSequencesKeepSaveLoadStable_generated
final class NoteDocumentTypedMarkdownTests: XCTestCase {

    /// Types `text` at the end of block `block`, one character at a time, applying the trigger after each.
    private struct Typist {
        var doc: NoteDocument
        var block = 0
        var conversions: [TypedConversion] = []
        var before: NoteDocument?   // the document just before the last conversion (what Cmd+Z restores)
        /// The editor types plain text (typing attributes drop the marks of the text before); `false` types with the marks
        /// of the character before, as when the caret is inside a styled run.
        var plain = true
        init(_ markdown: String = "\n", block: Int = 0) { doc = NoteDocument(markdown: markdown); self.block = block }
        mutating func type(_ text: String) {
            for ch in text {
                let len = doc.blocks[block].text.utf16.count
                doc.apply(.insertText(block: block, offset: len, text: String(ch)))
                if plain {
                    for mark in [Mark.bold, .italic, .underline, .strikethrough, .code] {
                        doc.apply(.clearMark(block: block, range: len..<len + String(ch).utf16.count, mark: mark))
                    }
                }
                let literal = doc
                if let c = doc.applyTyped(block: block, caret: len + String(ch).utf16.count, typed: ch) {
                    conversions.append(c)
                    before = literal
                    if c.lineBelow { block += 1 }
                }
            }
        }
        var markdown: String { doc.markdown() }
        var kind: BlockKind { doc.blocks[block].kind }
    }

    // MARK: 1. every trigger converts

    func testEveryBlockTriggerConverts() {
        let cases: [(String, BlockKind, String)] = [
            ("# ", .heading(level: 1), "# x\n"), ("## ", .heading(level: 2), "## x\n"), ("### ", .heading(level: 3), "### x\n"),
            ("#### ", .heading(level: 4), "#### x\n"), ("##### ", .heading(level: 5), "##### x\n"), ("###### ", .heading(level: 6), "###### x\n"),
            ("- ", .bullet, "- x\n"), ("* ", .bullet, "- x\n"), ("1. ", .numbered, "1. x\n"), ("> ", .quote, "> x\n"),
        ]
        for (typed, kind, md) in cases {
            var t = Typist()
            t.type(typed)
            XCTAssertEqual(t.conversions.count, 1, typed.debugDescription)
            XCTAssertEqual(t.kind, kind, typed.debugDescription)
            t.type("x")
            XCTAssertEqual(t.markdown, md, typed.debugDescription)
            XCTAssertEqual(t.conversions.count, 1, "typing on does not fire again: \(typed.debugDescription)")
        }
    }

    func testSevenHashesAreNoHeading() {
        var t = Typist()
        t.type("####### ")
        XCTAssertTrue(t.conversions.isEmpty)
        XCTAssertEqual(t.kind, .paragraph)
    }

    func testTypedNumberIsKept() {
        var t = Typist()
        t.type("7. x")
        XCTAssertEqual(t.kind, .numbered)
        XCTAssertEqual(t.markdown, "7. x\n")
        // Below a numbered item the typed number still wins over the continuation.
        var u = Typist("3. a\n\n", block: 1)
        u.type("1. y")
        XCTAssertEqual(u.markdown, "3. a\n1. y\n")
    }

    func testChecklistTriggersFireInABulletItemAndOnAPlainLine() {
        // Typed in a row, `- ` makes a bullet first, then `[ ] ` makes it a checklist item.
        for (typed, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] {
            var t = Typist()
            t.type(typed + "z")
            XCTAssertEqual(t.kind, .checklist(checked: checked), typed)
            XCTAssertEqual(t.markdown, checked ? "- [x] z\n" : "- [ ] z\n", typed)
        }
        // On a plain line that holds the literal characters (what Cmd+Z leaves), the last blank completes it too.
        let plain = TypedMarkdown.convert(kind: .paragraph, runs: [Run("- [ ] ")], caret: 6, typed: " ")
        XCTAssertEqual(plain?.kind, .checklist(checked: false))
        XCTAssertEqual(plain?.runs, [])
        XCTAssertNil(TypedMarkdown.convert(kind: .quote, runs: [Run("[ ] ")], caret: 4, typed: " "), "only a bullet item turns into a checklist item")
    }

    func testDividerTrigger() {
        var t = Typist("a\n\n", block: 1)
        t.type("---")
        XCTAssertEqual(t.conversions.count, 1)
        XCTAssertEqual(t.conversions.first?.kind, .divider)
        XCTAssertEqual(t.conversions.first?.lineBelow, true)
        XCTAssertEqual(t.doc.blocks.map(\.kind), [.paragraph, .divider, .paragraph])
        t.type("z")
        XCTAssertEqual(t.markdown, "a\n---\nz\n")
        // A fourth dash is not a trigger (it is typed below the rule), and `---` after text is not one.
        var u = Typist("a\n")
        u.type("---")
        XCTAssertTrue(u.conversions.isEmpty)
        XCTAssertEqual(u.doc.blocks.map(\.kind), [.paragraph])
    }

    func testFenceTrigger() {
        var t = Typist()
        t.type("```")
        XCTAssertEqual(t.conversions.count, 1)
        XCTAssertEqual(t.kind, .fence)
        XCTAssertEqual(t.conversions.first?.runs, [])
        XCTAssertEqual(t.markdown, "```\n```\n")
        t.type("let a = 1")
        XCTAssertEqual(t.markdown, "```\nlet a = 1\n```\n")
        var u = Typist("x\n")
        u.type("```")
        XCTAssertTrue(u.conversions.isEmpty, "a fence is a whole line of its own")
    }

    func testEveryInlineTriggerConverts() {
        let cases: [(String, Run, String)] = [
            ("**x**", Run("x", bold: .asterisks), "**x**"),
            ("*x*", Run("x", italic: .asterisk), "*x*"),
            ("_x_", Run("x", italic: .underscore), "_x_"),
            ("~~x~~", Run("x", strikethrough: true), "~~x~~"),
            ("`x`", Run("x", code: true), "`x`"),
            ("<u>x</u>", Run("x", underline: true), "<u>x</u>"),
        ]
        for (typed, run, md) in cases {
            var t = Typist()
            t.type(typed)
            XCTAssertEqual(t.conversions.count, 1, typed)
            XCTAssertEqual(t.doc.blocks[0].runs, [run], typed)
            XCTAssertEqual(t.conversions.first?.caret, 1, typed)
            XCTAssertEqual(t.markdown, md + "\n", typed)
        }
    }

    func testInlineTriggerInTheMiddleOfText() {
        var t = Typist()
        t.type("see **this** now")
        XCTAssertEqual(t.doc.blocks[0].runs, [Run("see "), Run("this", bold: .asterisks), Run(" now")])
        t.type(" and `code` and *it* here")
        XCTAssertEqual(t.doc.blocks[0].text, "see this now and code and it here")
        XCTAssertEqual(t.conversions.count, 3)
        // A heading and a list item hold marks too.
        var h = Typist()
        h.type("# a **b**")
        XCTAssertEqual(h.doc.blocks[0].runs, [Run("a "), Run("b", bold: .asterisks)])
        XCTAssertEqual(h.kind, .heading(level: 1))
    }

    func testBareURLBecomesAPillWhenCompleted() {
        for (typed, address, rest) in [("go https://example.com/a?b=1 ", "https://example.com/a?b=1", " "), ("https://x.co/y.\u{20}", "https://x.co/y", ".\u{20}"),
                                       ("(see http://x.co/p) ", "http://x.co/p", ") ")] {
            var t = Typist()
            t.type(typed)
            XCTAssertEqual(t.conversions.count, 1, typed)
            XCTAssertEqual(t.doc.blocks[0].runs.filter { $0.pill != nil }.map(\.text), [address], typed)
            XCTAssertTrue(t.doc.blocks[0].runs.last!.text.hasSuffix(rest), typed)
        }
        // Not completed: no pill. Completed by Enter (the caller reports "\n" typed with the caret at the line end).
        var open = Typist()
        open.type("go https://example.com/a")
        XCTAssertTrue(open.conversions.isEmpty)
        let enter = TypedMarkdown.convert(kind: .paragraph, runs: [Run("go https://example.com/a")], caret: 24, typed: "\n")
        XCTAssertEqual(enter?.runs, [Run("go "), Run("https://example.com/a", pill: .bare)])
        XCTAssertEqual(enter?.caret, 24)
        // Only http and https, and only at a word start.
        for text in ["ftp://x.co/a ", "xhttps://x.co/a ", "https:// ", "example.com "] {
            var t = Typist()
            t.type(text)
            XCTAssertTrue(t.conversions.isEmpty, text)
        }
        // Not inside a link label, inline code or an existing pill.
        for runs in [[Run("https://x.co/a ", link: "https://y.co")], [Run("https://x.co/a ", code: true)]] {
            XCTAssertNil(TypedMarkdown.convert(kind: .paragraph, runs: runs, caret: runs[0].text.utf16.count, typed: " "))
        }
    }

    func testPasteTurnsEveryBareURLIntoAPill() {
        let runs = [Run("a https://x.co/1 b https://x.co/2 c")]
        XCTAssertEqual(TypedMarkdown.pills(kind: .paragraph, runs: runs, overlapping: 0..<35),
                       [Run("a "), Run("https://x.co/1", pill: .bare), Run(" b "), Run("https://x.co/2", pill: .bare), Run(" c")])
        XCTAssertEqual(TypedMarkdown.pills(kind: .paragraph, runs: runs, overlapping: 20..<35),
                       [Run("a https://x.co/1 b "), Run("https://x.co/2", pill: .bare), Run(" c")], "only URLs the pasted range touches")
        XCTAssertNil(TypedMarkdown.pills(kind: .paragraph, runs: [Run("no url here")], overlapping: 0..<11))
        XCTAssertNil(TypedMarkdown.pills(kind: .fence, runs: [Run("https://x.co/1")], overlapping: 0..<14))
        XCTAssertNil(TypedMarkdown.pills(kind: .paragraph, runs: [Run("https://x.co/1", code: true)], overlapping: 0..<14))
    }

    // MARK: 2. the typed characters stay literal

    /// What Cmd+Z restores: the document with the typed characters as plain text. It saves escaped and reloads as the
    /// same literal text.
    func testTheLiteralTextBeforeAConversionIsSavedEscapedAndReloadsLiteral() {
        let triggers = ["# ", "###### ", "- ", "* ", "1. ", "> ", "---", "```", "**x**", "*x*", "_x_", "~~x~~", "`x`", "<u>x</u>"]
        for typed in triggers {
            var t = Typist()
            t.type(typed)
            guard let literal = t.before else { XCTFail("\(typed) did not convert"); continue }
            XCTAssertEqual(literal.blocks[0].text, typed, "\(typed): the literal characters")
            XCTAssertEqual(literal.blocks[0].kind, .paragraph, typed)
            let bytes = literal.markdown()
            let reloaded = NoteDocument(markdown: bytes)
            XCTAssertEqual(reloaded, literal, "\(typed): reload gives the literal text back (bytes \(bytes.debugDescription))")
            XCTAssertEqual(reloaded.blocks[0].text, typed, typed)
            XCTAssertNotEqual(bytes, typed, "\(typed): written escaped, or it would read as markup")
        }
        // Exact bytes of a few.
        var a = Typist(); a.type("- ")
        XCTAssertEqual(a.before?.markdown(), "\\- \n")
        var b = Typist(); b.type("**x**")
        XCTAssertEqual(b.before?.markdown(), "\\*\\*x\\*\\*\n")
        var c = Typist(); c.type("---")
        XCTAssertEqual(c.before?.markdown(), "\\---\n")
    }

    func testLiteralTextStaysLiteralWhenTypingOn() {
        for typed in ["- ", "# ", "> ", "1. ", "**x**", "`x`"] {
            var t = Typist()
            t.type(typed)
            var literal = Typist()
            literal.doc = t.before!
            literal.type("y")
            XCTAssertTrue(literal.conversions.isEmpty, "\(typed): typing on does not fire again")
            XCTAssertEqual(literal.doc.blocks[0].text, typed + "y")
            XCTAssertEqual(NoteDocument(markdown: literal.markdown), literal.doc, typed)
        }
    }

    // MARK: 3. never inside code or tables

    func testNoTriggerInACodeBlock() {
        for typed in ["# ", "- ", "1. ", "> ", "---", "```", "**x**", "*x*", "_x_", "~~x~~", "`x`", "<u>x</u>", "- [ ] ", "see https://x.co/a "] {
            var t = Typist("```\n```\n", block: 0)
            t.type(typed)
            XCTAssertTrue(t.conversions.isEmpty, "\(typed) in a code block")
            XCTAssertEqual(t.doc.blocks.map(\.kind), [.fence], typed)
            XCTAssertEqual(t.doc.blocks[0].text, typed)
        }
    }

    func testNoTriggerInInlineCode() {
        // Typed inside a code run (the typed characters carry its mark).
        for typed in ["**x**", "*x*", "~~x~~", "<u>x</u>", "https://x.co/a "] {
            var t = Typist("`code`")
            t.plain = false
            t.type(typed)
            XCTAssertTrue(t.conversions.isEmpty, "\(typed) in inline code")
            XCTAssertTrue(t.doc.blocks[0].runs.allSatisfy { $0.code && $0.pill == nil }, typed)
        }
        // A closing backtick typed inside a code run does not make code of the text before it.
        XCTAssertNil(TypedMarkdown.convert(kind: .paragraph, runs: [Run("a `b", code: true), Run("c`", code: true)], caret: 6, typed: "`"))
        // A line that starts with code is no block trigger.
        XCTAssertNil(TypedMarkdown.convert(kind: .paragraph, runs: [Run("- ", code: true)], caret: 2, typed: " "))
        // Delimiters on both sides of an existing code run do not wrap it.
        XCTAssertNil(TypedMarkdown.convert(kind: .paragraph, runs: [Run("**"), Run("c", code: true), Run("**")], caret: 4, typed: "*"))
    }

    func testNoTriggerInATableCell() {
        let table = "| a | b |\n| --- | --- |\n| c | d |\n"
        for typed in ["# ", "- ", "> ", "---", "```", "**x**", "*x*", "`x`", "~~x~~", "see https://x.co/a "] {
            var doc = NoteDocument(markdown: table)
            XCTAssertEqual(doc.blocks.map(\.kind), [.table])
            let len = doc.blocks[0].text.utf16.count
            var offset = len
            for ch in typed {
                doc.apply(.insertText(block: 0, offset: offset, text: String(ch)))
                offset += 1
                XCTAssertNil(doc.applyTyped(block: 0, caret: offset, typed: ch), "\(typed) in a table cell")
            }
            XCTAssertEqual(doc.blocks.map(\.kind), [.table], typed)
        }
    }

    // MARK: 4. near misses

    func testNearMissesStayLiteral() {
        let literal = ["snake_case_name ", "2 * 3 * 4 ", "a ** b ** c ", "**x ** ", "** x**", "*x *", "__init__ x", "~~ ~~", "``", "<u></u>", "****", "~~~x~~",
                       "**x*", "x_y_z", "#hashtag", "-x", ">x", "1.x", "1) x", "a - b", "text # ", "text - ", "\\- "]
        for typed in literal {
            var t = Typist()
            t.type(typed)
            XCTAssertEqual(t.doc.blocks.count, 1, typed.debugDescription)
            XCTAssertEqual(t.doc.blocks[0].kind, .paragraph, typed.debugDescription)
            XCTAssertEqual(t.doc.blocks[0].text, typed, "\(typed.debugDescription): visible text unchanged")
            XCTAssertTrue(t.conversions.isEmpty, "\(typed.debugDescription) fired")
        }
    }

    // MARK: 5. generated typing keeps the document stable

    func testTypedSequencesKeepSaveLoadStable_generated() {
        let alphabet = ["*", "*", "_", "_", "~", "`", "#", "-", " ", " ", "[", "]", "x", "a", "<", "u", ">", "/", "1", ".", "h", "t", "p", "s", ":", "\n"]
        let start = Date()
        for i in 0..<FuzzConfig.seedCount {
            let seed = FuzzConfig.firstSeed &+ UInt64(i)
            var rng = SeededRNG(seed: seed)
            var t = Typist("seed\n\n")
            t.block = 1
            var typed = ""
            for _ in 0..<(8 + Int(rng.next() % 30)) {
                let ch = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                if ch == "\n" {
                    let len = t.doc.blocks[t.block].text.utf16.count
                    t.doc.apply(.split(block: t.block, offset: len)); t.block += 1
                    typed += ch
                    continue
                }
                typed += ch
                t.type(ch)
                XCTAssertEqual(NoteDocument(markdown: t.markdown), t.doc, "seed \(seed) after typing \(typed.debugDescription): \(t.markdown.debugDescription)")
            }
        }
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(start), Double(FuzzConfig.budgetSeconds) * 3, "Property budget overrun")
    }
}
