import XCTest
import AppKit
import NoteDocument
@testable import Sidekick

/// Ticket 13: copy, cut, paste and drag and drop in the new editor. Real pasteboard objects (a private named one per
/// test, never the general pasteboard), real key events and menu actions through `NewEditorHost`.
///
/// Criterion -> test map
/// 1. copy across several block kinds gives markdown that, pasted into an empty note, reproduces the content
///      -> testCopyAcrossEveryBlockKindPastesBackAsTheSameNote, testCopyArrivesAsPlainTextOnly, testCopyAndPasteByKeyboardShortcut,
///         testCopyOfSeveralBlocksStartingAndEndingInsideThem
/// 2. paste of markdown gives formatted content; paste inside a code block is literal
///      -> testPastedMarkdownBecomesFormattedContent, testPasteInsideTheLineMergesWithIt, testPasteInsideACodeBlockIsLiteral,
///         testPasteInsideATableCellFollowsTheCellRules, testRichTextIsReducedToPlainText, testPastedBareURLBecomesAPill (10)
/// 3. a partial-block selection copies only the selected text with its marks
///      -> testPartialBlockCopiesOnlyTheSelectedTextWithItsMarks
/// 4. paste is one undo step (and cut is copy plus one step)
///      -> testPasteIsOneUndoStepAndUndoRestoresTheSource, testCutIsCopyPlusOneUndoStep, testUndoRestoresTheSource_generated
/// 5. property: copy all, paste into an empty note, save: equal as documents
///      -> testCopyAllPasteIntoEmptyNoteIsTheSameDocument_generated
/// 6. drag and drop inside the editor moves content with its formatting, one undo step
///      -> testDragMovesContentWithItsFormattingAsOneUndoStep (through the drag delegate path: a real drag session cannot be driven)
@MainActor
final class NewEditorClipboardTests: XCTestCase {
    private var seeds: Int { Int(ProcessInfo.processInfo.environment["SIDEKICK_FUZZ_SEEDS"] ?? "") ?? 40 }
    private var boards: [NSPasteboard] = []

