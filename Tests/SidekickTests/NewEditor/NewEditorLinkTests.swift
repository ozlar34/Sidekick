import XCTest
import AppKit
import NoteDocument
@testable import Sidekick

/// New editor, ticket 11: Cmd+K (and the Link menu item and toolbar button) opens a small address field at the selection
/// or at the link or pill under the caret. Return commits, Escape cancels, focus and selection come back. Driven by real
/// key events: Cmd+K through the Format menu's key equivalent, everything typed in the field through `NSWindow.sendEvent`.
@MainActor
final class NewEditorLinkTests: XCTestCase {
    private var delegate: AppDelegate!
    private var seeds: Int { Int(ProcessInfo.processInfo.environment["SIDEKICK_FUZZ_SEEDS"] ?? "") ?? 40 }

    override func setUp() async throws {
        _ = NSApplication.shared
        delegate = AppDelegate()
        delegate.installMainMenu()
    }

    private func host(_ markdown: String) -> NewEditorHost {
        let h = NewEditorHost(markdown: markdown)
        delegate.formatTargetOverride = { [unowned h] in h.textView }
        return h
    }

    private var formatMenu: NSMenu { NSApp.mainMenu!.items.first { $0.submenu?.title == "Format" }!.submenu! }

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

    /// Cmd+K as a key event. Returns the field it opened, if any.
    @discardableResult
    private func cmdK(_ h: NewEditorHost, file: StaticString = #filePath, line: UInt = #line) -> NoteLinkFieldView? {
        _ = h.shortcut("k", keyCode: 40, [], in: formatMenu)
        return h.textView.linkField
    }

    private func commit(_ address: String, _ h: NewEditorHost) {
        h.typeInField(address)
        h.pressInField(.enter)
    }

    // MARK: criterion 1: Cmd+K on selected text creates a link after the address is committed

    func testCmdKOnSelectedTextOpensTheFieldAndReturnCreatesTheLink() {
        let h = host("hello world")
        select("hello", in: h)
        let field = cmdK(h)
        XCTAssertNotNil(field, "Cmd+K opens the address field")
        XCTAssertEqual(field?.stringValue, "", "a new link starts empty")
        XCTAssertEqual(h.markdown, "hello world", "nothing is written before the address is committed")
        commit("https://example.com/a", h)
        XCTAssertNil(h.textView.linkField, "the field closes")
        XCTAssertEqual(h.markdown, "[hello](https://example.com/a) world")
        XCTAssertEqual(h.savedMarkdown, "[hello](https://example.com/a) world", "the save path got the standard link markdown")
        XCTAssertEqual(h.string, "hello world", "the address is not in the text")
        XCTAssertEqual(NoteTextEngine.address(ofCharacterAt: 2, in: h.textView.textStorage!), "https://example.com/a")
    }

