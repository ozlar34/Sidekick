import XCTest
import AppKit
import NoteDocument
@testable import Sidekick

/// New editor, ticket 08: URL pills, dividers, links and the inline marks (italic, underline, strikethrough, inline
/// code). Display, delete rules, Cmd+click, hover, `/hr`. Real key and mouse events in a real window.
@MainActor
final class NewEditorInlineTests: XCTestCase {

    private let fffc = "\u{FFFC}"
    private var seeds: Int { Int(ProcessInfo.processInfo.environment["SIDEKICK_FUZZ_SEEDS"] ?? "") ?? 40 }

    private func range(of s: String, in h: NewEditorHost) -> NSRange { NSString(string: h.string).range(of: s) }
    private func kinds(_ markdown: String) -> [BlockKind] { NoteDocument(markdown: markdown).blocks.map(\.kind) }
    private func attrs(_ h: NewEditorHost, _ word: String) -> [NSAttributedString.Key: Any] {
        h.textView.textStorage!.attributes(at: range(of: word, in: h).location, effectiveRange: nil)
    }
    private func ink(in rect: NSRect, of h: NewEditorHost) throws -> Int {
        h.textView.display()
        let rep = try XCTUnwrap(h.textView.bitmapImageRepForCachingDisplay(in: h.textView.bounds))
        h.textView.cacheDisplay(in: h.textView.bounds, to: rep)
        let background = rep.colorAt(x: Int(h.textView.bounds.maxX) - 5, y: 5)
        let scale = CGFloat(rep.pixelsWide) / h.textView.bounds.width
        var n = 0
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) where rep.colorAt(x: x, y: y) != background { n += 1 }
        }
        return n
    }

    // MARK: pills

    func testAPillIsOneCharacterAndOneCaretStep() {
        let source = "go https://example.com/a now\nnext\n"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.string, "go \(fffc) now\nnext\n")
        XCTAssertEqual(h.markdown, source, "no edit")
        h.select(3)
        let before = h.caret
        h.press(.right)
        XCTAssertEqual(h.location, 4, "one Right crosses the pill")
        XCTAssertGreaterThan(h.caret.minX, before.minX + 20, "the caret jumps over the drawn pill, not a character of the address")
        h.press(.left)
        XCTAssertEqual(h.location, 3)
        XCTAssertEqual(h.caret, before)
    }

    func testPillLooksLikeTodaysChip() throws {
        let h = NewEditorHost(markdown: "go https://www.example.com/a/ now [https://x.y](https://x.y) end\n")
        let targets = h.textView.hoverTargets
        XCTAssertEqual(targets.map(\.address), ["https://www.example.com/a/", "https://x.y"])
        let st = h.textView.textStorage!
        let attachments = (0..<st.length).compactMap { st.attribute(.attachment, at: $0, effectiveRange: nil) as? NotePillAttachment }
        XCTAssertEqual(attachments.map(\.displayText), ["example.com/a", "x.y"], "scheme, www. and trailing / are not shown")
        for t in targets {
            guard let r = t.rects.first else { XCTFail("no rect"); continue }
            XCTAssertGreaterThan(try ink(in: r, of: h), 30, "the pill is painted")
            XCTAssertGreaterThanOrEqual(r.width, 25)
        }
    }

    func testBackspaceAfterAPillRemovesExactlyThePill() {
        let source = "x https://e.co y\n"
        let h = NewEditorHost(markdown: source)
        h.select(3)
        h.press(.backspace)
        XCTAssertEqual(h.string, "x  y\n")
        XCTAssertEqual(h.savedMarkdown, "x  y\n")
        h.undo()
        XCTAssertEqual(h.markdown, source, "undo restores the exact bytes")
        XCTAssertEqual(h.string, "x \(fffc) y\n")
        XCTAssertEqual(h.textView.hoverTargets.map(\.address), ["https://e.co"], "the pill is back as a pill")
    }

    func testForwardDeleteBeforeAPillRemovesExactlyThePill() {
        let source = "x [https://e.co](https://e.co) y\n"
        let h = NewEditorHost(markdown: source)
        h.select(2)
        h.press(.forwardDelete)
        XCTAssertEqual(h.string, "x  y\n")
        XCTAssertEqual(h.savedMarkdown, "x  y\n")
        h.undo()
        XCTAssertEqual(h.markdown, source)
    }

    func testATypedCharacterNextToAPillStaysOutsideTheAddress() {
        for (source, loc) in [("go https://x.y\nrest\n", 4), ("go https://x.y\nrest\n", 3), ("[https://x.y](https://x.y)\n", 1)] {
            let h = NewEditorHost(markdown: source)
            h.select(loc)
            let drawn = h.caret
            h.type("Q")
            let at = NoteTextEngine.caretRect(in: h.textView, at: loc)
            XCTAssertEqual(at.minX, drawn.minX, accuracy: 0.5, "\(source) \(loc): appears where the caret was drawn")
            XCTAssertEqual(at.minY, drawn.minY, accuracy: 0.5)
            let saved = h.savedMarkdown ?? ""
            XCTAssertEqual(h.textView.hoverTargets.map(\.address), ["https://x.y"], "still one pill with the same address: \(saved)")
            let reloaded = NoteBuffer.attributed(for: NoteDocument(markdown: saved)).text.string
            XCTAssertEqual(reloaded, h.string, "the file reads back as what the view shows: \(saved)")
            XCTAssertEqual(h.string.contains("Q"), true)
        }
    }

    func testTextTypedAtTheEdgeOfALinkIsPlainAndInsideItStaysInTheLink() {
        let source = "see [lab](http://u) x\n"
        var h = NewEditorHost(markdown: source)
        h.select(range(of: "lab", in: h).upperBound)
        h.type("Q")
        XCTAssertEqual(h.savedMarkdown, "see [lab](http://u)Q x\n", "after the label: outside the link")
        h = NewEditorHost(markdown: source)
        h.select(range(of: "lab", in: h).location)
        h.type("Q")
        XCTAssertEqual(h.savedMarkdown, "see Q[lab](http://u) x\n", "before the label: outside the link")
        h = NewEditorHost(markdown: source)
        h.select(range(of: "lab", in: h).location + 1)
        h.type("Q")
        XCTAssertEqual(h.savedMarkdown, "see [lQab](http://u) x\n", "inside: part of the link")
    }

    // MARK: dividers

    func testADividerIsDrawnAsAHairlineAndTakesNoTextOrMarker() throws {
        let source = "above\n---\nbelow\n"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.string, "above\n\nbelow\n")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider", "p"])
        XCTAssertEqual(h.markdown, source)
        let dividers = NoteTextEngine.markers(in: h.textView).filter { $0.shape == .divider }
        XCTAssertEqual(dividers.count, 1)
        guard let line = dividers.first?.rect else { return XCTFail("no divider marker") }
        XCTAssertGreaterThan(line.width, 300, "across the text width")
        XCTAssertLessThanOrEqual(line.height, 2)
        XCTAssertGreaterThan(try ink(in: line.insetBy(dx: 0, dy: -1), of: h), 100, "the rule is painted")
        let above = h.caret.height
        XCTAssertGreaterThan(above, 0)
        XCTAssertEqual(NoteTextEngine.caretRect(in: h.textView, at: 6).midY, line.midY, accuracy: 3, "the line of the divider holds the rule")
    }

    func testBackspaceAfterADividerRemovesExactlyTheDivider() {
        let source = "a\n---\nb\n"
        let h = NewEditorHost(markdown: source)
        h.select(3)
        h.press(.backspace)
        XCTAssertEqual(h.string, "a\nb\n")
        XCTAssertEqual(h.savedMarkdown, "a\nb\n")
        XCTAssertEqual(h.location, 2)
        h.undo()
        XCTAssertEqual(h.markdown, source)
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider", "p"])
    }

    func testBackspaceOnTheDividerLineAndDeleteBeforeItRemoveIt() {
        let source = "a\n---\nb\n"
        var h = NewEditorHost(markdown: source)
        h.select(2)
        h.press(.backspace)
        XCTAssertEqual(h.savedMarkdown, "a\nb\n")
        h = NewEditorHost(markdown: source)
        h.select(1)
        h.press(.forwardDelete)
        XCTAssertEqual(h.savedMarkdown, "a\nb\n")
        XCTAssertEqual(h.location, 1)
        h.undo()
        XCTAssertEqual(h.markdown, source)
    }

    func testBackspaceInTheLineBelowATrailingDividerRemovesIt() {
        let h = NewEditorHost(markdown: "a\n---")
        h.select(h.length)
        h.press(.backspace)
        XCTAssertEqual(h.string, "a\n")
        XCTAssertEqual(kinds(h.savedMarkdown ?? ""), [.paragraph])
        h.undo()
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider"])
    }

    func testADividerAtTheEndAlwaysHasALineBelow() {
        let h = NewEditorHost(markdown: "a\n---")
        XCTAssertEqual(h.string, "a\n\n", "an editable line below the rule")
        XCTAssertEqual(h.markdown, "a\n---", "an unedited note keeps its bytes")
        h.select(1)
        h.press(.right); h.press(.right)
        XCTAssertEqual(h.location, 3, "Right reaches the line below")
        XCTAssertGreaterThan(h.caret.minY, NoteTextEngine.markers(in: h.textView).first { $0.shape == .divider }?.rect.maxY ?? .infinity)
        h.type("z")
        XCTAssertEqual(h.savedMarkdown, "a\n---\nz")
    }

    func testTypingOnTheDividerLineReplacesTheRuleWithTheText() {
        let h = NewEditorHost(markdown: "a\n---\nb\n")
        h.select(2)
        let drawn = h.caret
        h.type("Q")
        XCTAssertEqual(h.string, "a\nQ\nb\n")
        XCTAssertEqual(h.textView.blockKinds, ["p", "p", "p"])
        XCTAssertEqual(h.savedMarkdown, "a\nQ\nb\n")
        XCTAssertEqual(NoteTextEngine.caretRect(in: h.textView, at: 2).minY, drawn.minY, accuracy: 0.5, "the character is where the caret was drawn")
        h.undo()
        XCTAssertEqual(h.markdown, "a\n---\nb\n")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider", "p"])
    }

    func testEnterOnTheDividerLineAddsALineAboveAndKeepsTheDivider() {
        let h = NewEditorHost(markdown: "a\n---\nb\n")
        h.select(2)
        h.press(.enter)
        XCTAssertEqual(h.textView.blockKinds, ["p", "p", "divider", "p"])
        XCTAssertEqual(h.savedMarkdown, "a\n\n---\nb\n")
        XCTAssertEqual(h.location, 3)
    }

    // MARK: old case

    func testRightAcrossADividerOntoAnItalicLineNeedsNoExtraPress() {
        let h = NewEditorHost(markdown: "ab\n---\n*it* z\n")
        h.select(2)
        var carets = [h.caret]
        var seen: [Int] = []
        for _ in 0..<3 {
            h.press(.right)
            seen.append(h.location)
            XCTAssertNotEqual(h.caret, carets.last!, "the drawn caret moved")
            carets.append(h.caret)
        }
        XCTAssertEqual(seen, [3, 4, 5], "divider line, start of the italic line, past its first character")
        XCTAssertEqual(carets[2].minY, carets[3].minY, accuracy: 0.5)
    }

    // MARK: marks

    func testMarksLookAsToday() {
        let h = NewEditorHost(markdown: "plain *ital* <u>under</u> ~~gone~~ `mono` [lab](http://x.y/z) **bo** ***both***\n")
        func font(_ w: String) -> NSFont { attrs(h, w)[.font] as! NSFont }
        func traits(_ w: String) -> NSFontTraitMask { NSFontManager.shared.traits(of: font(w)) }
        XCTAssertTrue(traits("ital").contains(.italicFontMask))
        XCTAssertFalse(traits("plain").contains(.italicFontMask))
        XCTAssertEqual(attrs(h, "under")[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(attrs(h, "plain")[.underlineStyle])
        XCTAssertEqual(attrs(h, "gone")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(attrs(h, "plain")[.strikethroughStyle])
        XCTAssertTrue(traits("mono").contains(.fixedPitchFontMask))
        XCTAssertEqual(font("mono").pointSize, 13.5, accuracy: 0.01)
        XCTAssertEqual(attrs(h, "mono")[.backgroundColor] as? NSColor, .quaternaryLabelColor)
        XCTAssertNil(attrs(h, "plain")[.backgroundColor])
        XCTAssertEqual(attrs(h, "lab")[.foregroundColor] as? NSColor, .linkColor)
        XCTAssertEqual(attrs(h, "lab")[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(attrs(h, "lab")[.link], "AppKit's own link handling is not used: a plain click places the caret")
        XCTAssertTrue(traits("bo").contains(.boldFontMask))
        XCTAssertTrue(traits("both").contains(.boldFontMask) && traits("both").contains(.italicFontMask))
    }

    func testStrikethroughMarkAndCheckedItemCoexist() {
        let h = NewEditorHost(markdown: "- [x] aaa ~~bbb~~ ccc\n- [ ] ddd ~~eee~~\n")
        let struck = NSUnderlineStyle.single.rawValue
        XCTAssertEqual(attrs(h, "aaa")[.strikethroughStyle] as? Int, struck)
        XCTAssertEqual(attrs(h, "bbb")[.strikethroughStyle] as? Int, struck)
        XCTAssertNil(attrs(h, "ddd")[.strikethroughStyle], "an open item is not struck")
        XCTAssertEqual(attrs(h, "eee")[.strikethroughStyle] as? Int, struck, "the mark stays on a non-checked item")
        let box = NoteTextEngine.markers(in: h.textView).first { if case .checkbox(checked: true) = $0.shape { return true } else { return false } }?.rect ?? .zero
        h.click(at: NSPoint(x: box.midX, y: box.midY))
        XCTAssertNil(attrs(h, "aaa")[.strikethroughStyle], "unchecking removes the item's strike")
        XCTAssertEqual(attrs(h, "bbb")[.strikethroughStyle] as? Int, struck, "but not the mark's")
        XCTAssertNil(attrs(h, "ccc")[.strikethroughStyle])
    }

    func testBackspaceAndDeleteAtTheEdgeOfStyledTextRemoveOneVisibleCharacter() {
        let cases = ["x *ab* y", "x _ab_ y", "x <u>ab</u> y", "x ~~ab~~ y", "x `ab` y", "x [ab](http://u) y", "x **ab** y", "x __ab__ y", "x ***ab*** y"]
        for source in cases {
            var h = NewEditorHost(markdown: source)
            h.select(range(of: "ab", in: h).upperBound)
            h.press(.backspace)
            XCTAssertEqual(h.string, "x a y", source)
            XCTAssertEqual(h.savedMarkdown, source.replacingOccurrences(of: "ab", with: "a"), "Backspace at the end: \(source)")
            h = NewEditorHost(markdown: source)
            h.select(range(of: "ab", in: h).location)
            h.press(.forwardDelete)
            XCTAssertEqual(h.string, "x b y", source)
            XCTAssertEqual(h.savedMarkdown, source.replacingOccurrences(of: "ab", with: "b"), "Delete at the start: \(source)")
        }
    }

    // MARK: Cmd+click and hover

    /// The click helper must not depend on its queued mouse-up reaching NSTextView's tracking loop (it never does on the CI runner).
    func testClickReturnsAndPlacesTheCaretEvenWhenTheQueuedMouseUpNeverArrives() {
        let h = NewEditorHost(markdown: "first line\nsecond line\n")
        h.select(h.length)
        let start = Date()
        h.click(at: NSPoint(x: 20, y: h.caret.midY - 20), queueMouseUp: false)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "click returned by its own backstop (a hang is unbounded; 5 s leaves room for a loaded runner)")
        XCTAssertLessThan(h.location, h.length, "and placed the caret")
    }

    func testCmdClickOpensTheAddressAndAPlainClickPlacesTheCaret() {
        let h = NewEditorHost(markdown: "see https://e.co/p and [label](http://x.y/z) here\nsecond line\n")
        var opened: [String] = []
        h.textView.openURL = { opened.append($0.absoluteString) }
        let targets = h.textView.hoverTargets
        XCTAssertEqual(targets.map(\.address), ["https://e.co/p", "http://x.y/z"])
        guard targets.count == 2, targets.allSatisfy({ !$0.rects.isEmpty }) else { return }
        func center(_ t: NoteTextView.HoverTarget) -> NSPoint { NSPoint(x: t.rects[0].midX, y: t.rects[0].midY) }

        h.select(h.length)
        h.click(at: center(targets[0]))
        XCTAssertEqual(opened, [], "a plain click on a pill opens nothing")
        XCTAssertLessThan(h.location, h.length, "and places the caret")
        h.click(at: center(targets[1]))
        XCTAssertEqual(opened, [])
        XCTAssertTrue((6...28).contains(h.location), "caret placed in the link label, got \(h.location)")

        h.select(h.length)
        h.click(at: center(targets[0]), modifiers: .command)
        XCTAssertEqual(opened, ["https://e.co/p"])
        XCTAssertEqual(h.location, h.length, "Cmd+click leaves the caret alone")
        h.click(at: center(targets[1]), modifiers: .command)
        XCTAssertEqual(opened, ["https://e.co/p", "http://x.y/z"])
        h.click(at: NSPoint(x: 20, y: h.caret.midY + 40), modifiers: .command)
        XCTAssertEqual(opened.count, 2, "Cmd+click on plain text opens nothing")
    }

    func testCmdClickOnAPlainWwwAddressOpensItOverHttps() {
        let md = "go to www.google.com/maps, or swww.x.y here\n"
        let h = NewEditorHost(markdown: md)
        XCTAssertEqual(h.textView.markdown, md, "the address stays plain text: the file is unchanged")
        var opened: [String] = []
        h.textView.openURL = { opened.append($0.absoluteString) }
        let tv = h.textView
        func point(of text: String) -> NSPoint {
            let r = (tv.string as NSString).range(of: text)
            let g = tv.layoutManager!.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let rect = tv.layoutManager!.boundingRect(forGlyphRange: g, in: tv.textContainer!)
            return NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
        }
        h.select(0)
        h.click(at: point(of: "google"), modifiers: .command)
        XCTAssertEqual(opened, ["https://www.google.com/maps"], "trailing comma left out")
        XCTAssertEqual(h.location, 0, "Cmd+click leaves the caret alone")
        h.click(at: point(of: "google"))
        XCTAssertEqual(opened.count, 1, "a plain click opens nothing")
        h.click(at: point(of: "x.y"), modifiers: .command)
        XCTAssertEqual(h.textView.markdown, md)
        XCTAssertEqual(opened.count, 1, "www inside a word is not an address")
    }

    func testPlainTextAddressesAreFoundDrawnAsLinksAndLeaveTheFileAlone() {
        let md = "a google.com b xyz.org c abc.com.tr d melati.ge, e mail a@b.co\n"
            + "not README.md main.py e.g. v1.2.3 `code.com` [label](https://x.y) nor xgoogle\n"
        let h = NewEditorHost(markdown: md)
        let tv = h.textView
        XCTAssertEqual(tv.markdown, md, "the file is unchanged")
        let text = tv.string as NSString
        XCTAssertEqual(tv.foundLinks.map { text.substring(with: $0.range) },
                       ["google.com", "xyz.org", "abc.com.tr", "melati.ge", "a@b.co"])
        XCTAssertEqual(tv.foundLinks.map(\.address),
                       ["https://google.com", "https://xyz.org", "https://abc.com.tr", "https://melati.ge", "mailto:a@b.co"])

        let lm = tv.layoutManager!
        let g = text.range(of: "google.com")
        XCTAssertEqual(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: g.location, effectiveRange: nil) as? NSColor, .linkColor)
        XCTAssertNotNil(lm.temporaryAttribute(.underlineStyle, atCharacterIndex: g.location, effectiveRange: nil))
        XCTAssertNil(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: text.range(of: "README").location, effectiveRange: nil))

        let target = tv.hoverTargets.first { $0.address == "https://melati.ge" }
        XCTAssertNotNil(target, "found addresses get a pointing hand and tooltip like links")
        if let r = target?.rects.first {
            let p = NSPoint(x: r.midX, y: r.midY)
            XCTAssertEqual(tv.toolTip(at: p), "https://melati.ge")
            XCTAssertEqual(tv.cursor(at: p, modifiers: .command), NSCursor.pointingHand)
        }

        // Typing breaks the address; the drawing follows the text.
        h.select(g.location + 6)
        tv.insertText(" ", replacementRange: tv.selectedRange())
        XCTAssertFalse(tv.foundLinks.contains { $0.address == "https://google.com" })
        XCTAssertNil(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: g.location, effectiveRange: nil))
    }

    func testHoverShowsTheFullAddressAndAPointingHandOnlyWhileCommandIsDown() {
        let h = NewEditorHost(markdown: "see https://www.e.co/some/long/path/ and [label](mailto:a@b.c) here\nplain\n")
        let targets = h.textView.hoverTargets
        XCTAssertEqual(targets.count, 2)
        guard targets.count == 2, targets.allSatisfy({ !$0.rects.isEmpty }) else { return }
        for t in targets {
            let p = NSPoint(x: t.rects[0].midX, y: t.rects[0].midY)
            XCTAssertEqual(h.textView.toolTip(at: p), t.address)
            XCTAssertEqual(h.textView.cursor(at: p, modifiers: .command), NSCursor.pointingHand)
            XCTAssertNil(h.textView.cursor(at: p, modifiers: []), "without Command a click edits, so no hand")
        }
        XCTAssertEqual(targets[0].address, "https://www.e.co/some/long/path/", "the full address, not the chip text")
        let plain = NSPoint(x: 30, y: h.caret.midY + 30)
        XCTAssertNil(h.textView.toolTip(at: plain))
        XCTAssertNil(h.textView.cursor(at: plain, modifiers: .command))

        // A real mouse move sets the cursor: the hand with Command down, back to the I-beam without it.
        let tv = h.textView
        let onLink = NSPoint(x: targets[0].rects[0].midX, y: targets[0].rects[0].midY)
        func move(_ mods: NSEvent.ModifierFlags) {
            let e = NSEvent.mouseEvent(with: .mouseMoved, location: tv.convert(onLink, to: nil), modifierFlags: mods, timestamp: 0,
                                       windowNumber: tv.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            tv.mouseMoved(with: e)
        }
        move(.command)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        XCTAssertTrue(tv.showsLinkCursor)
        move([])
        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand)
        XCTAssertFalse(tv.showsLinkCursor)

        // Releasing Command without moving the mouse puts the I-beam back at once.
        move(.command)
        let up = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: tv.window!.windowNumber,
                                  context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
        tv.modifiersChanged(up)
        XCTAssertFalse(tv.showsLinkCursor, "the hand goes away on Command up")
        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand)
    }

    func testAWrappedLinkHasOneRectPerLine() {
        let words = (0..<40).map { "word\($0)" }.joined(separator: " ")
        let h = NewEditorHost(markdown: "[\(words)](http://x.y/z)\n", size: CGSize(width: 300, height: 600))
        let t = h.textView.hoverTargets
        XCTAssertEqual(t.count, 1)
        guard let first = t.first else { return }
        XCTAssertGreaterThan(first.rects.count, 2)
        for r in first.rects {
            XCTAssertEqual(h.textView.toolTip(at: NSPoint(x: r.midX, y: r.midY)), "http://x.y/z")
        }
    }

    // MARK: /hr

    func testSlashHrAndSlashDividerBecomeADividerWithALineBelow() {
        for trigger in ["/hr", "/divider"] {
            let h = NewEditorHost(markdown: "a\n")
            h.select(h.length)
            h.type(trigger)
            XCTAssertEqual(h.textView.blockKinds, ["p", "divider"], trigger)
            XCTAssertEqual(h.string, "a\n\n", "\(trigger): the line below the rule")
            XCTAssertEqual(h.location, 3, "the caret sits on the new line below")
            XCTAssertEqual(kinds(h.savedMarkdown ?? ""), [.paragraph, .divider])
            XCTAssertTrue((h.savedMarkdown ?? "").hasPrefix("a\n---"))
            h.type("z")
            XCTAssertEqual(h.savedMarkdown, "a\n---\nz\n", "typing continues below the rule")
        }
    }

    func testSlashHrInTheMiddleOfANote() {
        let h = NewEditorHost(markdown: "a\n\nb\n")
        h.select(2)
        h.type("/hr")
        XCTAssertEqual(h.textView.blockKinds, ["p", "divider", "p", "p"])
        XCTAssertEqual(h.savedMarkdown, "a\n---\n\nb\n")
        XCTAssertEqual(h.location, 3)
    }

    func testSlashHrOnlyFiresAloneOnAPlainLine() {
        for (source, typed) in [("x ", "/hr"), ("# ", "/hr"), ("- ", "/hr"), ("> ", "/divider"), ("", "/h")] {
            let h = NewEditorHost(markdown: source)
            h.select(h.length)
            h.type(typed)
            XCTAssertFalse(h.textView.blockKinds.contains("divider"), "\(source)\(typed)")
            XCTAssertTrue(h.string.hasSuffix(typed), "\(source)\(typed)")
        }
    }

    func testSlashHrNeedsTheCaretAtTheEndOfTheLine() {
        let h = NewEditorHost(markdown: "tail\n")
        h.select(0)
        h.type("/hr")
        XCTAssertEqual(h.string, "/hrtail\n")
        XCTAssertFalse(h.textView.blockKinds.contains("divider"))
    }

    func testSlashHrIsOneUndoStepThatBringsBackTheTypedText() {
        let h = NewEditorHost(markdown: "a\n")
        h.select(h.length)
        h.type("/hr")
        h.undo()
        XCTAssertEqual(h.markdown, "a\n/hr\n", "Cmd+Z gives back the literal characters")
        XCTAssertEqual(h.textView.blockKinds, ["p", "p"])
        h.undo()
        h.undo()
        h.undo()
        XCTAssertEqual(h.markdown, "a\n", "and further back, the original bytes")
    }

    // MARK: generated notes

    /// The caret at the end of a note whose last line is a heading, or holds a pill, sits where AppKit puts it.
    func testCaretAtTheEndOfALastLineThatIsAHeadingOrHoldsAPillMatchesAppKit() {
        for md in ["# head https://e.co", "go https://e.co", "# beta https://e.co/a x", "## h", "# snake_case", "a https://e.co https://e.co/b"] {
            let h = NewEditorHost(markdown: md)
            for loc in 0...h.length {
                h.select(loc)
                XCTAssertEqual(h.caret.origin.x, h.appKitCaretOrigin.x, accuracy: 1.5, "\(md.debugDescription) loc \(loc) x")
                XCTAssertEqual(h.caret.origin.y, h.appKitCaretOrigin.y, accuracy: 1.5, "\(md.debugDescription) loc \(loc) y")
            }
        }
    }

    /// Inputs of generated seeds that once failed, kept as plain examples (seeds 138, 186, 192, 248: type, then undo).
    func testUndoOfATypedCharacterRestoresTheExactBytesForOnceFailingNotes() {
        let cases: [(String, Double)] = [
            ("a*b **42** *42* https://e.co 42\nbeta **gamma** caf\u{e9} gamma", 0.3),
            ("- [x] snake_case caf\u{e9} x\n---", 1.0),
            ("gamma gamma https://example.com/alpha 42\n42 beta https://example.com/x a*b snake_case\n---\n\n", 0.6),
            ("# gamma beta\nx https://example.com/a*b x \u{65e5}\u{672c}\n---\n", 0.6),
        ]
        for (source, fraction) in cases {
            let h = NewEditorHost(markdown: source)
            h.select(Int(Double(h.length) * fraction))
            h.type("Z")
            h.undo()
            XCTAssertEqual(h.markdown, source, "\(source.debugDescription) at \(fraction)")
        }
    }

    /// Seed 217, location 1: Backspace after the first character of a note that opens with a rule, then undo.
    func testBackspaceThenUndoRestoresTheExactBytesForOnceFailingNote() {
        let source = "***\n9. caf\u{e9} \u{65e5}\u{672c}\n\u{65e5}\u{672c} \u{65e5}\u{672c} beta 42\n- \n- a*b gamma gamma"
        let h = NewEditorHost(markdown: source)
        h.select(1)
        h.press(.backspace)
        h.undo()
        XCTAssertEqual(h.markdown, source)
    }

    /// Seed 12 and its kin: removing the last line break of a note whose last line is a heading, list item, checklist item
    /// or quote, then undo, gives back the exact bytes (the empty tail line has no kind).
    func testUndoOfRemovingTheLastLineBreakGivesBackTheExactBytes() {
        for source in ["### caf\u{e9} caf\u{e9} alpha\n", "- alpha beta\n", "3. alpha beta\n", "- [ ] alpha beta\n", "- [x] alpha beta\n", "> alpha beta\n"] {
            let end = NoteBuffer.attributed(for: NoteDocument(markdown: source)).text.length - 1   // before the last line break
            for (key, at) in [(NewEditorHost.Key.forwardDelete, end), (.backspace, end + 1)] {
                let h = NewEditorHost(markdown: source)
                h.select(at)
                h.press(key)
                h.undo()
                XCTAssertEqual(h.markdown, source, "\(source.debugDescription) \(key) at \(at)")
            }
        }
    }

    /// SIDEKICK_ONLY_SEEDS=138,186 re-runs just those seeds.
    private var seedList: [UInt64] {
        if let only = ProcessInfo.processInfo.environment["SIDEKICK_ONLY_SEEDS"] { return only.split(separator: ",").compactMap { UInt64($0) } }
        return Array(1...UInt64(seeds))
    }

    private func note(_ seed: UInt64) -> String { var gen = NewEditorNoteGenerator(seed: seed); return gen.markdown() }

    func testWhatTheViewShowsIsWhatTheFileHoldsAfterAnEditAnywhere() {
        for seed in seedList {
            let source = note(seed)
            for fraction in [0.0, 0.3, 0.6, 1.0] {
                let h = NewEditorHost(markdown: source)
                h.select(Int(Double(h.length) * fraction))
                h.type("Z")
                let saved = h.savedMarkdown ?? ""
                // (A final line break the file gained or lost is not text: the last line is the same either way.)
                func trimmed(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }
                let reread = NoteBuffer.attributed(for: NoteDocument(markdown: saved)).text.string
                XCTAssertEqual(trimmed(reread), trimmed(h.string), "seed \(seed) at \(fraction): the file reads back as what the view shows")
                h.undo()
                XCTAssertEqual(h.markdown, source, "seed \(seed) at \(fraction): undo restores the exact bytes")
            }
        }
    }

    /// Every location, both keys. Backspace removes the character before the caret; at the start of a line it either joins
    /// the line to the one above (one line break), removes a divider's line (one line break), or, on a list item, heading
    /// or quote, just clears the kind (nothing is removed and the line becomes a paragraph). Forward Delete removes the
    /// character after the caret, a divider's line included, and nothing at the end of the note. Undo restores the bytes.
    func testBackspaceAndDeleteRemoveExactlyOneUnitOnGeneratedNotes() {
        // Every location and both keys cost about 30 times a sampled run, so this test takes at most 15 seeds (25 took almost 6 minutes, 100 over 12).
        for seed in seedList.prefix(15) {
            let source = note(seed)
            // One window per seed, reloaded (the editor's own reload: text, undo history and selection reset) for every location and key.
            // A window per location and key took 120 s and 17 GB: each one keeps its backing store until the run ends.
            // (undo waits 1 ms, not 20: the run loop only has to turn once to close the undo group; the two waits were 95% of the run.)
            let h = NewEditorHost(markdown: source)
            let sourceMarkdown = h.markdown
            let sourceLength = h.length
            for loc in 0...sourceLength {
                for key in [NewEditorHost.Key.backspace, .forwardDelete] {
                    h.textView.load(markdown: sourceMarkdown)
                    let original = h.string, ns = original as NSString
                    let originalMarkdown = h.markdown
                    func kind(_ at: Int, _ host: NewEditorHost) -> BlockKind {
                        if host.length == 0 { return .paragraph }
                        return NoteBuffer.kind(fromAttribute: host.textView.textStorage?.attribute(.noteBlockKind, at: min(at, max(host.length - 1, 0)), effectiveRange: nil))
                    }
                    let kindBefore = kind(loc, h)
                    h.select(loc)
                    h.press(key)
                    let removed = ns.length - h.length
                    let tag = "seed \(seed) loc \(loc) \(key)"
                    switch key {
                    case .backspace:
                        if loc == 0 { XCTAssertEqual(removed, kindBefore == .divider ? 1 : 0, "\(tag): at the very start only a divider's line goes") }
                        else if ns.character(at: loc - 1) == 0x0A {
                            if removed == 0 {
                                XCTAssertNotEqual(kindBefore, .paragraph, "\(tag): a line start that removed nothing must have cleared a kind")
                                XCTAssertEqual(kind(loc, h), .paragraph, "\(tag): the kind is cleared")
                            } else { XCTAssertEqual(removed, 1, "\(tag): a join removes one line break") }
                        } else { XCTAssertEqual(removed, 1, "\(tag): removed \(removed) units") }
                    default:
                        XCTAssertEqual(removed, loc < ns.length ? 1 : 0, "\(tag): removed \(removed) units")
                    }
                    h.undo(wait: 0.001)
                    XCTAssertEqual(h.string, original, tag)
                    XCTAssertEqual(h.markdown, originalMarkdown, "\(tag): undo restores the exact bytes")
                }
            }
        }
    }
}
