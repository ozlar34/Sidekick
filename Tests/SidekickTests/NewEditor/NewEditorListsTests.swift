import XCTest
import AppKit
@testable import Sidekick

/// New editor, ticket 07: bullet items, numbered items, checklist items and quotes. Drawn markers, the two
/// structural key rules (Backspace at block start, Enter in lists), the checkbox click and the empty last
/// paragraph. Real key and mouse events in a real window.
@MainActor
final class NewEditorListsTests: XCTestCase {

    private func range(of s: String, in h: NewEditorHost) -> NSRange { NSString(string: h.string).range(of: s) }

    // MARK: display

    func testBlocksShowNoMarkersInTextAndMarkersAreDrawnFromTheKind() {
        let source = "- a\n1. b\n- [ ] c\n- [x] d\n> e\n"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.string, "a\nb\nc\nd\ne\n")
        XCTAssertEqual(h.textView.blockKinds, ["bullet", "numbered", "todo", "checked", "quote"])
        XCTAssertEqual(h.markdown, source)
        let shapes = NoteTextEngine.markers(in: h.textView).map(\.shape)
        XCTAssertEqual(shapes, [.bullet, .number("1."), .checkbox(checked: false), .checkbox(checked: true)])
        // Not caret positions: Right walks the 10 buffer characters and never rests anywhere else.
        h.select(0)
        var seen = [0]
        while h.location < h.length { h.press(.right); seen.append(h.location) }
        XCTAssertEqual(seen, Array(0...10))
    }

    func testDrawnMarkersPaintPixels() throws {
        let h = NewEditorHost(markdown: "- a\n1. b\n- [ ] c\n- [x] d\n")
        h.textView.display()
        let rep = try XCTUnwrap(h.textView.bitmapImageRepForCachingDisplay(in: h.textView.bounds))
        h.textView.cacheDisplay(in: h.textView.bounds, to: rep)
        let background = rep.colorAt(x: Int(h.textView.bounds.maxX) - 5, y: 5)
        let scale = CGFloat(rep.pixelsWide) / h.textView.bounds.width
        for m in NoteTextEngine.markers(in: h.textView) {
            var ink = 0
            for x in Int(m.rect.minX * scale)..<Int(m.rect.maxX * scale) {
                for y in Int(m.rect.minY * scale)..<Int(m.rect.maxY * scale) where rep.colorAt(x: x, y: y) != background { ink += 1 }
            }
            XCTAssertGreaterThan(ink, 0, "marker \(m.shape) at \(m.start) painted nothing")
        }
    }

    func testTodaysLookCheckedDimmedAndStruckQuoteIndentedItalicDimmed() {
        let h = NewEditorHost(markdown: "- [ ] open\n- [x] done\n> quoted\nplain\n- item\n")
        let st = h.textView.textStorage!
        func attrs(_ word: String) -> [NSAttributedString.Key: Any] { st.attributes(at: range(of: word, in: h).location, effectiveRange: nil) }
        XCTAssertNil(attrs("open")[.strikethroughStyle])
        XCTAssertEqual(attrs("open")[.foregroundColor] as? NSColor, .textColor)
        XCTAssertEqual(attrs("done")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(attrs("done")[.foregroundColor] as? NSColor, .tertiaryLabelColor)
        XCTAssertEqual(attrs("quoted")[.foregroundColor] as? NSColor, .secondaryLabelColor)
        let quoteFont = attrs("quoted")[.font] as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: quoteFont).contains(.italicFontMask))
        XCTAssertNil(attrs("plain")[.strikethroughStyle])
        let plainFont = attrs("plain")[.font] as! NSFont
        XCTAssertFalse(NSFontManager.shared.traits(of: plainFont).contains(.italicFontMask))
        // Text starts right of the marker, wrapped lines hang at the same indent; quotes are indented as a block.
        let boxes = NoteTextEngine.markers(in: h.textView)
        let openX = NoteTextEngine.caretRect(in: h.textView, at: range(of: "open", in: h).location).minX
        XCTAssertGreaterThanOrEqual(openX, boxes[0].rect.maxX + 3, "text clear of the checkbox")
        let quoteX = NoteTextEngine.caretRect(in: h.textView, at: range(of: "quoted", in: h).location).minX
        let plainX = NoteTextEngine.caretRect(in: h.textView, at: range(of: "plain", in: h).location).minX
        XCTAssertEqual(quoteX - plainX, 18, accuracy: 0.5)
        let itemX = NoteTextEngine.caretRect(in: h.textView, at: range(of: "item", in: h).location).minX
        XCTAssertEqual(itemX - plainX, 11, accuracy: 0.5)
        for p in h.textView.textStorage!.string.components(separatedBy: "\n") where p == "open" {
            let style = st.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
            XCTAssertEqual(style.headIndent, style.firstLineHeadIndent, "wrapped lines hang under the text")
        }
    }

    private func numbers(_ h: NewEditorHost) -> [String] {
        NoteTextEngine.markers(in: h.textView).compactMap { m -> String? in
            if case .number(let n) = m.shape { return n } else { return nil }
        }
    }

    func testDrawnNumbersAreTheFilesNumbersWithTheirDelimiter() {
        XCTAssertEqual(numbers(NewEditorHost(markdown: "3. a\n4. b\n1. c\n\n- x\n1. d\n")), ["3.", "4.", "1.", "1."])
        XCTAssertEqual(numbers(NewEditorHost(markdown: "3) a\n  10. b\n")), ["3)", "10."])
    }

    func testTheNextItemGetsTheNextNumberInTheFileAndOnScreen() {
        let h = NewEditorHost(markdown: "4. a\n5. b")
        h.select(1)
        h.press(.enter)
        XCTAssertEqual(h.savedMarkdown, "4. a\n5. \n5. b")
        XCTAssertEqual(numbers(h), ["4.", "5.", "5."], "the screen shows what the file says")
        let started = NewEditorHost(markdown: "1. a")
        started.select(1)
        started.press(.enter)
        started.type("b")
        XCTAssertEqual(started.savedMarkdown, "1. a\n2. b")
        let paren = NewEditorHost(markdown: "3) x")
        paren.select(1)
        paren.press(.enter)
        XCTAssertEqual(paren.savedMarkdown, "3) x\n4) ")
        XCTAssertEqual(numbers(paren), ["3)", "4)"])
    }

    func testTheGapBetweenANumberAndItsTextDoesNotShrinkWithMoreDigits() {
        let h = NewEditorHost(markdown: "9. a\n10. b\n100. c\n1000. d\n")
        let markers = NoteTextEngine.markers(in: h.textView).filter { if case .number = $0.shape { return true } else { return false } }
        XCTAssertEqual(markers.count, 4)
        let gaps = markers.map { m in NoteTextEngine.caretRect(in: h.textView, at: m.start).minX - m.rect.maxX }
        XCTAssertGreaterThan(gaps[0], 2, "a visible gap for one digit")
        for (i, g) in gaps.enumerated() { XCTAssertGreaterThanOrEqual(g, gaps[0] - 0.5, "gap of item \(i) is \(g), one digit has \(gaps[0])") }
        // Typing in the item must not touch the gutter either.
        h.select(markers[1].start + 1)
        h.type("Z")
        let m1 = NoteTextEngine.markers(in: h.textView)[1]
        XCTAssertGreaterThanOrEqual(NoteTextEngine.caretRect(in: h.textView, at: m1.start).minX - m1.rect.maxX, gaps[0] - 0.5)
    }

    // MARK: Enter

    func testEnterContinuesLists() {
        let cases: [(source: String, caretAfter: String, expected: String, kinds: [String])] = [
            ("- a", "a", "- a\n- b", ["bullet", "bullet"]),
            ("- a\nrest\n", "a", "- a\n- b\nrest\n", ["bullet", "bullet", "p"]),
            ("1. a", "a", "1. a\n2. b", ["numbered", "numbered"]),
            ("7. a\n8. z\n", "a", "7. a\n8. b\n8. z\n", ["numbered", "numbered", "numbered"]),
            ("3) x\n", "x", "3) x\n4) b\n", ["numbered", "numbered"]),
            ("- [ ] a", "a", "- [ ] a\n- [ ] b", ["todo", "todo"]),
            ("- [x] a\n", "a", "- [x] a\n- [ ] b\n", ["checked", "todo"]),
        ]
        for c in cases {
            let h = NewEditorHost(markdown: c.source)
            h.select(range(of: c.caretAfter, in: h).upperBound)
            h.press(.enter)
            h.type("b")
            XCTAssertEqual(h.textView.blockKinds, c.kinds, c.source)
            XCTAssertEqual(h.savedMarkdown, c.expected, c.source)
        }
    }

    func testEnterInTheMiddleOfAnItemSplitsIt() {
        let h = NewEditorHost(markdown: "- [x] abcd\n")
        h.select(range(of: "ab", in: h).upperBound)
        h.press(.enter)
        XCTAssertEqual(h.string, "ab\ncd\n")
        XCTAssertEqual(h.textView.blockKinds, ["checked", "todo"], "the second half is a new, unchecked item")
        XCTAssertEqual(h.savedMarkdown, "- [x] ab\n- [ ] cd\n")
    }

    func testEnterOnAnEmptyItemEndsTheList() {
        for (source, kind, expected) in [("- a\n- \n", "bullet", "- a\n\n"), ("- a\n- \nrest\n", "bullet", "- a\n\nrest\n"),
                                         ("1. a\n2. \nrest", "numbered", "1. a\n\nrest"), ("- [ ] a\n- [ ] \nrest\n", "todo", "- [ ] a\n\nrest\n")] {
            let h = NewEditorHost(markdown: source)
            let emptyAt = (h.string as NSString).range(of: "\n").upperBound   // start of the second paragraph
            h.select(emptyAt)
            XCTAssertEqual(h.textView.blockKinds[1], kind, source)
            h.press(.enter)
            XCTAssertEqual(h.textView.blockKinds[1], "p", "kind cleared: \(source)")
            XCTAssertEqual(h.savedMarkdown, expected, source)
            XCTAssertEqual(h.location, emptyAt, "no line was inserted: \(source)")
        }
    }

    func testEnterAtTheEndOfAQuoteStartsAParagraph() {
        let h = NewEditorHost(markdown: "> said\n")
        h.select(range(of: "said", in: h).upperBound)
        h.press(.enter)
        h.type("next")
        XCTAssertEqual(h.textView.blockKinds, ["quote", "p"])
        XCTAssertEqual(h.savedMarkdown, "> said\nnext\n")
    }

    func testEachEnterRuleIsOneUndoStep() {
        // (note, caret offset in the buffer text, markdown after Enter)
        let cases: [(String, Int, String)] = [
            ("- a\n", 1, "- a\n- \n"), ("- [x] a\n", 1, "- [x] a\n- [ ] \n"), ("1. a\n2. b\n", 1, "1. a\n2. \n2. b\n"),
            ("- a\n- \n", 2, "- a\n\n"), ("- [ ] a\n- [ ] ", 2, "- [ ] a\n"), ("1. a\n2. ", 2, "1. a\n"), ("> q\n", 1, "> q\n\n"),
            ("- [x] ab\n", 1, "- [x] a\n- [ ] b\n"), ("- a", 1, "- a\n- "),
        ]
        for (source, caret, after) in cases {
            let h = NewEditorHost(markdown: source)
            h.select(caret)
            h.endUndoGroup()
            h.textView.undoManager?.removeAllActions()
            h.press(.enter)
            h.endUndoGroup()
            XCTAssertEqual(h.markdown, after, source)
            h.undo()
            XCTAssertEqual(h.markdown, source, "one undo gives back the exact bytes: \(source.debugDescription)")
            XCTAssertFalse(h.textView.undoManager?.canUndo ?? false, "Enter was a single undo step: \(source)")
        }
    }

    // MARK: Backspace at the start of a marked block

    func testBackspaceAtBlockStartClearsTheKindThenJoinsTheLineAbove() {
        for (source, word, cleared, joined) in [
            ("x\n- a\n", "a", "x\na\n", "xa\n"), ("x\n1. a\n", "a", "x\na\n", "xa\n"), ("x\n- [ ] a\n", "a", "x\na\n", "xa\n"),
            ("x\n- [x] a\n", "a", "x\na\n", "xa\n"), ("x\n> a\n", "a", "x\na\n", "xa\n"), ("x\n## a\n", "a", "x\na\n", "xa\n"),
        ] {
            let h = NewEditorHost(markdown: source)
            h.select(range(of: word, in: h).location)
            h.press(.backspace)
            XCTAssertEqual(h.savedMarkdown, cleared, "first press clears the kind: \(source)")
            XCTAssertEqual(h.string, "x\na\n")
            XCTAssertEqual(h.location, 2)
            h.press(.backspace)
            XCTAssertEqual(h.savedMarkdown, joined, "second press joins: \(source)")
        }
    }

    func testBackspaceOnTheFirstLineAndOnAnEmptyItem() {
        let first = NewEditorHost(markdown: "- a\nb")
        first.select(0)
        first.press(.backspace)
        XCTAssertEqual(first.savedMarkdown, "a\nb")
        first.press(.backspace)
        XCTAssertEqual(first.markdown, "a\nb", "nothing above to join")
        let empty = NewEditorHost(markdown: "x\n- [ ] \ny")
        empty.select(2)
        empty.press(.backspace)
        XCTAssertEqual(empty.savedMarkdown, "x\n\ny")
        XCTAssertEqual(empty.textView.blockKinds, ["p", "p", "p"])
    }

    func testBackspaceInTheMiddleOfAnItemIsPlainDelete() {
        let h = NewEditorHost(markdown: "- [ ] abc\n")
        h.select(range(of: "ab", in: h).upperBound)
        h.press(.backspace)
        XCTAssertEqual(h.savedMarkdown, "- [ ] ac\n")
    }

    func testTheLineAboveKeepsItsKindWhenJoinedIntoAndDeleteForwardJoinsTheSame() {
        let h = NewEditorHost(markdown: "- x\ny\n")
        h.select(range(of: "y", in: h).location)
        h.press(.backspace)
        XCTAssertEqual(h.savedMarkdown, "- xy\n", "the item absorbs the plain line")
        let d = NewEditorHost(markdown: "- x\ny\n")
        d.select(1)
        d.press(.forwardDelete)
        XCTAssertEqual(d.savedMarkdown, "- xy\n", "Delete at the end of an item joins the next line into it")
    }

    func testBackspaceAtBlockStartIsOneUndoStep() {
        for source in ["x\n- a\n", "x\n- [x] a\n", "x\n> a\n", "x\r\n- a", "- [ ] a\n- [ ] "] {
            let h = NewEditorHost(markdown: source)
            h.select(source.hasSuffix("- [ ] ") ? h.length : range(of: "a", in: h).location)
            h.endUndoGroup()
            h.textView.undoManager?.removeAllActions()
            h.press(.backspace)
            h.undo()
            XCTAssertEqual(h.markdown, source, "exact bytes: \(source.debugDescription)")
            XCTAssertFalse(h.textView.undoManager?.canUndo ?? false, source)
        }
    }

    // MARK: checkbox click

    private func box(_ h: NewEditorHost, _ index: Int = 0) -> NSRect {
        let boxes = NoteTextEngine.markers(in: h.textView).filter { if case .checkbox = $0.shape { return true } else { return false } }
        return boxes.indices.contains(index) ? boxes[index].rect : NSRect(x: -100, y: -100, width: 1, height: 1)   // off the view: the click does nothing
    }

    private func changedBytes(_ a: String, _ b: String) -> Int {
        zip(Array(a.utf8), Array(b.utf8)).filter { $0 != $1 }.count + abs(a.utf8.count - b.utf8.count)
    }

    func testClickOnTheBoxTogglesAndChangesOnlyTheBracketCharacter() {
        let source = "# T\r\n- [ ] a **b**\r\n- [X] c\r\n- [ ] d"
        let h = NewEditorHost(markdown: source)
        let r0 = box(h, 0)
        h.click(at: NSPoint(x: r0.midX, y: r0.midY))
        XCTAssertEqual(h.savedMarkdown, "# T\r\n- [x] a **b**\r\n- [X] c\r\n- [ ] d")
        XCTAssertEqual(changedBytes(source, h.savedMarkdown ?? ""), 1)
        XCTAssertEqual(h.textView.blockKinds, ["h1", "checked", "checked", "todo"])
        let r1 = box(h, 1)
        h.click(at: NSPoint(x: r1.midX, y: r1.midY))
        XCTAssertEqual(h.savedMarkdown, "# T\r\n- [x] a **b**\r\n- [ ] c\r\n- [ ] d")
        h.click(at: NSPoint(x: r1.midX, y: r1.midY))
        XCTAssertEqual(h.savedMarkdown, "# T\r\n- [x] a **b**\r\n- [X] c\r\n- [ ] d", "checking again restores the file's X")
        let strike = h.textView.textStorage!.attribute(.strikethroughStyle, at: range(of: "a", in: h).location + 0, effectiveRange: nil)
        XCTAssertNotNil(strike, "the toggled item is drawn struck through at once")
    }

    func testClickToggleIsOneUndoStepAndKeepsTheCaret() {
        let h = NewEditorHost(markdown: "- [ ] a\n- [ ] b\n")
        h.select(5)
        h.endUndoGroup()
        h.textView.undoManager?.removeAllActions()
        let r = box(h, 1)
        h.click(at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(h.markdown, "- [ ] a\n- [x] b\n")
        h.undo()
        XCTAssertEqual(h.markdown, "- [ ] a\n- [ ] b\n")
        XCTAssertFalse(h.textView.undoManager?.canUndo ?? false)
        XCTAssertEqual(h.textView.blockKinds, ["todo", "todo"])
    }

    func testClickOutsideTheBoxDoesNotToggle() {
        let source = "- [ ] item\n- [x] done\n"
        let h = NewEditorHost(markdown: source)
        let r = box(h, 0)
        let lineY = r.midY
        // Left margin (inside the text container padding), between box and text, on the text, right side, below the box.
        for point in [NSPoint(x: 3, y: lineY), NSPoint(x: r.minX - 6, y: lineY), NSPoint(x: r.maxX + 4, y: lineY),
                      NSPoint(x: r.midX, y: r.maxY + 6), NSPoint(x: h.textView.bounds.maxX - 20, y: lineY)] {
            h.click(at: point)
            XCTAssertEqual(h.markdown, source, "click at \(point) must not toggle")
            XCTAssertNil(h.savedMarkdown, "no edit at \(point)")
        }
        // A click on the text places the caret there instead.
        let text = NoteTextEngine.caretRect(in: h.textView, at: range(of: "item", in: h).location + 2)
        h.click(at: NSPoint(x: text.minX - 1, y: text.midY))
        XCTAssertEqual(h.location, range(of: "item", in: h).location + 2)
    }

    // MARK: empty last paragraph

    func testEmptyChecklistItemAtTheEndOfANote() throws {
        let source = "- [ ] a\n- [ ] "
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.string, "a\n")
        let boxes = NoteTextEngine.markers(in: h.textView).filter { if case .checkbox = $0.shape { return true } else { return false } }
        XCTAssertEqual(boxes.map(\.start), [0, 2], "the empty last item shows its checkbox")
        let last = try XCTUnwrap(boxes.last)
        XCTAssertGreaterThan(last.rect.height, 0)
        XCTAssertGreaterThan(last.rect.minY, boxes[0].rect.minY)
        XCTAssertEqual(h.markdown, source, "unedited, byte for byte")
        // The caret sits at the text column of the empty item, right of its box.
        h.select(2)
        XCTAssertGreaterThanOrEqual(h.caret.minX, last.rect.maxX + 3)
        h.type("x")
        XCTAssertEqual(h.savedMarkdown, "- [ ] a\n- [ ] x")
        XCTAssertEqual(h.textView.blockKinds, ["todo", "todo"])
        h.press(.backspace)   // remove x again: the item is empty again and keeps its kind
        XCTAssertEqual(h.savedMarkdown, "- [ ] a\n- [ ] ")
        XCTAssertEqual(h.textView.blockKinds, ["todo", "todo"])
    }

    func testEnterAtTheEndOfTheNoteMakesAnEmptyLastItemThatSaves() {
        for (source, typed, kinds) in [("- [ ] a", "- [ ] ", ["todo", "todo"]), ("- a", "- ", ["bullet", "bullet"]), ("1. a", "2. ", ["numbered", "numbered"])] {
            let h = NewEditorHost(markdown: source)
            h.select(h.length)
            h.press(.enter)
            XCTAssertEqual(h.savedMarkdown, source + "\n" + typed, source)
            XCTAssertEqual(h.textView.blockKinds, kinds)
            XCTAssertEqual(NoteTextEngine.markers(in: h.textView).last?.start, h.length, "marker of the empty last item: \(source)")
            h.press(.enter)   // Enter on the empty last item ends the list
            XCTAssertEqual(h.savedMarkdown, source, "back to the note's own bytes: \(source)")
            XCTAssertEqual(h.textView.blockKinds, [kinds[0]])
            h.type("after")
            XCTAssertEqual(h.savedMarkdown, source + "\nafter", source)
        }
    }

    func testBackspaceOnTheEmptyLastItemClearsItThenJoins() {
        let h = NewEditorHost(markdown: "- [ ] a\n- [ ] ")
        h.select(h.length)
        h.press(.backspace)
        XCTAssertEqual(h.savedMarkdown, "- [ ] a\n")
        XCTAssertEqual(NoteTextEngine.markers(in: h.textView).count, 1)
        h.press(.backspace)
        XCTAssertEqual(h.string, "a", "the empty last line is gone")
        XCTAssertEqual(h.location, 1)
    }

    func testEmptyLastItemIsOneUndoStepAndCheckboxClickTogglesIt() {
        let h = NewEditorHost(markdown: "- [ ] a\n- [ ] ")
        let r = box(h, 1)
        h.endUndoGroup()
        h.textView.undoManager?.removeAllActions()
        h.click(at: NSPoint(x: r.midX, y: r.midY))
        XCTAssertEqual(h.savedMarkdown, "- [ ] a\n- [x] ")
        h.undo()
        XCTAssertEqual(h.markdown, "- [ ] a\n- [ ] ")
        h.select(h.length)
        h.press(.backspace)   // clears the kind
        XCTAssertEqual(h.textView.blockKinds, ["todo"])
        h.undo()
        XCTAssertEqual(h.textView.blockKinds, ["todo", "todo"])
        XCTAssertEqual(h.markdown, "- [ ] a\n- [ ] ", "undo gives back the exact original bytes (no added line break)")
    }

    // MARK: named old case

    func testRightFromTheStartReachesTheEndPastAChecklistLineThatStartsBold() {
        let h = NewEditorHost(markdown: "ab\n- [ ] **bold** x\ncd")
        h.select(0)
        var last = 0
        while h.location < h.length {
            h.press(.right)
            XCTAssertGreaterThan(h.location, last, "Right did not move from \(last)")
            last = h.location
        }
        XCTAssertEqual(h.location, h.length)
        XCTAssertEqual(h.string, "ab\nbold x\ncd")
    }
}