    func testTheFieldOpensFromTheMenuItemAndFromTheToolbarButton() {
        let h = host("hello world")
        select("world", in: h)
        delegate.formatLink(nil)
        XCTAssertNotNil(h.textView.linkField, "Format > Link")
        h.pressInField(.escape)
        XCTAssertNil(h.textView.linkField)
        FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: h.textView)
        XCTAssertNotNil(h.textView.linkField, "the toolbar and popover Link button")
        commit("u", h)
        XCTAssertEqual(h.markdown, "hello [world](u)")
    }

    func testALinkOverMarkedTextKeepsTheMarksAndTheVisibleText() {
        let h = host("a **bold** and *it* end")
        select("bold and it", in: h)
        cmdK(h)
        commit("https://e.co/x", h)
        XCTAssertEqual(h.string, "a bold and it end")
        XCTAssertEqual(NoteDocument(markdown: h.markdown).markdown(), h.markdown, "what is written reads back the same")
        XCTAssertTrue(h.markdown.contains("](https://e.co/x)"), h.markdown)
        h.undo()
        XCTAssertEqual(h.markdown, "a **bold** and *it* end")
    }

    func testAnAddressIsTrimmedAndCannotBreakTheMarkdown() {
        let h = host("hello world")
        select("hello", in: h)
        cmdK(h)
        commit("  https://e.co/a)b|c  ", h)
        XCTAssertEqual(h.markdown, "[hello](https://e.co/a%29b%7Cc) world")
        XCTAssertEqual(NoteDocument(markdown: h.markdown).markdown(), h.markdown)
    }

    func testAnEmptySelectionAwayFromAnyLinkDoesNothing() {
        let h = host("hello world")
        h.select(3)
        XCTAssertNil(cmdK(h))
        XCTAssertEqual(h.markdown, "hello world")
        XCTAssertEqual(h.textView.undoManager?.canUndo, false)
    }

    func testALinkOverTextThatEqualsItsAddressIsShownAsAPill() {
        let h = host("see example.com now")
        select("example.com", in: h)
        cmdK(h)
        commit("example.com", h)
        XCTAssertEqual(h.markdown, "see [example.com](example.com) now", "a label equal to its address is the pill's link form")
        XCTAssertEqual(h.string, "see \u{FFFC} now", "shown as one pill object")
        XCTAssertEqual(h.string, NewEditorHost(markdown: h.markdown).string, "the same as after a reload")
        h.undo()
        XCTAssertEqual(h.markdown, "see example.com now")
        XCTAssertEqual(h.string, "see example.com now")
    }

    // MARK: criterion 2: Cmd+K on an existing link or pill edits its address

    func testCmdKInsideALinkShowsItsAddressAndEditingChangesIt() {
        let h = host("go [label](https://old.example/p) end")
        h.select(NSString(string: h.string).range(of: "bel").location)
        let field = cmdK(h)
        XCTAssertEqual(field?.stringValue, "https://old.example/p")
        commit("https://new.example/q", h)
        XCTAssertEqual(h.markdown, "go [label](https://new.example/q) end")
        XCTAssertEqual(h.string, "go label end")
    }

    func testCmdKOnASelectionInsideALinkEditsThatLinkNotASecondOne() {
        let h = host("go [label](u1) end")
        select("abe", in: h)
        XCTAssertEqual(cmdK(h)?.stringValue, "u1")
        commit("u2", h)
        XCTAssertEqual(h.markdown, "go [label](u2) end")
    }

    func testCmdKNextToABarePillEditsItAndKeepsTheBareForm() {
        let h = host("see https://a.example/p now")
        h.select(NSString(string: h.string).range(of: "\u{FFFC}").location + 1)   // right after the pill
        XCTAssertEqual(cmdK(h)?.stringValue, "https://a.example/p")
        commit("https://b.example/q", h)
        XCTAssertEqual(h.markdown, "see https://b.example/q now", "a bare pill stays bare")
        XCTAssertEqual(h.string, "see \u{FFFC} now")
    }

    func testCmdKOnALinkFormPillEditsItAndKeepsTheLinkForm() {
        let h = host("see [https://a.example](https://a.example) now")
        h.select(NSString(string: h.string).range(of: "\u{FFFC}").location)   // right before the pill
        XCTAssertEqual(cmdK(h)?.stringValue, "https://a.example")
        commit("https://b.example", h)
        XCTAssertEqual(h.markdown, "see [https://b.example](https://b.example) now")
        XCTAssertEqual(h.string, "see \u{FFFC} now")
    }

    func testSelectingExactlyAPillEditsIt() {
        let h = host("x https://a.example y")
        h.textView.setSelectedRange(NSString(string: h.string).range(of: "\u{FFFC}"))
        XCTAssertEqual(cmdK(h)?.stringValue, "https://a.example")
        commit("https://c.example", h)
        XCTAssertEqual(h.markdown, "x https://c.example y")
    }

    func testEditingALinkToItsOwnLabelMakesItAPill() {
        let h = host("a [https://q.example](https://old.example) b")
        h.select(5)
        cmdK(h)
        commit("https://q.example", h)
        XCTAssertEqual(h.markdown, "a [https://q.example](https://q.example) b")
        XCTAssertEqual(h.string, "a \u{FFFC} b")
        h.undo()
        XCTAssertEqual(h.markdown, "a [https://q.example](https://old.example) b")
    }

    // MARK: criterion 3: an empty address removes the link and keeps the label

    func testAnEmptyAddressRemovesALinkAndKeepsTheLabel() {
        let h = host("go [label](https://old.example) end")
        h.select(NSString(string: h.string).range(of: "label").location + 1)
        cmdK(h)
        h.pressInField(.enter)   // the field still holds the old address: nothing changes
        XCTAssertEqual(h.markdown, "go [label](https://old.example) end")
        cmdK(h)
        h.clearField()
        h.pressInField(.enter)
        XCTAssertEqual(h.markdown, "go label end")
        XCTAssertEqual(h.string, "go label end")
    }

    func testAnEmptyAddressOnAPillLeavesItsAddressAsPlainText() {
        for (source, written) in [("see https://a.example/p now", "see https\\://a.example/p now"),
                                  ("see [https://a.example](https://a.example) now", "see https\\://a.example now")] {
            let h = host(source)
            h.select(NSString(string: h.string).range(of: "\u{FFFC}").location + 1)
            cmdK(h)
            h.clearField()
            h.pressInField(.enter)
            XCTAssertEqual(h.string, source.contains("[") ? "see https://a.example now" : "see https://a.example/p now", source)
            XCTAssertEqual(h.markdown, written, source)
            XCTAssertEqual(NoteDocument(markdown: h.markdown).markdown(), h.markdown, "reads back as the same plain text")
            XCTAssertEqual(NewEditorHost(markdown: h.markdown).string, h.string, "no pill comes back after a reload")
        }
    }

    // MARK: criterion 4: each commit is one undo step

    func testEachCommitIsOneUndoStepBackToTheExactBytes() {
        let cases: [(source: String, at: String, address: String)] = [
            ("hello world\n", "hello", "https://e.co/a"),
            ("# head ing\n- item two\n", "item", "u"),
            ("go [label](https://old.example) end", "label", "https://new.example"),
            ("go [label](https://old.example) end", "label", ""),
            ("see https://a.example/p now", "\u{FFFC}", "https://b.example"),
            ("see [https://a.example](https://a.example) now", "\u{FFFC}", ""),
            ("a **b** c", "b", "x"),
        ]
        for c in cases {
            let h = host(c.source)
            select(c.at, in: h)
            cmdK(h)
            h.clearField()
            commit(c.address, h)
            XCTAssertNotEqual(h.markdown, c.source, "\(c.source): the commit changed something")
            h.undo()
            XCTAssertEqual(h.markdown, c.source, "undo restores the exact bytes: \(c.source)")
            XCTAssertEqual(h.textView.undoManager?.canUndo, false, "one step only: \(c.source)")
        }
    }

    // MARK: criterion 5: standard markdown; an unedited link keeps its bytes

    func testAnUnchangedLinkOrPillKeepsItsBytesAndRegistersNoUndo() {
        let source = "a [x](u) [https://q.r](https://q.r) b https://s.t\n"
        for probe in ["x", "\u{FFFC}"] {
            for occurrence in probe == "x" ? [0] : [0, 1] {
                let h = host(source)
                select(probe, in: h, occurrence: occurrence)
                h.textView.setSelectedRange(NSRange(location: h.textView.selectedRange().location, length: 0))
                let field = cmdK(h)
                XCTAssertNotNil(field)
                h.pressInField(.enter)
                XCTAssertEqual(h.markdown, source, "Return on the unchanged address")
                XCTAssertEqual(h.textView.undoManager?.canUndo, false)
                cmdK(h)
                h.pressInField(.escape)
                XCTAssertEqual(h.markdown, source, "Escape")
                XCTAssertEqual(h.textView.undoManager?.canUndo, false)
            }
        }
    }

    func testEditingOneLinkLeavesTheOtherBlocksBytesAlone() {
        let source = "*a*   b\n\n[x](u)  \n- [ ] t\n"
        let h = host(source)
        select("x", in: h)
        cmdK(h)
        h.clearField()
        commit("v", h)
        XCTAssertEqual(h.markdown, "*a*   b\n\n[x](v)  \n- [ ] t\n")
    }

    // MARK: criterion 6: Return commits, Escape cancels, focus and selection come back

    func testEscapeCancelsAndRestoresFocusAndSelection() {
        let h = host("hello world")
        select("lo wo", in: h)
        let before = h.textView.selectedRange()
        cmdK(h)
        XCTAssertTrue(h.window.firstResponder !== h.textView, "the field has the focus")
        h.typeInField("https://nope")
        h.pressInField(.escape)
        XCTAssertNil(h.textView.linkField)
        XCTAssertEqual(h.markdown, "hello world")
        XCTAssertEqual(h.textView.undoManager?.canUndo, false)
        XCTAssertTrue(h.window.firstResponder === h.textView, "focus is back in the editor")
        XCTAssertEqual(h.textView.selectedRange(), before, "selection restored")
        h.type("Z")
        XCTAssertEqual(h.markdown, "helZrld", "typing goes to the editor and replaces the restored selection")
    }

    func testReturnCommitsAndRestoresFocusAndSelection() {
        let h = host("hello world")
        select("lo wo", in: h)
        let before = h.textView.selectedRange()
        cmdK(h)
        commit("https://e.co", h)
        XCTAssertTrue(h.window.firstResponder === h.textView)
        XCTAssertEqual(h.textView.selectedRange(), before)
        XCTAssertEqual(h.markdown, "hel[lo wo](https://e.co)rld")
    }

    func testFocusAndCaretComeBackForALinkEditedFromTheCaret() {
        let h = host("go [label](u) end")
        let caret = NSString(string: h.string).range(of: "bel").location
        h.select(caret)
        cmdK(h)
        h.clearField()
        commit("w", h)
        XCTAssertTrue(h.window.firstResponder === h.textView)
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: caret, length: 0))
    }

    func testCmdKWhileTheFieldIsOpenKeepsOneField() {
        let h = host("hello world")
        select("hello", in: h)
        let first = cmdK(h)
        delegate.formatLink(nil)   // the menu is off while the field has the focus; the toolbar button still reaches here
        FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: h.textView)
        XCTAssertEqual(h.textView.subviews.filter { $0 is NoteLinkFieldView }.count, 1)
        XCTAssertTrue(h.textView.linkField === first)
        h.pressInField(.escape)
    }

    func testClickingAwayCancelsWithoutTakingTheFocusBack() {
        let h = host("hello world")
        select("hello", in: h)
        cmdK(h)
        h.typeInField("https://nope")
        h.window.makeFirstResponder(nil)   // the focus leaves, as on a click elsewhere
        XCTAssertNil(h.textView.linkField)
        XCTAssertEqual(h.markdown, "hello world")
        XCTAssertFalse(h.window.firstResponder === h.textView, "the focus is not pulled back")
        XCTAssertEqual(h.textView.undoManager?.canUndo, false)
    }

    func testAFieldOpenedOnAnotherTextIsNotAppliedToTheNewText() {
        let h = host("hello world")
        select("hello", in: h)
        cmdK(h)
        h.typeInField("https://nope")
        h.textView.replaceAllWithMarkdown("other note text")
        h.pressInField(.enter)
        XCTAssertEqual(h.markdown, "other note text")
    }

    func testASelectionHoldingAPillLinksOnlyTheTextAround() {
        let h = host("see https://a.example now")
        h.textView.selectAll(nil)
        cmdK(h)
        commit("u", h)
        XCTAssertEqual(h.string, "see \u{FFFC} now")
        XCTAssertEqual(NoteDocument(markdown: h.markdown).markdown(), h.markdown)
        XCTAssertTrue(h.markdown.contains("https://a.example"), "the pill keeps its address: \(h.markdown)")
        h.undo()
        XCTAssertEqual(h.markdown, "see https://a.example now")
    }

    func testTheFieldSitsUnderTheSelection() {
        let h = host("hello world")
        select("world", in: h)
        let field = cmdK(h)!
        let anchor = NoteTextEngine.caretRect(in: h.textView, at: NSString(string: h.string).range(of: "world").location)
        XCTAssertTrue(h.textView.bounds.contains(field.frame), "inside the view")
        XCTAssertGreaterThanOrEqual(field.frame.minY, anchor.maxY - 1, "below the text it belongs to")
        XCTAssertLessThan(abs(field.frame.minX - anchor.minX), 40, "at the selection")
        h.pressInField(.escape)
    }

    // MARK: criterion 3 of the effort: nothing in a code block or a table

    func testCmdKDoesNothingInACodeBlockOrATable() {
        for (source, probe) in [("before\n```swift\ncode line\n# not\n```\nafter\n", "code"), ("before\n| a | b |\n| - | - |\n| c | d |\nafter\n", "a")] {
            for length in [0, 1, 3] {
                let h = host(source)
                h.textView.setSelectedRange(NSRange(location: NSString(string: h.string).range(of: probe).location, length: length))
                h.endUndoGroup()
                XCTAssertNil(cmdK(h), "\(probe) \(length)")
                FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: h.textView)
                delegate.formatLink(nil)
                XCTAssertNil(h.textView.linkField)
                XCTAssertEqual(h.markdown, source)
                XCTAssertEqual(h.textView.undoManager?.canUndo, false)
                XCTAssertTrue(h.window.firstResponder === h.textView)
            }
        }
    }

    func testASelectionAcrossLinesOrIntoACodeBlockDoesNothing() {
        let source = "one\ntwo\n```\ncode\n```\n"
        let h = host(source)
        h.textView.setSelectedRange(NSRange(location: 1, length: 5))   // across two paragraphs
        XCTAssertNil(cmdK(h))
        h.textView.setSelectedRange(NSRange(location: 4, length: 9))   // text into the code block
        XCTAssertNil(cmdK(h))
        XCTAssertEqual(h.markdown, source)
    }

    // MARK: with the switch off the old editor is unchanged

    func testTheOldEditorsCmdKIsUnchanged() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.string = "hello world"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        delegate.formatTargetOverride = { tv }
        delegate.formatLink(nil)
        XCTAssertEqual(tv.string, "[hello]() world", "the old editor still wraps and leaves the address to be typed")
        let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        plain.string = "hello world"
        plain.setSelectedRange(NSRange(location: 0, length: 5))
        FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: plain)
        XCTAssertEqual(plain.string, "[hello]() world")
        XCTAssertFalse(plain.subviews.contains { $0 is NoteLinkFieldView }, "no field in the old editor")
    }

    /// Seed 270 of the generated test below (found by the 300-seed final run): a bare URL pill whose address is changed.
    /// A pill's text is its address, so the new address is the new text; the rest of the line is untouched.
    func testChangingThePillAddressChangesItsTextAndNothingElse() {
        let source = "caf\u{e9} https://example.com/beta 42"
        let h = host(source)
        h.textView.setSelectedRange(NSRange(location: 5, length: 1))   // the pill is one character after "café "
        h.endUndoGroup()
        XCTAssertEqual(h.textView.linkTarget()?.address, "https://example.com/beta")
        XCTAssertNotNil(cmdK(h))
        h.clearField()
        commit("https://e.co/270", h)
        XCTAssertEqual(h.textView.document.blocks.map(\.text), ["caf\u{e9} https://e.co/270 42"])
        XCTAssertEqual(h.markdown, "caf\u{e9} https://e.co/270 42")
        h.undo()
        XCTAssertEqual(h.markdown, source)
    }

    // MARK: generated

    private struct Pick {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func int(_ n: Int) -> Int { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Int(state % UInt64(max(1, n))) }
    }

    /// Cmd+K at any place of a generated note, then an address (new, same, empty): the visible text never changes, what
    /// is written reads back as the same document and shows as the buffer does now, and Cmd+Z gives back the exact bytes
    /// in one step. Where nothing opens, nothing changes.
    func testGeneratedLinkEditsAreOneUndoStepAndKeepTheTextAndTheBytes() {
        var opened = 0
        defer { XCTAssertGreaterThan(opened, seeds / 4, "the generated places must mostly open the field, or the properties are vacuous") }
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            let source = gen.markdown()
            var pick = Pick(seed)
            let h = host(source)
            guard h.length > 0 else { continue }
            let location = pick.int(h.length)
            let length = pick.int(2) == 0 ? min(h.length - location, 1 + pick.int(9)) : 0
            h.textView.setSelectedRange(NSRange(location: location, length: length))
            h.endUndoGroup()
            let textBefore = h.textView.document.blocks.map(\.text)
            let target = h.textView.linkTarget()
            let blockIndex = h.textView.paragraph(at: location)?.0
            guard cmdK(h) != nil else {
                XCTAssertEqual(h.markdown, source, "seed \(seed): nothing opened, nothing changed")
                XCTAssertEqual(h.textView.undoManager?.canUndo, false, "seed \(seed)")
                continue
            }
            opened += 1
            let address = ["https://e.co/\(seed)", "notes/\(seed)", "", "same"][pick.int(4)]
            if address == "same" { h.pressInField(.enter); XCTAssertEqual(h.markdown, source, "seed \(seed): unchanged"); continue }
            h.clearField()
            commit(address, h)
            let written = h.markdown
            // A link keeps its label text. A pill's text is its address, so a new address is the new text (an empty
            // address leaves the address as plain text).
            var expectedText = textBefore
            if case .pill? = target?.kind, !address.isEmpty, let i = blockIndex, let old = textBefore[i].range(of: target!.address) {
                expectedText[i].replaceSubrange(old, with: Run.linkAddress(address))
            }
            XCTAssertEqual(h.textView.document.blocks.map(\.text), expectedText, "seed \(seed) [\(address)]: visible text is the label (a pill: its new address)")
            XCTAssertEqual(NoteDocument(markdown: written).markdown(), written, "seed \(seed): stable")
            XCTAssertEqual(NewEditorHost(markdown: written).string, h.string, "seed \(seed) [\(address)] at \(location)+\(length): the buffer is what a reload shows\n\(source.debugDescription)\n\(written.debugDescription)")
            XCTAssertTrue(h.window.firstResponder === h.textView, "seed \(seed)")
            h.undo()
            XCTAssertEqual(h.markdown, source, "seed \(seed) [\(address)] at \(location)+\(length)")
            XCTAssertEqual(h.textView.undoManager?.canUndo, false, "seed \(seed): one step")
        }
    }
}

// MARK: Driving the field with real key events

extension NewEditorHost {
    /// Keys and characters go to whatever has the focus (the address field's editor), unlike `press` and `type`, which
    /// return the focus to the editor first.
    private func sendToFocus(chars: String, keyCode: UInt16) {
        let ts = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ts, windowNumber: window.windowNumber,
                                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ts + 0.01, windowNumber: window.windowNumber,
                                  context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        window.sendEvent(down)
        window.sendEvent(up)
    }

    func typeInField(_ text: String) { for ch in text { sendToFocus(chars: String(ch), keyCode: 0) } }

    enum FieldKey { case enter, escape }
    func pressInField(_ key: FieldKey) {
        switch key {
        case .enter: sendToFocus(chars: "\r", keyCode: 36)
        case .escape: sendToFocus(chars: "\u{1B}", keyCode: 53)
        }
    }

    /// Empties the field the way a user does: select all, Delete.
    func clearField() {
        (window.firstResponder as? NSTextView)?.selectAll(nil)
        sendToFocus(chars: "\u{7F}", keyCode: 51)
    }
}
