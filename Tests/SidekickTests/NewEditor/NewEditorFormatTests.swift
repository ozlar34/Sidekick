import XCTest
import AppKit
import NoteDocument
@testable import Sidekick

/// New editor, ticket 09: every format command (inline marks, block kinds, horizontal rule) through the real routes: the
/// main menu's key equivalents (real key events), the Format menu actions, and the functions the toolbar popover and the
/// checklist button call. The note document is the target, not marker characters.
@MainActor
final class NewEditorFormatTests: XCTestCase {
    private var delegate: AppDelegate!
    private var seeds: Int { Int(ProcessInfo.processInfo.environment["SIDEKICK_FUZZ_SEEDS"] ?? "") ?? 40 }

    override func setUp() async throws {
        _ = NSApplication.shared
        delegate = AppDelegate()
        delegate.installMainMenu()
    }

    /// A host whose text view is the target of the Format menu and its key equivalents.
    private func host(_ markdown: String) -> NewEditorHost {
        let h = NewEditorHost(markdown: markdown)
        delegate.formatTargetOverride = { [unowned h] in h.textView }
        return h
    }

    private func select(_ text: String, in h: NewEditorHost, occurrence: Int = 0) {
        var r = NSRange(location: 0, length: 0)
        var from = 0
        for _ in 0...occurrence {
            r = NSString(string: h.string).range(of: text, range: NSRange(location: from, length: h.length - from))
            from = NSMaxRange(r)
        }
        XCTAssertNotEqual(r.location, NSNotFound, text)
        h.textView.setSelectedRange(r)
    }

    private struct Shortcut { let name: String; let chars: String; let code: UInt16; let mods: NSEvent.ModifierFlags }
    private static let bold = Shortcut(name: "bold", chars: "b", code: 11, mods: [])
    private static let italic = Shortcut(name: "italic", chars: "i", code: 34, mods: [])
    private static let underline = Shortcut(name: "underline", chars: "u", code: 32, mods: [])
    private static let strike = Shortcut(name: "strike", chars: "x", code: 7, mods: [.shift])
    private static let code = Shortcut(name: "code", chars: "c", code: 8, mods: [.option])
    private static let bullet = Shortcut(name: "bullet", chars: "8", code: 28, mods: [.shift])
    private static let numbered = Shortcut(name: "numbered", chars: "7", code: 26, mods: [.shift])
    private static let quote = Shortcut(name: "quote", chars: "9", code: 25, mods: [.shift])
    private static let checklist = Shortcut(name: "checklist", chars: "l", code: 37, mods: [.shift])
    private static let h1 = Shortcut(name: "h1", chars: "1", code: 18, mods: [.option])
    private static let h2 = Shortcut(name: "h2", chars: "2", code: 19, mods: [.option])
    private static let h3 = Shortcut(name: "h3", chars: "3", code: 20, mods: [.option])
    private static let body = Shortcut(name: "body", chars: "0", code: 29, mods: [.option])

    private var formatMenu: NSMenu { NSApp.mainMenu!.items.first { $0.submenu?.title == "Format" }!.submenu! }
    private func press(_ s: Shortcut, in h: NewEditorHost) {
        XCTAssertTrue(h.shortcut(s.chars, keyCode: s.code, s.mods, in: formatMenu), "the Format menu answers \(s.name)")
    }

    // MARK: criterion 1: every command reachable from shortcut, menu and toolbar

    func testEveryShortcutDrivesItsCommandThroughTheMainMenu() {
        let cases: [(Shortcut, String, String)] = [
            (Self.bold, "hello world", "**hello** world"), (Self.italic, "hello world", "*hello* world"),
            (Self.underline, "hello world", "<u>hello</u> world"), (Self.strike, "hello world", "~~hello~~ world"),
            (Self.code, "hello world", "`hello` world"),
            (Self.bullet, "hello world", "- hello world"), (Self.numbered, "hello world", "1. hello world"),
            (Self.quote, "hello world", "> hello world"), (Self.checklist, "hello world", "- [ ] hello world"),
            (Self.h1, "hello world", "# hello world"), (Self.h2, "hello world", "## hello world"),
            (Self.h3, "hello world", "### hello world"), (Self.body, "## hello world", "hello world"),
        ]
        for (shortcut, source, expected) in cases {
            let h = host(source)
            select("hello", in: h)
            press(shortcut, in: h)
            XCTAssertEqual(h.markdown, expected, shortcut.name)
        }
    }

