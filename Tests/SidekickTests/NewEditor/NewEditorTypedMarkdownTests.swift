import XCTest
import AppKit
import NoteDocument
@testable import Sidekick

/// New editor, ticket 10: typed markdown converts, through real key events in a real window. The rule table itself is
/// tested without a window in `NoteDocumentTypedMarkdownTests`.
///
/// Criterion -> test map
/// 1. each trigger converts
///      -> testEveryBlockTriggerConverts, testChecklistTriggers, testDividerTriggerKeepsALineBelow, testFenceTriggerMakesACodeBlock,
///         testEveryInlineTriggerConverts, testTypedBareURLBecomesAPillWhenCompleted, testBareURLCompletedByEnter, testPastedBareURLBecomesAPill
/// 2. Cmd+Z right after restores the typed characters; they save escaped and reload literal
///      -> testUndoRightAfterAConversionGivesBackTheTypedCharacters (exact bytes and a reopen), testLiteralCharactersStayLiteralWhenTypingOn
/// 3. no trigger inside a code block, inline code or a table cell
///      -> testNothingConvertsInACodeBlock, testNothingConvertsInInlineCode, testNothingConvertsInATableCell
/// 4. interplay: /hr, pill and link edges, `---`, `1. `, armed style
///      -> testSlashHrStillWorks, testTriggersAfterAPillOrLinkStayPlain, testNumberedTriggerKeepsTheTypedNumberAndContinues,
///         testArmedStyleSurvivesABlockConversionAndMeetsAnInlineOne
/// 5. typing properties hold while conversions occur
///      -> testConversionsKeepCaretTextAndUndoRight_generated
@MainActor
final class NewEditorTypedMarkdownTests: XCTestCase {
    private var seeds: Int { Int(ProcessInfo.processInfo.environment["SIDEKICK_FUZZ_SEEDS"] ?? "") ?? 40 }

    private func runs(_ h: NewEditorHost, _ block: Int = 0) -> [Run] {
        let blocks = h.textView.document.blocks
        return blocks.indices.contains(block) ? blocks[block].runs : []
    }
    /// A run by index (a missing one reads as an unmistakable placeholder, so that a failure reports instead of crashing).
    private func run(_ h: NewEditorHost, _ i: Int) -> Run { let r = runs(h); return r.indices.contains(i) ? r[i] : Run("<missing run \(i)>") }

    /// One key press at a time with the undo group closed in between, as between real key events (`type` sends a whole
    /// string in one pass of the run loop, which is one undo group).
    private func typeKeyByKey(_ h: NewEditorHost, _ text: String) {
        for ch in text { h.type(String(ch)); h.endUndoGroup() }
    }

    // MARK: 1. each trigger converts

    func testEveryBlockTriggerConverts() {
        let cases: [(String, String, String)] = [
            ("# ", "h1", "# x\n"), ("## ", "h2", "## x\n"), ("### ", "h3", "### x\n"), ("#### ", "h4", "#### x\n"), ("##### ", "h5", "##### x\n"),
            ("###### ", "h6", "###### x\n"), ("- ", "bullet", "- x\n"), ("* ", "bullet", "- x\n"), ("1. ", "numbered", "1. x\n"), ("> ", "quote", "> x\n"),
        ]
        for (typed, kind, md) in cases {
            for source in ["", "a\n", "a\n\nb\n"] {
                let h = NewEditorHost(markdown: source)
                let line = source.isEmpty ? 0 : source.hasPrefix("a\n\n") ? 2 : 2
                if source.isEmpty { h.select(0) } else { h.select(line) }   // an empty line (the one below `a`, or the empty tail)
                if source == "a\n" { h.select(h.length) }
                let blocksBefore = h.textView.blockKinds.count
                h.type(typed)
                XCTAssertFalse(h.string.contains(typed.trimmingCharacters(in: .whitespaces)), "\(typed.debugDescription) in \(source.debugDescription): the characters were taken away")
                h.type("x")
                let kinds = h.textView.blockKinds
                XCTAssertEqual(kinds.count >= (source == "a\n\nb\n" ? 2 : 1) ? kinds[kinds.count - (source == "a\n\nb\n" ? 2 : 1)] : "<none>", kind, "\(typed.debugDescription) in \(source.debugDescription)")
                XCTAssertGreaterThanOrEqual(kinds.count, blocksBefore)
                XCTAssertTrue((h.savedMarkdown ?? "").contains(md.dropLast()), "\(typed.debugDescription) in \(source.debugDescription): \(h.savedMarkdown ?? "nil")")
            }
        }
        // The plain example, exact bytes.
        let h = NewEditorHost(markdown: "")
        h.type("# x")
        XCTAssertEqual(h.textView.blockKinds, ["h1"])
        XCTAssertEqual(h.string, "x")
        XCTAssertEqual(h.markdown, "# x\n")
        XCTAssertEqual(h.location, 1)
    }