    override func tearDown() {
        boards.forEach { $0.releaseGlobally() }
        boards = []
        super.tearDown()
    }

    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("sidekick.test.\(UUID().uuidString)"))
        pb.clearContents()
        boards.append(pb)
        return pb
    }

    private func host(_ markdown: String, board pb: NSPasteboard? = nil) -> NewEditorHost {
        let h = NewEditorHost(markdown: markdown)
        h.textView.clipboard = pb ?? board()
        return h
    }

    private func select(_ h: NewEditorHost, _ from: String, to end: String? = nil) {
        let ns = h.string as NSString
        let a = ns.range(of: from)
        XCTAssertNotEqual(a.location, NSNotFound, "\(from) is in the text")
        let b = end.map { ns.range(of: $0, range: NSRange(location: a.location, length: ns.length - a.location)) } ?? a
        h.textView.setSelectedRange(NSRange(location: a.location, length: NSMaxRange(b) - a.location))
    }

    private func copied(_ h: NewEditorHost) -> String? {
        h.textView.copy(nil)
        return h.textView.clipboard.string(forType: .string)
    }

    private func pasteText(_ h: NewEditorHost, _ text: String) {
        h.textView.clipboard.clearContents()
        h.textView.clipboard.setString(text, forType: .string)
        h.textView.paste(nil)
    }

    /// Without one final line break, whichever way it is spelled (`"\r\n"` is one Character in Swift, so work on scalars).
    private static func withoutFinalLineBreak(_ markdown: String) -> String {
        var scalars = markdown.unicodeScalars
        if scalars.last == "\n" { scalars.removeLast(); if scalars.last == "\r" { scalars.removeLast() } }
        return String(scalars)
    }

    /// The note with LF line endings (a new note's last line gets LF; a paste into an empty note takes it).
    private static func crlf(_ markdown: String) -> String { lf(markdown).replacingOccurrences(of: "\n", with: "\r\n") }

    private static func lf(_ markdown: String) -> String { markdown.replacingOccurrences(of: "\r\n", with: "\n") }

    private func document(_ markdown: String) -> NoteDocument { NoteDocument(markdown: markdown) }

    static let everyKind = "# Title **bold**\n- bullet *it*\n3. numbered\n- [x] done ~~gone~~\n> quote `code`\n---\n"
        + "see https://x.co/1 and [label](http://x.y/z)\n```swift\n# not a heading\n**x**\n```\n| a | b |\n|---|---|\n| 1 | **2** |\nlast\n"

    // MARK: 1. copy across kinds

    func testCopyAcrossEveryBlockKindPastesBackAsTheSameNote() {
        let h = host(Self.everyKind)
        h.textView.selectAll(nil)
        let md = copied(h)
        XCTAssertEqual(md, Self.everyKind, "the whole note, as the file spells it")
        let target = host("")
        pasteText(target, md ?? "")
        XCTAssertEqual(document(target.markdown), document(Self.everyKind))
        XCTAssertEqual(target.textView.blockKinds, h.textView.blockKinds)
        XCTAssertEqual(target.string, h.string)
    }

    func testCopyArrivesAsPlainTextOnly() {
        let pb = board()
        let h = host("**bold** and *it*\n", board: pb)
        h.textView.selectAll(nil)
        h.textView.copy(nil)
        let aliasesOfPlainText: Set<String> = ["public.utf8-plain-text", "NSStringPboardType"]
        XCTAssertEqual(Set((pb.types ?? []).map(\.rawValue)), aliasesOfPlainText, "other apps receive plain markdown text only")
        XCTAssertEqual(pb.string(forType: .string), "**bold** and *it*\n")
    }

    func testCopyOfSeveralBlocksStartingAndEndingInsideThem() {
        let h = host("# Big title\n- one **bold** two\n> quote here\n")
        select(h, "title", to: "quo")
        XCTAssertEqual(copied(h), "title\n- one **bold** two\n> quo", "a start inside a block gives its text; later blocks keep their kind")
        let target = host("")
        pasteText(target, copied(h) ?? "")
        XCTAssertEqual(target.textView.blockKinds, ["p", "bullet", "quote"])
        XCTAssertEqual(target.string, "title\none bold two\nquo")
    }

    func testCopyAndPasteByKeyboardShortcut() {
        let h = host("# Head\n- item\n")
        let menu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = h.textView
            menu.addItem(item)
        }
        h.textView.selectAll(nil)
        XCTAssertTrue(h.shortcut("c", keyCode: 8, [], in: menu), "Cmd+C reaches the editor")
        XCTAssertEqual(h.textView.clipboard.string(forType: .string), "# Head\n- item\n")
        h.select(h.length)
        XCTAssertTrue(h.shortcut("v", keyCode: 9, [], in: menu), "Cmd+V reaches the editor")
        XCTAssertEqual(h.markdown, "# Head\n- item\n# Head\n- item\n")
        h.textView.selectAll(nil)
        XCTAssertTrue(h.shortcut("x", keyCode: 7, [], in: menu), "Cmd+X reaches the editor")
        XCTAssertEqual(h.markdown, "")
    }

    // MARK: 3. partial blocks

    func testPartialBlockCopiesOnlyTheSelectedTextWithItsMarks() {
        let h = host("plain **bold** and *it* tail\n## Head line\nsee https://x.co/1 now\n")
        select(h, "ld and i")
        XCTAssertEqual(copied(h), "**ld** and *i*")
        select(h, "ead")
        XCTAssertEqual(copied(h), "ead", "the heading mark is not part of a text selection inside it")
        select(h, "see ", to: "now")
        XCTAssertEqual(copied(h), "see https://x.co/1 now", "a pill is copied as its address")
        select(h, "plain")
        XCTAssertEqual(copied(h), "plain", "no marks in the selected text, none in the copy")
        let code = host("```\n# a\n**b**\n```\n")
        select(code, "a\u{2028}**b")
        XCTAssertEqual(copied(code), "a\n**b", "inside a code block the text is as written")
    }

    // MARK: 2. paste

    func testPastedMarkdownBecomesFormattedContent() {
        let h = host("")
        pasteText(h, "# Title\n- one\n- [ ] two **b**\n> q\n---\n`c` and [l](http://a.b)")
        XCTAssertEqual(h.textView.blockKinds, ["h1", "bullet", "todo", "quote", "divider", "p"])
        XCTAssertEqual(h.string, "Title\none\ntwo b\nq\n\n" + "c and l")
        XCTAssertEqual(h.markdown, "# Title\n- one\n- [ ] two **b**\n> q\n---\n`c` and [l](http://a.b)\n", "a new note's last line gets the line ending (LF)")
        XCTAssertEqual(h.location, (h.string as NSString).length, "the caret is after the pasted text")
        let fenced = host("")
        pasteText(fenced, "```swift\n# literal\n```\n")
        XCTAssertEqual(fenced.textView.blockKinds.first, "code")
    }

    func testPasteInsideTheLineMergesWithIt() {
        let h = host("abcd\n")
        h.select(2)
        pasteText(h, "**x** y")
        XCTAssertEqual(h.markdown, "ab**x** ycd\n")
        XCTAssertEqual(h.location, 5)
        let list = host("- item\n")
        list.select(2)
        pasteText(list, "*one*")
        XCTAssertEqual(list.markdown, "- it*one*em\n")
        let split = host("abcd\n")
        split.select(2)
        pasteText(split, "# Head")
        XCTAssertEqual(split.textView.blockKinds, ["p", "h1"], "a block that is not a plain line starts its own line")
        XCTAssertEqual(split.string, "ab\nHeadcd\n")
        let lines = host("abcd\n")
        lines.select(2)
        pasteText(lines, "x\ny\n")
        XCTAssertEqual(lines.markdown, "abx\ny\ncd\n", "a pasted line break at the end keeps the rest on its own line")
        XCTAssertEqual(lines.location, 6)
    }

    func testPasteReplacesTheSelectionAcrossBlocks() {
        let h = host("# One\ntwo\nthree\n")
        select(h, "ne\ntwo\nth")
        pasteText(h, "-")
        XCTAssertEqual(h.markdown, "# O-ree\n")
    }

    func testPasteInsideACodeBlockIsLiteral() {
        let h = host("```\nx\n```\n")
        h.select(1)
        pasteText(h, "# h\n**b** https://x.co/1\r\n- a")
        XCTAssertEqual(h.textView.blockKinds, ["code"], "still one code block")
        XCTAssertEqual(h.markdown, "```\nx# h\n**b** https://x.co/1\n- a\n```\n")
        XCTAssertEqual(h.textView.document.blocks[0].runs.map(\.pill), [nil], "no pill")
        // The selection is replaced by the literal text.
        let r = host("```\nabc\n```\n")
        select(r, "b")
        pasteText(r, "*")
        XCTAssertEqual(r.markdown, "```\na*c\n```\n")
        h.undo()
        XCTAssertEqual(h.markdown, "```\nx\n```\n")
    }

    func testPasteInsideATableCellFollowsTheCellRules() {
        let source = "| a | b |\n|---|---|\n| c | d |\n"
        let h = host(source)
        let starts = h.tableCellStarts()
        h.select(starts[2])   // the first cell of the body row
        pasteText(h, "x\ty\nz **w**")
        XCTAssertEqual(h.textView.blockKinds.first, "table")
        XCTAssertEqual(h.textView.document.blocks[0].runs.map(\.text).joined(), "a\tb\u{2028}x y z **w**c\td", "tabs and line breaks become blanks, markdown stays text")
        XCTAssertFalse(h.textView.document.blocks[0].runs.contains { $0.bold != nil })
        h.undo()
        XCTAssertEqual(h.markdown, source)
    }

    func testRichTextIsReducedToPlainText() {
        let attributed = NSMutableAttributedString(string: "Hello ", attributes: [.font: NSFont.systemFont(ofSize: 20)])
        attributed.append(NSAttributedString(string: "world", attributes: [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .boldFontMask),
                                                                           .underlineStyle: 1, .link: URL(string: "http://a.b")!]))
        let full = NSRange(location: 0, length: attributed.length)
        // RTF only
        let rtf = host("")
        rtf.textView.clipboard.setData(attributed.rtf(from: full, documentAttributes: [:]), forType: .rtf)
        rtf.textView.paste(nil)
        XCTAssertEqual(rtf.markdown, "Hello world\n", "a new note's last line gets the line ending")
        XCTAssertEqual(rtf.textView.document.blocks.first?.runs.count, 1, "no marks")
        // HTML only
        let html = host("")
        let data = try? attributed.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        html.textView.clipboard.setData(data, forType: .html)
        html.textView.paste(nil)
        XCTAssertEqual(html.markdown.trimmingCharacters(in: .whitespacesAndNewlines), "Hello world")
        XCTAssertFalse(html.textView.document.blocks.contains { $0.runs.contains { $0.bold != nil || $0.link != nil || $0.underline } })
        // Plain text next to rich text: the plain text is what counts.
        let both = host("")
        both.textView.clipboard.setData(attributed.rtf(from: full, documentAttributes: [:]), forType: .rtf)
        both.textView.clipboard.setString("**plain** text", forType: .string)
        both.textView.paste(nil)
        XCTAssertEqual(both.markdown, "**plain** text\n")
    }

    func testPastedBareURLsBecomePillsAsPartOfThePasteStep() {
        let h = host("a ")
        h.select(2)
        pasteText(h, "see https://x.co/1 and https://x.co/2\nnext https://x.co/3")
        XCTAssertEqual(h.string, "a see \u{FFFC} and \u{FFFC}\nnext \u{FFFC}")
        XCTAssertEqual(h.textView.document.blocks.flatMap(\.runs).filter { $0.pill != nil }.map(\.text), ["https://x.co/1", "https://x.co/2", "https://x.co/3"])
        h.undo()
        XCTAssertEqual(h.markdown, "a ", "the pills belong to the paste step")
    }

    /// Fixed examples of fuzz failures (seeds 55, 71, 53, 85 of the 100-seed run).
    func testPastedBlocksKeepTheirOwnSpellingWhenEqualBlocksDifferInSpelling() {
        let source = "---\nx\n___\n***\n"   // seeds 55, 71: three dividers that read the same, spelled differently
        let h = host(source)
        h.textView.selectAll(nil)
        h.textView.copy(nil)
        let target = host("")
        pasteText(target, h.textView.clipboard.string(forType: .string) ?? "")
        XCTAssertEqual(target.markdown, source)
    }

    func testPastedTableNextToAnOldTableDoesNotMergeWithIt() {
        // seed 53: the new blocks are inserted one by one; for a moment the pasted table stood next to the old one
        let h = host("one\n|  |\n| --- |\n| alpha |\n")
        h.select(1)
        pasteText(h, "a\n| s | a |\n| --- | --- |\n|  |\n")
        XCTAssertEqual(h.textView.blockKinds, ["p", "table", "p", "table"])
        XCTAssertEqual(h.markdown, "oa\n| s | a |\n| --- | --- |\n|  |\nne\n|  |\n| --- |\n| alpha |\n")
    }

    func testALineBreakAtTheEndOfTextPastedIntoACellLeavesNoBlank() {
        // seed 85
        let h = host("|x|y|\n|-|-|\n|1|2|\n")
        h.select(h.tableCellStarts()[2])
        pasteText(h, "ab\n")
        XCTAssertEqual(h.textView.document.blocks[0].runs.map(\.text).joined(), "x\ty\u{2028}ab1\t2")
    }

    func testPasteDisarmsAnArmedTypingStyle() {
        let h = host("ab\n")
        h.select(2)
        let delegate = AppDelegate()
        _ = NSApplication.shared
        delegate.installMainMenu()
        delegate.formatTargetOverride = { [unowned h] in h.textView }
        let format = NSApp.mainMenu!.items.first { $0.submenu?.title == "Format" }!.submenu!
        XCTAssertTrue(h.shortcut("b", keyCode: 11, [], in: format))   // Cmd+B: the next typed text is bold
        pasteText(h, "x")
        h.type("y")
        XCTAssertEqual(h.markdown, "abxy\n", "the caret moved with the paste, so the armed style is gone")
        h.undo(); h.undo()
        XCTAssertEqual(h.markdown, "ab\n")
    }

    // MARK: CRLF notes (review B1)

    func testPartialCopyInsideACRLFLineAddsNoLineEnding() {
        let h = host("a\r\nb\r\nc")
        select(h, "a")
        XCTAssertEqual(copied(h), "a", "the selection did not take the line break")
        select(h, "b")
        XCTAssertEqual(copied(h), "b")
        select(h, "a\nb")
        XCTAssertEqual(copied(h), "a\r\nb", "the line break inside the selection keeps the file's spelling")
        select(h, "a\nb\n")
        XCTAssertEqual(copied(h), "a\r\nb\r\n", "a selection that took the line break ends in it")
        let lf = host("a\nb\nc")
        select(lf, "a")
        XCTAssertEqual(copied(lf), "a")
    }

    func testCopyAllOfACRLFNoteIsTheFileBytes() {
        for source in ["a\r\nb\r\n", "a\r\nb\r\nc", "# h\r\n- x\r\n```\r\ncode\r\n```\r\nlast\r\n", "---\r\n"] {
            let h = host(source)
            h.textView.selectAll(nil)
            let md = copied(h)
            XCTAssertEqual(md, source, "\(source.debugDescription)")
            let target = host("")
            pasteText(target, md ?? "")
            XCTAssertEqual(document(Self.withoutFinalLineBreak(target.markdown)), document(Self.withoutFinalLineBreak(Self.lf(source))), "\(source.debugDescription) pasted into an empty note")
            XCTAssertEqual(target.string, h.string)
        }
    }

    func testPastedCRLFTextIsReadLikeLFText() {
        // `"\r\n"` and a lone `"\r"` are line breaks of the pasted text; the cell and block rules see only `"\n"`.
        for text in ["a\r\nb\r\n", "a\rb\r", "# h\r\n\r\n- x\r\n"] {
            let crlf = host(""), lf = host("")
            pasteText(crlf, text)
            pasteText(lf, text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
            XCTAssertEqual(crlf.markdown, lf.markdown, text.debugDescription)
            XCTAssertEqual(crlf.string, lf.string, text.debugDescription)
        }
        let cell = host("|x|y|\n|-|-|\n|1|2|\n")
        cell.select(cell.tableCellStarts()[2])
        pasteText(cell, "ab\r\n")
        XCTAssertEqual(cell.textView.document.blocks[0].runs.map(\.text).joined(), "x\ty\u{2028}ab1\t2", "a CRLF at the end of text pasted into a cell leaves no blank")
    }

    func testCRLFCopyPastedIntoACRLFNoteKeepsItsLineEndings() {
        let h = host("a\r\nb\r\n")
        h.textView.selectAll(nil)
        let md = copied(h) ?? ""
        let target = host("x\r\n")
        target.select(0)
        pasteText(target, md)
        XCTAssertEqual(target.markdown, "a\r\nb\r\nx\r\n")
    }

    func testEmptyOrUnreadablePasteboardChangesNothing() {
        let h = host("keep\n")
        h.select(2)
        h.textView.paste(nil)
        XCTAssertEqual(h.markdown, "keep\n")
        h.textView.clipboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("x.unknown"))
        h.textView.paste(nil)
        XCTAssertEqual(h.markdown, "keep\n")
    }

    // MARK: 4. undo

    func testPasteIsOneUndoStepAndUndoRestoresTheSource() {
        let source = "# Head\nabcd\n- [ ] x\n"
        for (offset, text) in [(0, "# T\n- a\n- b\n"), (8, "mid **b** https://x.co/1"), (3, "x\n"), (15, "```\ncode\n```\n---\n")] {
            let h = host(source)
            h.select(offset)
            pasteText(h, text)
            XCTAssertNotEqual(h.markdown, source, "\(text.debugDescription) changed the note")
            h.undo()
            XCTAssertEqual(h.markdown, source, "one Cmd+Z undoes the whole paste of \(text.debugDescription)")
            XCTAssertEqual(h.textView.blockKinds, ["h1", "p", "todo"])
        }
        let sel = host(source)
        select(sel, "bcd\n", to: "x")
        pasteText(sel, "# Z\nq")
        sel.undo()
        XCTAssertEqual(sel.markdown, source, "a paste over a selection is one step too")
    }

    func testCutIsCopyPlusOneUndoStep() {
        let source = "# Head\nabcd **b**\n- item\n"
        let h = host(source)
        select(h, "bcd", to: "item")
        let expected = copied(h)
        XCTAssertEqual(expected, "bcd **b**\n- item")
        h.textView.clipboard.clearContents()
        h.textView.cut(nil)
        XCTAssertEqual(h.textView.clipboard.string(forType: .string), expected)
        XCTAssertEqual(h.string, "Head\na\n")
        h.undo()
        XCTAssertEqual(h.markdown, source, "one Cmd+Z brings the cut text back")
        XCTAssertEqual(h.textView.clipboard.string(forType: .string), expected, "the clipboard keeps it")
        let none = host(source)
        none.select(2)
        none.textView.cut(nil)
        XCTAssertEqual(none.markdown, source, "no selection, nothing cut")
        XCTAssertNil(none.textView.clipboard.string(forType: .string))
    }

    // MARK: 6. drag and drop

    func testDragMovesContentWithItsFormattingAsOneUndoStep() {
        let source = "**one** two\n- item\nend\n"
        let h = host(source)
        select(h, "one")
        let drop = (h.string as NSString).range(of: "end").upperBound
        let drag = FakeDrag(view: h.textView, source: h.textView, mask: .move, at: drop)
        h.textView.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertTrue(h.textView.writeSelection(to: drag.draggingPasteboard, types: h.textView.writablePasteboardTypes))
        XCTAssertEqual(drag.draggingPasteboard.string(forType: .string), "**one**")
        XCTAssertTrue(h.textView.performDragOperation(drag))
        XCTAssertEqual(h.markdown, " two\n- item\nend**one**\n", "moved with its bold mark")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: (h.string as NSString).range(of: "one").location, length: 3), "the dropped text is selected")
        h.undo()
        XCTAssertEqual(h.markdown, source, "one Cmd+Z moves it back")

        // A whole line moves up with its kind.
        let list = host(source)
        select(list, "item\n")
        let up = FakeDrag(view: list.textView, source: list.textView, mask: .move, at: 0)
        XCTAssertTrue(list.textView.writeSelection(to: up.draggingPasteboard, types: list.textView.writablePasteboardTypes))
        XCTAssertTrue(list.textView.performDragOperation(up))
        XCTAssertEqual(list.markdown, "- item\n**one** two\nend\n")
        XCTAssertEqual(list.textView.blockKinds, ["bullet", "p", "p"])
        list.undo()
        XCTAssertEqual(list.markdown, source)
    }

    func testDragCopyKeepsTheSourceAndDropOnItselfDoesNothing() {
        let source = "a **b** c\n"
        let h = host(source)
        select(h, "b")
        let inside = FakeDrag(view: h.textView, source: h.textView, mask: .move, at: 2)
        h.textView.writeSelection(to: inside.draggingPasteboard, types: h.textView.writablePasteboardTypes)
        _ = h.textView.performDragOperation(inside)
        XCTAssertEqual(h.markdown, source, "dropped inside the dragged text: unchanged")
        let copy = FakeDrag(view: h.textView, source: h.textView, mask: .copy, at: (h.string as NSString).range(of: "c").upperBound)
        h.textView.writeSelection(to: copy.draggingPasteboard, types: h.textView.writablePasteboardTypes)
        XCTAssertTrue(h.textView.performDragOperation(copy))
        XCTAssertEqual(h.markdown, "a **b** c**b**\n")
        h.undo()
        XCTAssertEqual(h.markdown, source)
        // Text dragged in from another app is read as markdown.
        let outside = FakeDrag(view: h.textView, source: nil, mask: .copy, at: 0)
        outside.draggingPasteboard.setString("- x", forType: .string)
        XCTAssertTrue(h.textView.performDragOperation(outside))
        XCTAssertEqual(h.textView.blockKinds.first, "bullet")
    }

    // MARK: 5. properties

    func testCopyAllPasteIntoEmptyNoteIsTheSameDocument_generated() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            var source = gen.markdown()
            if seed % 3 == 0 { source = Self.crlf(source) }   // a third of the notes are CRLF files
            let h = host(source)
            if h.length == 0 { continue }   // nothing to select, so nothing to copy
            h.textView.selectAll(nil)
            h.textView.copy(nil)
            let target = host("")
            pasteText(target, h.textView.clipboard.string(forType: .string) ?? "")
            let saved = target.markdown
            // A new note's last line always ends in a line break (LF), so a source without one is compared without it.
            XCTAssertEqual(document(Self.withoutFinalLineBreak(saved)), document(Self.withoutFinalLineBreak(Self.lf(source))),
                           "seed \(seed): \(source.debugDescription) -> \(saved.debugDescription)")
            XCTAssertEqual(target.string, h.string, "seed \(seed)")
            XCTAssertEqual(target.textView.blockKinds, h.textView.blockKinds, "seed \(seed)")
        }
    }

    func testUndoRestoresTheSource_generated() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            var source = gen.markdown()
            if seed % 3 == 0 { source = Self.crlf(source) }
            var other = NewEditorNoteGenerator(seed: seed &+ 7919)
            let pasted = other.markdown()
            let h = host(source)
            let at = Int((seed &* 2654435761) % UInt64((h.string as NSString).length + 1))
            h.select(at)
            let before = h.markdown
            pasteText(h, pasted)
            h.undo()
            XCTAssertEqual(h.markdown, before, "seed \(seed): caret \(at), pasted \(pasted.debugDescription) into \(source.debugDescription)")
        }
    }

    func testPastedContentSavesAndReloadsToTheSameText_generated() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            var source = gen.markdown()
            if seed % 3 == 0 { source = Self.crlf(source) }
            var other = NewEditorNoteGenerator(seed: seed &+ 104729)
            let pasted = other.markdown()
            let h = host(source)
            h.select(Int((seed &* 40503) % UInt64((h.string as NSString).length + 1)))
            pasteText(h, pasted)
            let reopened = NewEditorHost(markdown: h.markdown)
            // A note whose file has no final line break shows no empty line below its last block until it is typed into
            // (seed 4: a code block pasted at the end of such a note), so a trailing empty line is not compared.
            func trimmed(_ s: String) -> String { var t = s; while t.hasSuffix("\n") { t.removeLast() }; return t }
            XCTAssertEqual(trimmed(reopened.string), trimmed(h.string), "seed \(seed): \(pasted.debugDescription) pasted into \(source.debugDescription)")
            XCTAssertEqual(reopened.textView.blockKinds, h.textView.blockKinds, "seed \(seed)")
        }
    }

    /// Paste validation asks the view's own clipboard, not the general pasteboard. Whatever the system clipboard holds, a
    /// private board with text enables Paste and an empty one disables it (one of the two fails if validation reads
    /// the general board). The general pasteboard is never touched.
    func testPasteValidationReadsTheViewsClipboard() {
        let full = board()
        full.setString("text", forType: .string)
        let empty = board()
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        for action in [#selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)), #selector(NSTextView.pasteAsRichText(_:))] {
            item.action = action
            let h = host("x", board: full)
            XCTAssertTrue(h.textView.validateUserInterfaceItem(item), "\(action) with text on the clipboard")
            XCTAssertTrue(h.textView.validateMenuItem(item), "\(action) menu item with text on the clipboard")
            h.textView.clipboard = empty
            XCTAssertFalse(h.textView.validateUserInterfaceItem(item), "\(action) with an empty clipboard")
            XCTAssertFalse(h.textView.validateMenuItem(item), "\(action) menu item with an empty clipboard")
        }
    }
}

/// A drag as the destination sees it, so that the drag delegate path runs without a real drag session.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let view: NSTextView
    let sourceView: Any?
    let mask: NSDragOperation
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("sidekick.test.drag.\(UUID().uuidString)"))
    private let point: NSPoint

    init(view: NoteTextView, source: Any?, mask: NSDragOperation, at index: Int) {
        self.view = view; sourceView = source; self.mask = mask
        let rect = NoteTextEngine.caretRect(in: view, at: index)
        point = view.convert(NSPoint(x: rect.minX, y: rect.midY), to: nil)
        pasteboard.clearContents()
    }
    deinit { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { view.window }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { sourceView }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