    func testEveryFormatMenuActionDrivesItsCommand() {
        let actions: [(String, (Any?) -> Void, String, String)] = [
            ("bold", delegate.formatBold, "hello world", "**hello** world"), ("italic", delegate.formatItalic, "hello world", "*hello* world"),
            ("underline", delegate.formatUnderline, "hello world", "<u>hello</u> world"),
            ("strike", delegate.formatStrikethrough, "hello world", "~~hello~~ world"),
            ("code", delegate.formatInlineCode, "hello world", "`hello` world"),
            ("bullet", delegate.formatBulletedList, "hello world", "- hello world"),
            ("numbered", delegate.formatNumberedList, "hello world", "1. hello world"),
            ("quote", delegate.formatBlockQuote, "hello world", "> hello world"),
            ("checklist", delegate.formatChecklist, "hello world", "- [ ] hello world"),
            ("h1", delegate.formatHeading1, "hello world", "# hello world"), ("h2", delegate.formatHeading2, "hello world", "## hello world"),
            ("h3", delegate.formatHeading3, "hello world", "### hello world"), ("body", delegate.formatHeadingBody, "# hello world", "hello world"),
        ]
        for (name, action, source, expected) in actions {
            let h = host(source)
            select("hello", in: h)
            action(nil)
            XCTAssertEqual(h.markdown, expected, name)
        }
    }