    func testChecklistTriggers() {
        for (typed, kind, md) in [("- [ ] ", "todo", "- [ ] x\n"), ("- [x] ", "checked", "- [x] x\n"), ("- [X] ", "checked", "- [x] x\n")] {
            let h = NewEditorHost(markdown: "")
            h.type(typed + "x")
            XCTAssertEqual(h.textView.blockKinds, [kind], typed)
            XCTAssertEqual(h.string, "x", typed)
            XCTAssertEqual(h.markdown, md, typed)
        }
    }

    func testDividerTriggerKeepsALineBelow() {
        let h = NewEditorHost(markdown: "a\n")
        h.select(h.length)
        h.type("---")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider"])
        XCTAssertEqual(h.string, "a\n\n", "a plain line below the rule")
        XCTAssertEqual(h.location, 3, "the caret sits on that line")
        h.type("z")
        XCTAssertEqual(h.markdown, "a\n---\nz\n")
        // In the middle of a note, and the line above is untouched.
        let m = NewEditorHost(markdown: "a\n\nb\n")
        m.select(2)
        m.type("---")
        XCTAssertEqual(m.textView.blockKinds, ["p", "divider", "p", "p"])
        XCTAssertEqual(m.markdown, "a\n---\n\nb\n")
        // `---` after text on the same line is no trigger.
        let t = NewEditorHost(markdown: "a")
        t.select(1)
        t.type("---")
        XCTAssertEqual(t.textView.blockKinds, ["p"])
    }

    func testFenceTriggerMakesACodeBlock() {
        let h = NewEditorHost(markdown: "a\n")
        h.select(h.length)
        h.type("```")
        XCTAssertEqual(h.textView.blockKinds, ["p", "code"])
        XCTAssertEqual(h.string, "a\n\n", "an empty code line, and a plain line stays below to leave by")
        XCTAssertEqual(h.location, 2, "the caret is in the code block")
        h.type("let x = 1")
        XCTAssertEqual(h.textView.blockKinds, ["p", "code"])
        XCTAssertEqual(h.markdown, "a\n```\nlet x = 1\n```\n")
        // Code inside is not read for markup, and the line below is reachable.
        h.type("# **no**")
        XCTAssertEqual(h.textView.blockKinds, ["p", "code"])
        h.press(.right)
        h.type("after")
        XCTAssertEqual(h.textView.blockKinds, ["p", "code", "p"])
    }

