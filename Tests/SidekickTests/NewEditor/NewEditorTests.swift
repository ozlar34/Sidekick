import XCTest
import AppKit
@testable import Sidekick

/// New editor, first path: paragraphs, headings and bold. Seam 2 of the spec: a real window, real
/// key events, geometry read from the view. Budget via SIDEKICK_FUZZ_SEEDS (default 40).
@MainActor
final class NewEditorTests: XCTestCase {

    private var seeds: Int { Int(ProcessInfo.processInfo.environment["SIDEKICK_FUZZ_SEEDS"] ?? "") ?? 40 }

    // MARK: switch

    func testSwitchIsOffByDefault() {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains(NewEditorSwitch.launchArgument))
        XCTAssertFalse(Defaults.store.bool(forKey: NewEditorSwitch.defaultsKey))
        XCTAssertFalse(NewEditorSwitch.isOn)
    }

    // MARK: open, show, type, save

    func testOpenShowsNoMarkersAndKindsAsAttributes() {
        let h = NewEditorHost(markdown: "# Title\n\nHello **bold** world\n## Sub\n")
        XCTAssertEqual(h.string, "Title\n\nHello bold world\nSub\n")
        XCTAssertEqual(h.textView.blockKinds, ["h1", "p", "p", "h2"])
        let bold = NSString(string: h.string).range(of: "bold")
        let font = h.textView.textStorage!.attribute(.font, at: bold.location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let heading = h.textView.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertGreaterThan(heading.pointSize, 20)
        XCTAssertEqual(h.markdown, "# Title\n\nHello **bold** world\n## Sub\n")
    }

    func testTypingSavesAndEditsOnlyTheEditedBlock() {
        let source = "# Title\r\n\r\nHello __bold__ world\r\nlast line"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.markdown, source, "no edit: byte for byte")
        h.select(NSString(string: h.string).range(of: "world").upperBound)
        h.type("!")
        XCTAssertEqual(h.savedMarkdown, "# Title\r\n\r\nHello __bold__ world!\r\nlast line")
        h.select(5)
        h.type("s")
        XCTAssertEqual(h.savedMarkdown, "# Titles\r\n\r\nHello __bold__ world!\r\nlast line")
        // Typing inside bold stays bold and keeps the file's delimiter.
        h.select(NSString(string: h.string).range(of: "bold").location + 2)
        h.type("Z")
        XCTAssertEqual(h.savedMarkdown, "# Titles\r\n\r\nHello __boZld__ world!\r\nlast line")
    }

    func testSavedFileReadsBackAsWhatTheViewShows() {
        let h = NewEditorHost(markdown: "plain\n")
        h.select(5)
        h.type("*x_ #")
        let saved = h.savedMarkdown!
        let reopened = NewEditorHost(markdown: saved)
        XCTAssertEqual(reopened.string, h.string)
        XCTAssertEqual(reopened.markdown, saved)
    }

    func testEmptyNoteAcceptsTyping() {
        let h = NewEditorHost(markdown: "")
        h.type("hi")
        h.press(.enter)
        h.type("there")
        XCTAssertEqual(h.savedMarkdown, "hi\nthere\n")
    }

    func testReplaceAllWithMarkdownIsOneUndoStepAndSyncsDocument() {
        let h = NewEditorHost(markdown: "old\n")
        h.textView.replaceAllWithMarkdown("# New\n\ntext **b**\n")
        XCTAssertEqual(h.string, "New\n\ntext b\n")
        XCTAssertEqual(h.textView.blockKinds, ["h1", "p", "p"])
        XCTAssertEqual(h.markdown, "# New\n\ntext **b**\n")
    }

    func testOpenUnchangedIsByteIdenticalOnGeneratedNotes() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            let md = gen.markdown()
            XCTAssertEqual(NewEditorHost(markdown: md).markdown, md, "seed \(seed)")
        }
    }

    // MARK: Enter at the end of a heading

    func testEnterAtEndOfHeadingStartsParagraph() {
        for source in ["# Head\nrest\n", "# Head\n", "# Head", "text\n## Head\n\nmore"] {
            let h = NewEditorHost(markdown: source)
            let headEnd = NSString(string: h.string).range(of: "Head").upperBound
            h.select(headEnd)
            h.press(.enter)
            h.type("next")
            let kinds = h.textView.blockKinds
            let headIndex = h.string.components(separatedBy: "\n").firstIndex(of: "Head")!
            XCTAssertTrue(kinds[headIndex].hasPrefix("h"), source)
            XCTAssertEqual(kinds[headIndex + 1], "p", "new line after heading is a paragraph: \(source)")
            XCTAssertTrue(h.savedMarkdown!.contains("Head\nnext"), source)
            XCTAssertFalse(h.savedMarkdown!.contains("# next"), source)
        }
    }

    func testEnterInMiddleOfHeadingKeepsBothHalvesHeadings() {
        let h = NewEditorHost(markdown: "# Headline\n")
        h.select(4)
        h.press(.enter)
        XCTAssertEqual(h.textView.blockKinds, ["h1", "h1"])
    }

    // MARK: properties (generated notes)

    func testCaretMatchesWhatAppKitReports() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            let h = NewEditorHost(markdown: gen.markdown())
            for loc in 0...h.length {
                h.select(loc)
                let mine = h.caret.origin, theirs = h.appKitCaretOrigin
                XCTAssertEqual(mine.x, theirs.x, accuracy: 1.5, "seed \(seed) loc \(loc) x")
                XCTAssertEqual(mine.y, theirs.y, accuracy: 1.5, "seed \(seed) loc \(loc) y")
            }
        }
    }

    /// Found by generated seed 96 (and 84 on the 06 base): the caret at the end of a last line that has no line break.
    func testCaretAtTheEndOfTheLastLineWithoutALineBreakMatchesAppKit() {
        for md in ["# beta caf\u{e9} snake_case", "# snake_case", "# beta snake_case", "## beta", "text\n# Head", "alpha", "- item", "- [ ] item", "> quote", "1. one", "# a\n\n# b"] {
            let h = NewEditorHost(markdown: md)
            for loc in 0...h.length {
                h.select(loc)
                XCTAssertEqual(h.caret.origin.x, h.appKitCaretOrigin.x, accuracy: 1.5, "\(md.debugDescription) loc \(loc) x")
                XCTAssertEqual(h.caret.origin.y, h.appKitCaretOrigin.y, accuracy: 1.5, "\(md.debugDescription) loc \(loc) y")
            }
        }
    }

    func testEveryRightAndLeftMovesTheCaretAndLeftReversesRight() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            let h = NewEditorHost(markdown: gen.markdown())
            h.select(0)
            var path: [(Int, NSRect)] = [(h.location, h.caret)]
            while h.location < h.length {
                h.press(.right)
                XCTAssertGreaterThan(h.location, path.last!.0, "seed \(seed): Right did not advance from \(path.last!.0)")
                XCTAssertNotEqual(h.caret, path.last!.1, "seed \(seed): drawn caret did not move at \(h.location)")
                path.append((h.location, h.caret))
            }
            for expected in path.dropLast().reversed() {
                h.press(.left)
                XCTAssertEqual(h.location, expected.0, "seed \(seed): Left is not the reverse of Right")
                XCTAssertEqual(h.caret, expected.1, "seed \(seed): drawn caret differs on the way back at \(expected.0)")
            }
        }
    }

    func testUpAndDownChangeTheLine() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            let h = NewEditorHost(markdown: gen.markdown())
            let lines = NoteTextEngine.lineCount(in: h.textView)
            h.select(0)
            var ys = [h.caret.minY]
            for _ in 0..<(lines - 1) {
                h.press(.down)
                XCTAssertGreaterThan(h.caret.minY, ys.last!, "seed \(seed): Down did not change the line")
                ys.append(h.caret.minY)
            }
            for expected in ys.dropLast().reversed() {
                h.press(.up)
                XCTAssertEqual(h.caret.minY, expected, accuracy: 0.5, "seed \(seed): Up did not change the line")
            }
        }
    }

    func testTypedCharacterAppearsAtTheDrawnCaretAtEveryPosition() {
        for seed in 1...UInt64(seeds) {
            var gen = NewEditorNoteGenerator(seed: seed)
            let h = NewEditorHost(markdown: gen.markdown())
            let original = h.string
            for loc in 0...h.length {
                h.select(loc)
                let before = h.caret
                h.type("Z")
                XCTAssertEqual(h.location, loc + 1, "seed \(seed) loc \(loc)")
                // The typed character starts where the caret was drawn, and the caret now sits to its right.
                // 4 pt of slack: the system adds up to ~1/8 em of space between CJK and Latin neighbours.
                let start = NoteTextEngine.caretRect(in: h.textView, at: loc)
                XCTAssertEqual(start.minX, before.minX, accuracy: 4, "seed \(seed) loc \(loc): typed character not at the caret")
                XCTAssertEqual(start.minY, before.minY, accuracy: 0.5, "seed \(seed) loc \(loc): typed character on another line")
                XCTAssertEqual(h.caret.minY, before.minY, accuracy: 0.5, "seed \(seed) loc \(loc): caret left the line")
                XCTAssertGreaterThan(h.caret.minX, before.minX, "seed \(seed) loc \(loc): caret did not advance past the typed character")
                h.press(.backspace)
                XCTAssertEqual(h.string, original, "seed \(seed) loc \(loc): Backspace did not remove the typed character")
            }
        }
    }

    // MARK: layout-engine code in one place

    func testLayoutEngineCodeLivesInOneFile() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Sidekick/NewEditor")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files where file.lastPathComponent != "NoteTextEngine.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in ["NSLayoutManager", "layoutManager", "NSTextContainer", "glyphIndex", "lineFragmentRect", "boundingRect"] {
                XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) uses \(token) outside NoteTextEngine.swift")
            }
        }
    }

    /// Document history (07): undo back to ANY earlier state gives that state's exact bytes, however many steps.
    func testUndoOfManyEditsRestoresTheOriginalSpellingsAndRedoComesBack() {
        let source = "intro\r\n___\r\n* one\r\n* two\r\n1) a\r\n2) b\r\nend\r\n"
        let h = NewEditorHost(markdown: source)
        XCTAssertEqual(h.markdown, source)
        var states = [source]
        // The first edits rewrite the very blocks whose spellings (`___`, `* `, `1)`, CRLF) the file has.
        func start(of line: String) -> Int { NSString(string: h.string).range(of: line).location }
        let rewrite: [() -> Void] = [
            { h.select(start(of: "one")); h.press(.backspace) },        // the bullet becomes a plain line
            { h.select(start(of: "a\n")); h.press(.backspace) },         // the numbered item becomes a plain line
            { h.select(start(of: "two") + 3); h.type("!") },                 // the second bullet is edited
            { h.select(start(of: "b\n") + 1); h.type("?") },                  // the second number is edited
            { h.select(start(of: "intro") + 5); h.press(.forwardDelete) },    // the line break after intro goes
        ]
        for i in 0..<40 {
            if i < rewrite.count { rewrite[i]() } else {
                h.select(NSString(string: h.string).range(of: i % 2 == 0 ? "intro" : "end").upperBound)
                h.type(String(UnicodeScalar(UInt8(97 + i % 26))))
            }
            h.endUndoGroup()
            states.append(h.markdown)
        }
        XCTAssertNotEqual(h.markdown, source)
        for i in stride(from: 39, through: 0, by: -1) {
            h.undo()
            XCTAssertEqual(h.markdown, states[i], "undo to state \(i)")
        }
        XCTAssertEqual(h.markdown, source)
        for i in 1...40 {
            h.textView.undoManager?.redo()
            h.endUndoGroup()
            XCTAssertEqual(h.markdown, states[i], "redo to state \(i)")
        }
    }
}