    /// The popover and the checklist button call these functions (EditorPaneView hands them the editor's text view).
    func testToolbarFunctionsDriveTheNewEditor() {
        func run(_ source: String, _ body: (NoteTextView) -> Void) -> String {
            let h = host(source)
            select("hello", in: h)
            body(h.textView)
            return h.markdown
        }
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: $0) }, "**hello** world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performWrap(prefix: "*", suffix: "*", in: $0) }, "*hello* world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performWrap(prefix: "<u>", suffix: "</u>", in: $0) }, "<u>hello</u> world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performWrap(prefix: "~~", suffix: "~~", in: $0) }, "~~hello~~ world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performLinePrefix(in: $0) }, "- hello world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performNumberedList(in: $0) }, "1. hello world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performBlockQuote(in: $0) }, "> hello world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performChecklist(in: $0) }, "- [ ] hello world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performHeadingLevel(in: $0, level: 1) }, "# hello world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performHeadingLevel(in: $0, level: 2) }, "## hello world")
        XCTAssertEqual(run("# hello world") { FormattingToolbarView.performHeadingLevel(in: $0, level: nil) }, "hello world")
        XCTAssertEqual(run("hello world") { FormattingToolbarView.performInsertThematicBreak(in: $0) }, "hello world\n---")
    }

    func testLinkAsksForAnAddressAndWritesNothingUntilItIsCommitted() {
        let h = host("hello world")
        select("hello", in: h)
        delegate.formatLink(nil)
        XCTAssertNotNil(h.textView.linkField)
        XCTAssertEqual(h.markdown, "hello world")
        h.pressInField(.escape)
        FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: h.textView)
        h.pressInField(.escape)
        XCTAssertEqual(h.markdown, "hello world")
    }

    // MARK: criterion 2: toggle rules

    func testInlineOnASelectionTogglesOnAndOff() {
        for (shortcut, on) in [(Self.bold, "**hello** world"), (Self.italic, "*hello* world"), (Self.underline, "<u>hello</u> world"),
                               (Self.strike, "~~hello~~ world"), (Self.code, "`hello` world")] {
            let h = host("hello world")
            select("hello", in: h)
            press(shortcut, in: h)
            XCTAssertEqual(h.markdown, on, shortcut.name)
            XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 0, length: 5), "selection stays, so the next press toggles off")
            press(shortcut, in: h)
            XCTAssertEqual(h.markdown, "hello world", shortcut.name)
        }
    }

    func testMixedSelectionIsMadeUniformThenToggledOff() {
        let h = host("**aa** bb")
        select("aa bb", in: h)
        press(Self.bold, in: h)
        XCTAssertEqual(h.markdown, "**aa bb**")
        press(Self.bold, in: h)
        XCTAssertEqual(h.markdown, "aa bb")
    }

    func testBoldAndItalicAreExclusiveAsToday() {
        let h = host("hello world")
        select("hello", in: h)
        press(Self.bold, in: h)
        press(Self.italic, in: h)
        XCTAssertEqual(h.markdown, "*hello* world", "italic over bold swaps, as the old editor does")
        press(Self.code, in: h)
        XCTAssertEqual(h.markdown, "`hello` world", "code excludes every other mark")
        press(Self.bold, in: h)
        XCTAssertEqual(h.markdown, "**hello** world")
    }

    func testUnderlineAndStrikethroughStackWithBold() {
        let h = host("hello world")
        select("hello", in: h)
        press(Self.bold, in: h)
        press(Self.underline, in: h)
        press(Self.strike, in: h)
        let run = NoteDocument(markdown: h.markdown).blocks[0].runs[0]
        XCTAssertEqual(run.text, "hello")
        XCTAssertNotNil(run.bold); XCTAssertTrue(run.underline); XCTAssertTrue(run.strikethrough)
        XCTAssertEqual(h.string, "hello world")
    }

    func testRememberedDelimitersAreUsedAndNewOnesUseDefaults() {
        var h = host("__bold__ and x")
        select("x", in: h)
        press(Self.bold, in: h)
        XCTAssertEqual(h.markdown, "__bold__ and __x__", "the block's own bold delimiter")
        h = host("_it_ and x")
        select("x", in: h)
        press(Self.italic, in: h)
        XCTAssertEqual(h.markdown, "_it_ and _x_")
        h = host("plain x")
        select("x", in: h)
        press(Self.bold, in: h)
        XCTAssertEqual(h.markdown, "plain **x**", "spec default")
    }

    func testMarksNeverTouchAPillAndOtherBlocksKeepTheirBytes() {
        let source = "first *it* line\nsee https://example.com/a now\nlast __b__\n"
        let h = host(source)
        select("see", in: h)
        h.textView.setSelectedRange(NSRange(location: NSString(string: h.string).range(of: "see").location, length: 7))
        press(Self.bold, in: h)
        let blocks = NoteDocument(markdown: h.markdown).blocks
        XCTAssertEqual(blocks[0].runs, NoteDocument(markdown: source).blocks[0].runs)
        XCTAssertNil(blocks[1].runs.first(where: { $0.pill != nil })?.bold)
        XCTAssertTrue(h.markdown.hasPrefix("first *it* line\n"))
        XCTAssertTrue(h.markdown.hasSuffix("\nlast __b__\n"))
    }

    func testNoSelectionArmsTheTypingStyle() {
        var h = host("x ")
        h.select(2)
        press(Self.bold, in: h)
        XCTAssertEqual(h.markdown, "x ", "arming edits nothing")
        h.type("hi")
        XCTAssertEqual(h.markdown, "x **hi**")
        h = host("x ")
        h.select(2)
        press(Self.bold, in: h)
        press(Self.bold, in: h)
        h.type("hi")
        XCTAssertEqual(h.markdown, "x hi", "a second press disarms")
        h = host("x ")
        h.select(2)
        press(Self.bold, in: h)
        press(Self.italic, in: h)
        h.type("hi")
        XCTAssertEqual(h.markdown, "x *hi*", "italic replaces bold in the arm, as today")
        h = host("x ")
        h.select(2)
        press(Self.underline, in: h)
        press(Self.strike, in: h)
        h.type("hi")
        let run = NoteDocument(markdown: h.markdown).blocks[0].runs.last!
        XCTAssertEqual(run.text, "hi"); XCTAssertTrue(run.underline); XCTAssertTrue(run.strikethrough)
    }

    func testArmedStyleIsDroppedWhenTheCaretMoves() {
        let h = host("ab")
        h.select(1)
        press(Self.bold, in: h)
        h.press(.right)
        h.press(.left)
        h.type("Z")
        XCTAssertEqual(h.markdown, "aZb")
    }

    func testArmedStyleAtAnEmptyLastLineAndInAnEmptyNote() {
        var h = host("")
        press(Self.bold, in: h)
        h.type("go")
        XCTAssertEqual(h.markdown, "**go**\n")
        h = host("first\n")
        h.select(6)
        press(Self.italic, in: h)
        h.type("go")
        XCTAssertEqual(h.markdown, "first\n*go*\n")
    }

    func testBlockCommandsToggleOnEveryLineOfASelection() {
        let source = "one\ntwo\nthree\nfour"
        for (shortcut, on, kind) in [(Self.bullet, "- one\n- two\n- three\nfour", "bullet"), (Self.quote, "> one\n> two\n> three\nfour", "quote"),
                                     (Self.checklist, "- [ ] one\n- [ ] two\n- [ ] three\nfour", "todo")] {
            let h = host(source)
            h.textView.setSelectedRange(NSRange(location: 2, length: 9))   // from "one" to "three"
            press(shortcut, in: h)
            XCTAssertEqual(h.markdown, on, shortcut.name)
            XCTAssertEqual(h.textView.blockKinds, [kind, kind, kind, "p"])
            press(shortcut, in: h)
            XCTAssertEqual(h.markdown, source, "all lines already have it: toggles off (\(shortcut.name))")
        }
    }

    func testMixedLinesAreAllGivenTheKind() {
        let h = host("- one\ntwo\n- three")
        h.textView.selectAll(nil)
        press(Self.bullet, in: h)
        XCTAssertEqual(h.markdown, "- one\n- two\n- three")
        let c = host("- [x] one\ntwo\n")
        c.textView.setSelectedRange(NSRange(location: 0, length: 7))
        press(Self.checklist, in: c)
        XCTAssertEqual(c.markdown, "- [x] one\n- [ ] two\n", "an item keeps its checked state; the other becomes an open item")
    }

    func testChecklistTogglesOffWhenAllLinesAreChecklistItemsCheckedOrNot() {
        let h = host("- [x] one\n- [ ] two")
        h.textView.selectAll(nil)
        press(Self.checklist, in: h)
        XCTAssertEqual(h.markdown, "one\ntwo")
    }

    func testEmptyLinesAreIgnoredByTheToggleCheckButGetTheKind() {
        let h = host("- one\n\n- two")
        h.textView.selectAll(nil)
        press(Self.bullet, in: h)
        XCTAssertEqual(h.markdown, "one\n\ntwo", "every non-empty line has it: off, the empty line stays empty")
        press(Self.bullet, in: h)
        XCTAssertEqual(h.markdown, "- one\n- \n- two", "on: every line, empty ones too")
    }

    func testNumberedListNumbersFromOneAndTogglesOff() {
        let h = host("one\ntwo\nthree")
        h.textView.selectAll(nil)
        press(Self.numbered, in: h)
        XCTAssertEqual(h.markdown, "1. one\n2. two\n3. three")
        XCTAssertEqual(NoteTextEngine.markers(in: h.textView).map(\.shape), [.number("1."), .number("2."), .number("3.")])
        press(Self.numbered, in: h)
        XCTAssertEqual(h.markdown, "one\ntwo\nthree")
        let k = host("a\nb")
        k.textView.selectAll(nil)
        press(Self.bullet, in: k)
        press(Self.numbered, in: k)
        XCTAssertEqual(k.markdown, "1. a\n2. b", "another list kind is replaced, not stacked")
    }

    /// Decided by Oguz: a selection with some lines already numbered is renumbered from 1, as in the old editor.
    func testNumberedListOnAMixedSelectionRenumbersFromOne() {
        for (source, expected) in [("3. a\nb", "1. a\n2. b"), ("x\n7) a\n9) b\ny\nz", "1. x\n2) a\n3) b\n4) y\n5) z"), ("a\n5. b\nc", "1. a\n2. b\n3. c")] {
            let h = host(source)
            h.textView.selectAll(nil)
            h.endUndoGroup()
            press(Self.numbered, in: h)
            XCTAssertEqual(h.markdown, expected, source)
            h.undo()
            XCTAssertEqual(h.markdown, source, "one undo step, exact bytes")
            XCTAssertEqual(h.textView.undoManager?.canUndo, false)
            h.endUndoGroup()
            h.textView.undoManager?.redo()
            XCTAssertEqual(h.markdown, expected, "redo")
        }
        let all = host("3. a\n9. b")
        all.textView.selectAll(nil)
        press(Self.numbered, in: all)
        XCTAssertEqual(all.markdown, "a\nb", "every line already numbered: off")
    }

    func testHeadingLevelsSwapAndThePickedActiveLevelReturnsToBody() {
        let h = host("# hello")
        press(Self.h2, in: h)
        XCTAssertEqual(h.markdown, "## hello")
        press(Self.h2, in: h)
        XCTAssertEqual(h.markdown, "hello", "the active level again: body")
        press(Self.h3, in: h)
        XCTAssertEqual(h.markdown, "### hello")
        press(Self.body, in: h)
        XCTAssertEqual(h.markdown, "hello")
        press(Self.body, in: h)
        XCTAssertEqual(h.markdown, "hello", "body on a plain line does nothing")
        let b = host("- item")
        press(Self.body, in: b)
        XCTAssertEqual(b.markdown, "- item", "body only strips a heading, as today")
        let list = host("- item")
        press(Self.h1, in: list)
        XCTAssertEqual(list.markdown, "# item")
    }

    func testAnEditedBlockKeepsItsRememberedForms() {
        let source = "* star\n  - [X] done\n> q"
        let h = host(source)
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        press(Self.numbered, in: h)
        XCTAssertEqual(NoteDocument(markdown: h.markdown).blocks[0].kind, .numbered)
        h.undo()
        XCTAssertEqual(h.markdown, source)
        select("done", in: h)
        press(Self.bullet, in: h)
        XCTAssertEqual(h.markdown, "* star\n  - done\n> q", "indent and bullet character of the item are kept")
        h.undo()
        press(Self.checklist, in: h)
        XCTAssertEqual(h.markdown, "* star\ndone\n> q", "the only line is a checklist item: off")
        h.undo()
        XCTAssertEqual(h.markdown, source)
        select("star", in: h)
        press(Self.checklist, in: h)
        XCTAssertEqual(h.markdown, "* [ ] star\n  - [X] done\n> q", "the bullet character of the item is kept; the other item is untouched")
    }

    func testRuleIsInsertedBelowTheCaretLineWithALineBelowIt() {
        var h = host("alpha")
        h.select(5)
        FormattingToolbarView.performInsertThematicBreak(in: h.textView)
        XCTAssertEqual(h.markdown, "alpha\n---", "the file ends with the rule until text is typed below it, as for /hr")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider"])
        XCTAssertEqual(h.location, h.length, "the caret is on the new line below the rule")
        h.type("x")
        XCTAssertEqual(h.markdown, "alpha\n---\nx")
        h = host("a\nb\n")
        h.select(0)
        FormattingToolbarView.performInsertThematicBreak(in: h.textView)
        XCTAssertEqual(h.markdown, "a\n---\n\nb\n")
        XCTAssertEqual(h.location, 3)
        h = host("")
        FormattingToolbarView.performInsertThematicBreak(in: h.textView)
        XCTAssertEqual(h.markdown, "---\n")
        h = host("# head")
        h.select(2)
        FormattingToolbarView.performInsertThematicBreak(in: h.textView)
        XCTAssertEqual(h.markdown, "# head\n---")
        h.type("z")
        XCTAssertEqual(h.markdown, "# head\n---\nz", "the line below the rule is plain, not a heading")
    }

    func testCommandsOnAnEmptyLastLineAndEmptyNote() {
        var h = host("")
        press(Self.bullet, in: h)
        h.type("x")
        XCTAssertEqual(h.markdown, "- x\n")
        h = host("a\n")
        h.select(2)
        press(Self.h1, in: h)
        h.type("T")
        XCTAssertEqual(h.markdown, "a\n# T\n")
        h = host("a\n- ")
        h.select(h.length)
        press(Self.bullet, in: h)
        XCTAssertEqual(h.markdown, "a\n", "an empty last item toggles off")
    }

    // MARK: criterion 3: one undo step, exact bytes

    func testEveryCommandIsOneUndoStepAndUndoRestoresTheFileBytes() {
        let source = "* star **b** line\r\n  - [X] done _i_\r\n> quote\r\nplain https://example.com/x text\r\n# Head\r\n1) one\r\n2) two\r\n"
        let all: [(String, Shortcut)] = [("bold", Self.bold), ("italic", Self.italic), ("underline", Self.underline), ("strike", Self.strike),
                                         ("code", Self.code), ("bullet", Self.bullet), ("numbered", Self.numbered), ("quote", Self.quote),
                                         ("checklist", Self.checklist), ("h1", Self.h1), ("h2", Self.h2), ("h3", Self.h3), ("body", Self.body)]
        for (name, shortcut) in all {
            for range in [NSRange(location: 3, length: 20), NSRange(location: 0, length: 0), NSRange(location: 0, length: 120)] {
                let h = host(source)
                h.textView.setSelectedRange(NSRange(location: min(range.location, h.length), length: min(range.length, h.length - min(range.location, h.length))))
                h.endUndoGroup()
                press(shortcut, in: h)
                h.undo()
                XCTAssertEqual(h.markdown, source, "\(name) \(range)")
                XCTAssertEqual(h.textView.undoManager?.canUndo, false, "\(name) is one undo step")
            }
        }
        let rule = host("a\nb")
        rule.select(0)
        rule.endUndoGroup()
        FormattingToolbarView.performInsertThematicBreak(in: rule.textView)
        rule.undo()
        XCTAssertEqual(rule.markdown, "a\nb")
        XCTAssertEqual(rule.textView.undoManager?.canUndo, false)
    }

    func testRedoReappliesTheCommand() {
        let h = host("hello world")
        select("hello", in: h)
        h.endUndoGroup()
        press(Self.bold, in: h)
        h.undo()
        h.endUndoGroup()
        h.textView.undoManager?.redo()
        XCTAssertEqual(h.markdown, "**hello** world")
    }

    // MARK: criterion 4: active styles and block kind

    func testTheStateShowsTheActiveStylesAndBlockKindAtTheCaret() {
        let h = host("# head\nplain **bold** and *ital*\n- item\n1. nnn\n> qqq\n- [ ] ttt\n")
        XCTAssertEqual(h.textView.formatState, NoteFormatState(inline: [], heading: 1, block: nil))
        select("bold", in: h)
        h.textView.setSelectedRange(NSRange(location: h.textView.selectedRange().location + 2, length: 0))
        XCTAssertEqual(h.textView.formatState.inline, [.bold])
        select("ital", in: h)
        h.textView.setSelectedRange(NSRange(location: h.textView.selectedRange().location + 1, length: 0))
        XCTAssertEqual(h.textView.formatState.inline, [.italic])
        select("bold", in: h)
        XCTAssertEqual(h.textView.formatState.inline, [.bold], "a selection shows what all of it has")
        select("bold and", in: h)
        XCTAssertEqual(h.textView.formatState.inline, [], "…and only that")
        for (text, block) in [("item", FormattingToolbarView.LinePrefix.bullet), ("nnn", .numbered), ("qqq", .blockquote), ("ttt", .checklist)] {
            select(text, in: h)
            h.textView.setSelectedRange(NSRange(location: h.textView.selectedRange().location, length: 0))
            XCTAssertEqual(h.textView.formatState.block, block, text)
            XCTAssertNil(h.textView.formatState.heading)
        }
    }

    func testTheStateShowsAnArmedStyleAndHeadingLevelsAreCappedAtThree() {
        let h = host("plain\n#### deep")
        h.select(5)
        press(Self.bold, in: h)
        XCTAssertEqual(h.textView.formatState.inline, [.bold])
        press(Self.underline, in: h)
        XCTAssertEqual(h.textView.formatState.inline, [.bold, .underline])
        h.select(h.length)
        XCTAssertEqual(h.textView.formatState, NoteFormatState(inline: [], heading: 3, block: nil))
    }

    func testTheControllerGetsTheStateTheToolbarShows() {
        let h = host("# head\nplain **bold**\n")
        let controller = HybridEditorController()
        h.textView.bindFormatState(to: controller)
        select("bold", in: h)
        h.textView.setSelectedRange(NSRange(location: h.textView.selectedRange().location + 1, length: 0))
        XCTAssertEqual(controller.armedInlineKinds, [.bold])
        XCTAssertNil(controller.activeHeadingLevel)
        h.select(2)
        XCTAssertEqual(controller.activeHeadingLevel, 1)
        XCTAssertEqual(controller.armedInlineKinds, [])
        h.select(h.length)
        press(Self.bullet, in: h)
        XCTAssertEqual(controller.activeLinePrefix, .bullet)
    }

    // MARK: criterion 5: validation

    func testFormatItemsAreEnabledWhileTheEditorHasFocusAndDisabledWithout() {
        let h = host("hello")
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.formatBold(_:)), keyEquivalent: "")
        XCTAssertTrue(delegate.validateUserInterfaceItem(item))
        h.window.makeFirstResponder(nil)
        XCTAssertFalse(delegate.validateUserInterfaceItem(item))
    }

    // MARK: carry-over from ticket 12: nothing in a code block or a table

    private static let everyShortcut: [Shortcut] = [bold, italic, underline, strike, code, bullet, numbered, quote, checklist, h1, h2, h3, body]

    private func assertNothingChanges(_ source: String, selecting range: NSRange, file: StaticString = #filePath, line: UInt = #line) {
        let h = host(source)
        h.textView.setSelectedRange(range)
        h.endUndoGroup()
        for shortcut in Self.everyShortcut {
            press(shortcut, in: h)
            XCTAssertEqual(h.markdown, source, shortcut.name, file: file, line: line)
        }
        FormattingToolbarView.performInsertThematicBreak(in: h.textView)
        XCTAssertEqual(h.markdown, source, "rule", file: file, line: line)
        XCTAssertEqual(h.textView.undoManager?.canUndo, false, "nothing registered", file: file, line: line)
        XCTAssertEqual(h.textView.formatState.inline, [], file: file, line: line)
        h.type("Q")
        XCTAssertTrue(h.string.contains("Q"), file: file, line: line)
        XCTAssertFalse(h.markdown.contains("**Q") || h.markdown.contains("`Q") || h.markdown.contains("*Q"), "no armed style was left behind", file: file, line: line)
    }

    func testFormatCommandsDoNothingInsideACodeBlock() {
        let source = "before\n```swift\ncode **x** line\n# not a heading\n```\nafter\n"
        let h = host(source)
        let caretInCode = NSString(string: h.string).range(of: "code").location + 2
        assertNothingChanges(source, selecting: NSRange(location: caretInCode, length: 0))
        assertNothingChanges(source, selecting: NSRange(location: caretInCode, length: 6))
    }

    func testFormatCommandsDoNothingInsideATable() {
        let source = "before\n| a | b |\n| - | - |\n| c | d |\nafter\n"
        let h = host(source)
        let inTable = NSString(string: h.string).range(of: "a").location
        assertNothingChanges(source, selecting: NSRange(location: inTable, length: 0))
        assertNothingChanges(source, selecting: NSRange(location: inTable, length: 1))
    }

    func testASelectionAcrossTextAndACodeBlockFormatsOnlyTheText() {
        let source = "one\n```\n**keep** me\n```\ntwo\n"
        let h = host(source)
        h.textView.selectAll(nil)
        press(Self.bullet, in: h)
        XCTAssertEqual(h.markdown, "- one\n```\n**keep** me\n```\n- two\n")
        press(Self.bold, in: h)
        XCTAssertEqual(h.markdown, "- **one**\n```\n**keep** me\n```\n- **two**\n")
    }

    // MARK: with the switch off the old editor is unchanged

    func testTheOldEditorsCommandsAreUnchanged() {
        XCTAssertFalse(NewEditorSwitch.isOn)
        func old(_ body: String, _ run: (NSTextView) -> Void) -> NSTextView {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            tv.string = body
            tv.setSelectedRange(NSRange(location: 0, length: 5))
            run(tv)
            return tv
        }
        XCTAssertEqual(old("hello world") { FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: $0) }.string, "**hello** world")
        XCTAssertEqual(old("hello world") { FormattingToolbarView.performLinePrefix(in: $0) }.string, "- hello world")
        XCTAssertEqual(old("hello world") { FormattingToolbarView.performNumberedList(in: $0) }.string, "1. hello world")
        XCTAssertEqual(old("hello world") { FormattingToolbarView.performBlockQuote(in: $0) }.string, "> hello world")
        XCTAssertEqual(old("hello world") { FormattingToolbarView.performChecklist(in: $0) }.string, "- [ ] hello world")
        XCTAssertEqual(old("hello world") { FormattingToolbarView.performHeadingLevel(in: $0, level: 2) }.string, "## hello world")
        XCTAssertEqual(old("hello world") { FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: $0) }.string, "[hello]() world")
        // The menu action reaches the old editor's text view through the same functions.
        let tv = old("hello world") { _ in }
        delegate.formatTargetOverride = { tv }
        delegate.formatItalic(nil)
        XCTAssertEqual(tv.string, "*hello* world")
        delegate.formatHeading1(nil)
        XCTAssertEqual(tv.string, "# *hello* world")
    }

    // MARK: generated

    private struct Pick {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func int(_ n: Int) -> Int { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Int(state % UInt64(max(1, n))) }
    }

    /// Any command on any selection of a generated note: one undo step back to the exact bytes, the visible text is
    /// untouched, and what is written reads back as the same document.
    func testGeneratedCommandsAreOneUndoStepAndKeepTheTextAndTheBytes() {
        var changed = 0
        defer { XCTAssertGreaterThan(changed, seeds / 4, "the generated commands must mostly do something, or the properties below are vacuous") }
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            var pick = Pick(seed)
            let source = gen.markdown()
            let h = host(source)
            let length = h.length
            let location = pick.int(length + 1)
            let selected = pick.int(3) == 0 ? 0 : pick.int(length - location + 1)
            h.textView.setSelectedRange(NSRange(location: location, length: selected))
            let text = h.string
            let shortcut = Self.everyShortcut[pick.int(Self.everyShortcut.count)]
            h.endUndoGroup()
            press(shortcut, in: h)
            let written = h.markdown
            if written != source { changed += 1 }
            XCTAssertEqual(h.string, text, "seed \(seed) \(shortcut.name): visible text unchanged")
            XCTAssertEqual(NoteDocument(markdown: written).markdown(), written, "seed \(seed) \(shortcut.name): stable")
            h.undo()
            XCTAssertEqual(h.markdown, source, "seed \(seed) \(shortcut.name) at \(location)+\(selected)")
            XCTAssertEqual(h.textView.undoManager?.canUndo, false, "seed \(seed) \(shortcut.name): one step")
        }
    }

    /// Code blocks and tables of a generated note come out of any command with their bytes.
    func testGeneratedCommandsLeaveCodeBlocksAndTablesAlone() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed &+ 5000)
            var pick = Pick(seed)
            let source = gen.markdown()
            let h = host(source)
            let before = NoteDocument(markdown: source).blocks.enumerated().filter { $0.element.kind == .fence || $0.element.kind == .table }
            guard !before.isEmpty else { continue }
            h.textView.selectAll(nil)
            for _ in 0..<3 {
                press(Self.everyShortcut[pick.int(Self.everyShortcut.count)], in: h)
                let now = NoteDocument(markdown: h.markdown).blocks.filter { $0.kind == .fence || $0.kind == .table }
                XCTAssertEqual(now.map(\.runs), before.map(\.element.runs), "seed \(seed)")
            }
        }
    }
}