    func testEveryInlineTriggerConverts() {
        let cases: [(String, (Run) -> Bool)] = [
            ("**x**", { $0.bold == .asterisks }), ("*x*", { $0.italic == .asterisk }), ("_x_", { $0.italic == .underscore }),
            ("~~x~~", { $0.strikethrough }), ("`x`", { $0.code }), ("<u>x</u>", { $0.underline }),
        ]
        for (typed, has) in cases {
            let h = NewEditorHost(markdown: "")
            h.type("a " + typed)
            XCTAssertEqual(h.string, "a x", typed)
            XCTAssertEqual(h.location, 3, typed)
            let r = runs(h)
            XCTAssertEqual(r.map(\.text), ["a ", "x"], typed)
            XCTAssertTrue(r.count > 1 && has(r[1]), typed)
            XCTAssertTrue(r.first?.hasMarksNone ?? false, typed)
            // The next typed text is plain.
            h.type("y")
            XCTAssertEqual(runs(h).map(\.text), ["a ", "x", "y"], typed)
            XCTAssertTrue(run(h, 2).hasMarksNone, "\(typed): typing on is plain text")
        }
    }

    func testInlineTriggerInAHeadingAndAListItem() {
        let h = NewEditorHost(markdown: "")
        h.type("## a **b**")
        XCTAssertEqual(h.textView.blockKinds, ["h2"])
        XCTAssertEqual(runs(h).map(\.text), ["a ", "b"])
        XCTAssertEqual(run(h, 1).bold, .asterisks)
        let l = NewEditorHost(markdown: "")
        l.type("- see `code`")
        XCTAssertEqual(l.textView.blockKinds, ["bullet"])
        XCTAssertTrue(runs(l).last?.code ?? false)
        XCTAssertEqual(l.markdown, "- see `code`\n")
    }

    func testTypedBareURLBecomesAPillWhenCompleted() {
        let h = NewEditorHost(markdown: "")
        h.type("go https://example.com/a?b=1")
        XCTAssertFalse(h.string.contains("\u{FFFC}"), "not completed yet: still text")
        h.type(" ")
        XCTAssertEqual(h.string, "go \u{FFFC} ")
        XCTAssertEqual(h.location, 5)
        XCTAssertEqual(runs(h).filter { $0.pill != nil }.map(\.text), ["https://example.com/a?b=1"])
        XCTAssertEqual(h.markdown, "go https://example.com/a?b=1 \n")
        h.type("next")
        XCTAssertEqual(h.string, "go \u{FFFC} next")
        // Trailing punctuation is not part of the address.
        let p = NewEditorHost(markdown: "")
        p.type("see https://x.co/y. ")
        XCTAssertEqual(p.string, "see \u{FFFC}. ")
    }

    func testUndoRightAfterABareURLConversionRestoresTheLiteralURL() {
        let h = NewEditorHost(markdown: "")
        h.type("go https://example.com/a?b=1")
        h.type(" ")
        XCTAssertEqual(h.string, "go \u{FFFC} ")
        h.undo()
        XCTAssertEqual(h.string, "go https://example.com/a?b=1 ")
        XCTAssertTrue(runs(h).allSatisfy { $0.pill == nil }, "the literal characters, no pill")
        XCTAssertEqual(h.markdown, "go https\\://example.com/a?b=1 \n", "saved with the escaped colon")
        let reloaded = NewEditorHost(markdown: h.markdown)
        XCTAssertEqual(reloaded.string, "go https://example.com/a?b=1 \n", "the file ends with a line break: an empty last line shows")
        XCTAssertTrue(runs(reloaded).allSatisfy { $0.pill == nil }, "reads back as plain text")
    }

    func testBareURLCompletedByEnter() {
        let h = NewEditorHost(markdown: "")
        h.type("https://example.com/a")
        h.press(.enter)
        XCTAssertEqual(h.string, "\u{FFFC}\n")
        XCTAssertEqual(h.textView.blockKinds, ["p"], "a new empty last line is no block yet")
        // Enter undoes first (its own step), then the pill goes back to the typed characters.
        h.undo()
        XCTAssertEqual(h.string, "\u{FFFC}")
        h.undo()
        XCTAssertEqual(h.string, "https://example.com/a")
    }

    func testPastedBareURLBecomesAPill() {
        let h = NewEditorHost(markdown: "a ")
        h.select(2)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("see https://x.co/1 and https://x.co/2\nnext https://x.co/3", forType: .string)
        h.textView.paste(nil)
        XCTAssertEqual(h.string, "a see \u{FFFC} and \u{FFFC}\nnext \u{FFFC}")
        XCTAssertEqual(h.location, (h.string as NSString).length, "the caret stays after the pasted text")
        XCTAssertEqual(h.textView.document.blocks.flatMap(\.runs).filter { $0.pill != nil }.map(\.text), ["https://x.co/1", "https://x.co/2", "https://x.co/3"])
        h.undo()
        XCTAssertEqual(h.markdown, "a ", "ticket 13: the pills belong to the paste, which is one undo step")
        // Pasted into a code block it stays text.
        let c = NewEditorHost(markdown: "```\n\n```\n")
        c.select(0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://x.co/1", forType: .string)
        c.textView.paste(nil)
        XCTAssertEqual(c.string, "https://x.co/1\n")
    }

    // MARK: 2. Cmd+Z gives the typed characters back

    func testUndoRightAfterAConversionGivesBackTheTypedCharacters() {
        // typed, the literal bytes the file holds after Cmd+Z
        let cases: [(String, String)] = [
            ("# ", "\\# \n"), ("###### ", "\\###### \n"), ("- ", "\\- \n"), ("* ", "\\* \n"), ("1. ", "\\1. \n"), ("> ", "\\> \n"),
            ("---", "\\---\n"), ("```", "\\`\\`\\`\n"), ("**x**", "\\*\\*x\\*\\*\n"), ("*x*", "\\*x\\*\n"), ("_x_", "\\_x\\_\n"),
            ("~~x~~", "\\~\\~x\\~\\~\n"), ("`x`", "\\`x\\`\n"), ("<u>x</u>", "\\<u>x\\</u>\n"),
        ]
        for (typed, bytes) in cases {
            let h = NewEditorHost(markdown: "")
            typeKeyByKey(h, typed)
            XCTAssertNotEqual(h.string, typed, "\(typed.debugDescription) converted")
            h.undo()
            XCTAssertEqual(h.string, typed, "\(typed.debugDescription): Cmd+Z gives back the characters as typed")
            XCTAssertEqual(h.textView.blockKinds, ["p"], typed)
            XCTAssertEqual(h.location, (typed as NSString).length, "\(typed.debugDescription): the caret is after them")
            XCTAssertEqual(h.savedMarkdown, bytes, "\(typed.debugDescription): the bytes of the literal text")
            // The file reopened shows the same literal text.
            let reopened = NewEditorHost(markdown: h.savedMarkdown ?? "")
            XCTAssertEqual(reopened.string, typed + "\n", "\(typed.debugDescription) reopened (the file ends in a line break, so an empty line follows)")
            XCTAssertEqual(reopened.textView.blockKinds, ["p"], "\(typed.debugDescription) reopened")
            XCTAssertEqual(reopened.markdown, bytes, "\(typed.debugDescription) reopened and saved again")
            // A second Cmd+Z takes back the typing (AppKit coalesces it into one step), never the conversion again.
            h.undo()
            XCTAssertEqual(h.string, "", "\(typed.debugDescription): the next step is the typing itself")
            XCTAssertEqual(h.textView.blockKinds, [], typed)
        }
    }

    func testLiteralCharactersStayLiteralWhenTypingOn() {
        for typed in ["# ", "- ", "> ", "1. ", "**x**", "`x`", "---"] {
            let h = NewEditorHost(markdown: "")
            typeKeyByKey(h, typed)
            h.undo()
            h.type("y")
            XCTAssertEqual(h.string, typed + "y", typed)
            XCTAssertEqual(h.textView.blockKinds, ["p"], "\(typed.debugDescription): typing on does not convert again")
            let reopened = NewEditorHost(markdown: h.savedMarkdown ?? "")
            XCTAssertEqual(reopened.string, typed + "y\n", "\(typed.debugDescription) reopened")
            XCTAssertEqual(reopened.textView.blockKinds, ["p"], typed)
        }
    }

    func testRedoConvertsAgain() {
        let h = NewEditorHost(markdown: "")
        h.type("**x**")
        h.undo()
        h.endUndoGroup()
        h.textView.undoManager?.redo()
        h.endUndoGroup()
        XCTAssertEqual(h.string, "x")
        XCTAssertEqual(runs(h).map(\.bold), [.asterisks])
        XCTAssertEqual(h.markdown, "**x**\n")
    }

    // MARK: 3. never inside code or tables

    func testNothingConvertsInACodeBlock() {
        for typed in ["# ", "- ", "1. ", "> ", "---", "**x**", "*x*", "`x`", "~~x~~", "- [ ] ", "<u>x</u>", "see https://x.co/a "] {
            let h = NewEditorHost(markdown: "```\na\n```\n")
            h.select(1)
            h.type(typed)
            XCTAssertEqual(h.textView.blockKinds, ["code"], typed)
            XCTAssertEqual(h.string, "a" + typed + "\n", "\(typed): typed as it is")
            XCTAssertFalse(h.string.contains("\u{FFFC}"), typed)
        }
        // At the start of a code line too (a line start is where block triggers fire).
        let h = NewEditorHost(markdown: "```\nb\n```\n")
        h.select(0)
        h.type("# ")
        XCTAssertEqual(h.textView.blockKinds, ["code"])
        XCTAssertEqual(h.string, "# b\n")
    }

    func testNothingConvertsInInlineCode() {
        for typed in ["**x**", "*x*", "~~x~~", "<u>x</u>", "https://x.co/a "] {
            let h = NewEditorHost(markdown: "`code`\n")
            h.select(2)   // inside the code
            h.type(typed)
            XCTAssertTrue(runs(h).allSatisfy { $0.code && $0.pill == nil }, "\(typed) inside inline code: \(runs(h))")
            XCTAssertEqual(h.string, "co" + typed + "de\n", typed)
        }
        // Typing at the end of a code run continues the code: the closing backtick of a second span is not a trigger either.
        let h = NewEditorHost(markdown: "`a`\n")
        h.select(1)
        h.type("`b`")
        XCTAssertEqual(h.string, "a`b`\n", "no second code span was made of the typed backticks")
        XCTAssertEqual(runs(h).filter { $0.code }.map(\.text).joined(), "ab", "the document keeps a backtick out of a code run: \(runs(h))")
    }

    func testNothingConvertsInATableCell() {
        let table = "| a | b |\n| --- | --- |\n| c | d |\n"
        for typed in ["# ", "- ", "> ", "---", "```", "**x**", "*x*", "`x`", "~~x~~", "see https://x.co/a "] {
            let h = NewEditorHost(markdown: table)
            let starts = h.tableCellStarts()
            h.select(starts[0])
            h.type(typed)
            XCTAssertEqual(h.textView.blockKinds, ["table"], typed)
            XCTAssertFalse(h.string.contains("\u{FFFC}"), typed)
            XCTAssertTrue(h.string.hasPrefix(typed), "\(typed.debugDescription) stays text in the cell: \(h.string.debugDescription)")
            h.select(starts[3])
            h.type(typed)
            XCTAssertEqual(h.textView.blockKinds, ["table"], typed)
        }
    }

    // MARK: 4. interplay

    func testSlashHrStillWorks() {
        let h = NewEditorHost(markdown: "a\n")
        h.select(h.length)
        h.type("/hr")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider"])
        h.type("--")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider", "p"], "`--` below the rule is not a trigger")
        h.type("-")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider", "divider"], "`---` below the rule is one")
    }

    func testTriggersAfterAPillOrLinkStayPlain() {
        // After a link the typed text is plain (08), so the typed delimiters wrap plain text, not link text.
        let h = NewEditorHost(markdown: "[a](https://y.co/z)\n")
        h.select(1)
        h.type(" **b**")
        XCTAssertEqual(runs(h).map(\.text), ["a", " ", "b"])
        XCTAssertEqual(run(h, 0).link, "https://y.co/z")
        XCTAssertNil(run(h, 1).link)
        XCTAssertNil(run(h, 2).link)
        XCTAssertEqual(run(h, 2).bold, .asterisks)
        // Two URLs in a row each become a pill; the pill edge rule keeps typed text out of the address.
        let p = NewEditorHost(markdown: "")
        p.type("https://a.co/1 https://b.co/2 ")
        XCTAssertEqual(p.string, "\u{FFFC} \u{FFFC} ")
        XCTAssertEqual(runs(p).filter { $0.pill != nil }.map(\.text), ["https://a.co/1", "https://b.co/2"])
        // A pill before the caret is not text a block trigger reads: `- ` after a pill stays text.
        let q = NewEditorHost(markdown: "https://a.co/1\n")
        q.select(1)
        q.type("- ")
        XCTAssertEqual(q.textView.blockKinds, ["p"])
    }

    func testNumberedTriggerKeepsTheTypedNumberAndContinues() {
        let h = NewEditorHost(markdown: "3. a\n")
        h.select(h.length)
        h.type("1. y")
        XCTAssertEqual(h.textView.blockKinds, ["numbered", "numbered"])
        XCTAssertEqual(h.markdown, "3. a\n1. y\n", "the number typed is the number saved")
        h.press(.enter)
        h.type("z")
        XCTAssertEqual(h.markdown, "3. a\n1. y\n2. z\n", "Enter continues from the typed number")
        let s = NewEditorHost(markdown: "")
        s.type("7. a")
        XCTAssertEqual(s.markdown, "7. a\n")
        let drawn = NoteTextEngine.markers(in: s.textView).compactMap { m -> String? in if case .number(let t) = m.shape { return t } else { return nil } }
        XCTAssertEqual(drawn, ["7."], "the drawn number is the one typed")
    }

    func testArmedStyleSurvivesABlockConversionAndMeetsAnInlineOne() {
        let h = NewEditorHost(markdown: "")
        h.textView.perform(.bold)
        h.type("- x")
        XCTAssertEqual(h.textView.blockKinds, ["bullet"])
        XCTAssertEqual(runs(h).map(\.bold), [.asterisks], "the armed bold applies to the text typed after the conversion")
        // Armed bold, then an italic trigger: x is bold and italic, and the next text is bold again.
        let g = NewEditorHost(markdown: "")
        g.textView.perform(.bold)
        g.type("_x_y")
        XCTAssertEqual(runs(g).map(\.text), ["x", "y"])
        XCTAssertEqual(run(g, 0).bold, .asterisks)
        XCTAssertNotNil(run(g, 0).italic, "bold and italic (the document may respell the delimiter)")
        XCTAssertEqual(run(g, 1).bold, .asterisks)
        XCTAssertNil(run(g, 1).italic)
    }

    // MARK: 5. typing properties while conversions occur

    private static let triggers = ["# ", "## ", "- ", "* ", "1. ", "> ", "- [ ] ", "- [x] ", "---", "```", "**b**", "*i*", "_u_", "~~s~~", "`c`", "<u>u</u>", "http://e.co/a ", "/hr"]

    /// Trigger sequences typed at line starts and line ends of generated notes: the caret is where AppKit reports it, the
    /// file reads back as what the view shows, a typed character lands at the caret, and Cmd+Z takes the round back to the
    /// bytes it started with. (The document keeps the last 16 states for byte-exact undo, so a round stays below that.)
    func testConversionsKeepCaretTextAndUndoRight_generated() {
        let seedCount = min(seeds, 40)
        // SIDEKICK_TYPED_SEED=<n> replays one seed.
        let only = ProcessInfo.processInfo.environment["SIDEKICK_TYPED_SEED"].flatMap { UInt64($0) }
        for seed in (only.map { [$0] } ?? Array(1...UInt64(seedCount))) {
            var gen = NewEditorNoteGenerator(seed: seed &+ 5000)
            let source = gen.markdown()
            var pick = SplitMix(seed: seed)
            for round in 0..<3 {
                // A fresh host per round: its undo steps are its own.
                let h = NewEditorHost(markdown: source)
                let ranges = NoteBuffer.paragraphRanges(in: h.string as NSString)
                let para = ranges[pick.next(ranges.count)]
                let atEnd = pick.next(2) == 0
                h.select(atEnd ? NSMaxRange(para) : para.location)
                let typed = Self.triggers[pick.next(Self.triggers.count)]
                if only != nil { print("ROUND", round, "start", h.markdown.debugDescription, h.textView.blockKinds) }
                let startMarkdown = h.markdown, startString = h.string, startKinds = h.textView.blockKinds, startLocation = h.location
                h.type(typed)
                if only != nil { print("ROUND", round, typed.debugDescription, "at", h.location, "->", h.markdown.debugDescription, h.textView.blockKinds) }
                let tag = "seed \(seed) round \(round) typing \(typed.debugDescription) at \(atEnd ? "end" : "start") of \(startString.debugDescription)"
                XCTAssertEqual(h.caret.origin.x, h.appKitCaretOrigin.x, accuracy: 1.5, "\(tag): caret x")
                XCTAssertEqual(h.caret.origin.y, h.appKitCaretOrigin.y, accuracy: 1.5, "\(tag): caret y")
                let reopened = NewEditorHost(markdown: h.markdown)
                // (A file whose last line ends in a line break shows an empty line below it, and a table cell loses trailing
                // blanks in the file; neither belongs to this ticket.)
                func trimmed(_ s: String) -> String {
                    var lines = s.components(separatedBy: "\n").map { l -> String in var t = l; while t.hasSuffix(" ") { t.removeLast() }; return t }
                    while lines.last == "" { lines.removeLast() }
                    return lines.joined(separator: "\n")
                }
                XCTAssertEqual(trimmed(reopened.string), trimmed(h.string), "\(tag): the file reads back as what the view shows; saved \(h.markdown.debugDescription)")
                XCTAssertEqual(reopened.textView.blockKinds, h.textView.blockKinds, "\(tag): kinds read back")
                // Cmd+Z takes the round back to the bytes it started with.
                var guardCount = 0
                while h.string != startString || h.textView.blockKinds != startKinds, h.textView.undoManager?.canUndo == true, guardCount < 4 { h.undo(); guardCount += 1 }
                XCTAssertEqual(h.markdown, startMarkdown, "\(tag): Cmd+Z takes the round back to its bytes")
                XCTAssertEqual(h.string, startString, "\(tag): and its text")
                XCTAssertEqual(h.textView.blockKinds, startKinds, "\(tag): and its kinds")
                // Typed again (after a pause that closes the undo step), a typed character appears at the caret and Backspace
                // takes exactly it away.
                h.endUndoGroup()
                h.select(startLocation)
                h.type(typed)
                let before = h.string, at = h.location
                h.type("Z")
                XCTAssertEqual(h.location, at + 1, "\(tag): typed character at the caret")
                h.press(.backspace)
                XCTAssertEqual(h.string, before, "\(tag): Backspace removes the typed character")
            }
        }
    }
}

private extension Run {
    var hasMarksNone: Bool { bold == nil && italic == nil && !underline && !strikethrough && !code && link == nil && pill == nil }
}

/// Small deterministic generator for the choices of the property test.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next(_ n: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(n))
    }
}
