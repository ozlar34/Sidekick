import XCTest
import AppKit
@testable import Sidekick

/// The new editor in a real window, driven by real key events (`NSWindow.sendEvent`), with caret and
/// glyph geometry read from the view. This is the "editor as the user sees it" seam.
@MainActor
final class NewEditorHost {
    let textView: NoteTextView
    let window: NSWindow
    /// Markdown reported through `onMarkdownChange` (what the app would hand to the save path).
    private(set) var savedMarkdown: String?

    init(markdown: String, size: CGSize = CGSize(width: 900, height: 600)) {
        TestWatchdog.installOnce()
        textView = NoteTextView.make()
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        textView.load(markdown: markdown)
        textView.onMarkdownChange = { [unowned self] md in self.savedMarkdown = md }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    /// A host showing an open note (its storage, undo history and edit state), as the app does.
    convenience init(note: OpenNote, size: CGSize = CGSize(width: 900, height: 600)) {
        self.init(markdown: "", size: size)
        textView.attach(note.content)
    }

    deinit { MainActor.assumeIsolated { window.contentView = nil; window.close() } }

    var string: String { textView.string }
    var length: Int { (textView.string as NSString).length }
    var location: Int { textView.selectedRange().location }
    var caret: NSRect { NoteTextEngine.caretRect(in: textView, at: location) }
    var markdown: String { textView.markdown }

    func select(_ location: Int) { textView.setSelectedRange(NSRange(location: location, length: 0)) }

    enum Key {
        case left, right, up, down, enter, backspace, forwardDelete, tab, backtab
        var code: UInt16 {
            switch self {
            case .left: return 123; case .right: return 124; case .down: return 125; case .up: return 126
            case .enter: return 36; case .backspace: return 51; case .forwardDelete: return 117; case .tab, .backtab: return 48
            }
        }
        var chars: String {
            switch self {
            case .left: return "\u{F702}"; case .right: return "\u{F703}"; case .down: return "\u{F701}"; case .up: return "\u{F700}"
            case .enter: return "\r"; case .backspace: return "\u{7F}"; case .forwardDelete: return "\u{F728}"; case .tab: return "\t"; case .backtab: return "\u{19}"
            }
        }
    }

    func press(_ key: Key, shift: Bool = false) { send(chars: key.chars, keyCode: key.code, mods: shift ? [.shift] : []) }

    func type(_ text: String) {
        for ch in text {
            if ch == "\n" { press(.enter) } else { send(chars: String(ch), keyCode: 0, mods: []) }
        }
    }

    /// A real key event with Command held (and more modifiers), offered to `menu` as a key equivalent. `keyCode` is the
    /// physical key (US layout), so shifted digits match their menu item as on a real keyboard. The Format menu is offered
    /// the key directly: the Edit menu's Cut (also `x`) answers Command-Shift-X first when the whole main menu is asked.
    @discardableResult
    func shortcut(_ chars: String, keyCode: UInt16, _ mods: NSEvent.ModifierFlags, in menu: NSMenu) -> Bool {
        window.makeKeyAndOrderFront(nil)
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods.union(.command), timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: mods.contains(.shift) ? chars.uppercased() : chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        return menu.performKeyEquivalent(with: event)
    }

    private func send(chars: String, keyCode: UInt16, mods: NSEvent.ModifierFlags) {
        window.makeKeyAndOrderFront(nil)
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
        let ts = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ts,
                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: mods, timestamp: ts + 0.01,
                                  windowNumber: window.windowNumber, context: nil, characters: chars,
                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// A real left click at `point` (view coordinates): a mouse-down event delivered to the view, the mouse-up queued
    /// first because NSTextView tracks a click until it sees it.
    /// A synthetic mouse event sent through `NSWindow.sendEvent` does not reach the view in a test run.
    /// On the CI runner the queued mouse-up never reaches NSTextView's tracking loop, which then waits forever; so while
    /// `mouseDown` runs, a timer in the common run-loop modes (it fires inside the tracking loop) re-posts the mouse-up
    /// until the click returns. `queueMouseUp: false` skips the first post, to test that backstop alone.
    func click(at point: NSPoint, modifiers: NSEvent.ModifierFlags = [], queueMouseUp: Bool = true) {
        window.makeKeyAndOrderFront(nil)
        let inWindow = textView.convert(point, to: nil)
        let ts = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ t: TimeInterval) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: modifiers, timestamp: t, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        if queueMouseUp { window.postEvent(event(.leftMouseUp, ts + 0.05), atStart: false) }
        let backstop = Timer(timeInterval: 0.15, repeats: true) { [window] _ in
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: inWindow, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
        }
        RunLoop.main.add(backstop, forMode: .common)
        textView.mouseDown(with: event(.leftMouseDown, ts))
        backstop.invalidate()
        // Whatever of the click is left unread must not leak into the next test.
        while NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }

    /// Lets the run loop close the current undo group, so that the next change is a separate undo step
    /// (as it is between two real events).
    /// `wait` is how long the run loop may run; loops that undo thousands of times pass a shorter one.
    func endUndoGroup(wait: TimeInterval = 0.02) { RunLoop.current.run(until: Date(timeIntervalSinceNow: wait)) }

    /// Undoes one step.
    func undo(wait: TimeInterval = 0.02) { endUndoGroup(wait: wait); textView.undoManager?.undo(); endUndoGroup(wait: wait) }

    /// Where AppKit itself reports the insertion point (screen -> view coordinates).
    var appKitCaretRect: NSRect {
        var actual = NSRange()
        let screen = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: &actual)
        let inWindow = window.convertFromScreen(screen)
        return textView.convert(inWindow, from: nil)
    }
    var appKitCaretOrigin: NSPoint { appKitCaretRect.origin }

    /// Offset of the first position of every table cell (after a tab or a row break, and at the table start),
    /// in the text the view shows. Table paragraphs are found through the document's block kinds.
    func tableCellStarts() -> [Int] {
        let ns = string as NSString
        var starts: [Int] = []
        var blockIndex = 0
        let kinds = textView.blockKinds
        var location = 0
        while location <= ns.length, blockIndex < kinds.count {
            let end = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location)).location
            let stop = end == NSNotFound ? ns.length : end
            if kinds[blockIndex] == "table" {
                starts.append(location)
                for i in location..<stop where ns.character(at: i) == 0x09 || ns.character(at: i) == 0x2028 { starts.append(i + 1) }
            }
            blockIndex += 1
            if end == NSNotFound { break }
            location = end + 1
        }
        return starts
    }
}

/// Small seeded generator of markdown inside the scope of this slice (paragraphs, headings, every mark, URL pills,
/// links, dividers, lists, checklists, quotes).
struct NewEditorNoteGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9 : seed }
    private mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    private mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    private static let words = ["alpha", "beta", "gamma", "x", "caf\u{e9}", "\u{65E5}\u{672C}", "snake_case", "a*b", "42"]

    private mutating func words(_ max: Int) -> String {
        (0..<(1 + int(max))).map { _ in Self.words[int(Self.words.count)] }.joined(separator: " ")
    }

    /// A fenced code block: markup-looking lines, empty lines, an optional info word.
    private mutating func code() -> String {
        let lines = (0..<(1 + int(3))).map { _ -> String in
            switch int(5) {
            case 0: return ""
            case 1: return "# " + words(2)
            case 2: return "**" + words(1) + "** and `x`"
            default: return words(3)
            }
        }
        return "```" + (int(3) == 0 ? "swift" : "") + "\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// A table with a header, a delimiter row and body rows; cells may be empty and rows may be short.
    private mutating func table() -> String {
        let columns = 1 + int(3)
        func row(_ short: Bool) -> String {
            let n = short ? max(1, columns - 1) : columns
            return "| " + (0..<n).map { _ in int(4) == 0 ? "" : words(2) }.joined(separator: " | ") + " |"
        }
        var rows = [row(false), "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"]
        for _ in 0..<(1 + int(3)) { rows.append(row(int(4) == 0)) }
        return rows.joined(separator: "\n")
    }

    mutating func markdown() -> String {
        var out = ""
        let count = 1 + int(6)
        for i in 0..<count {
            switch int(19) {
            case 11: out += words(2) + " https://example.com/" + words(1).replacingOccurrences(of: " ", with: "") + " " + words(2)   // bare pill
            case 12: out += "[https://x.y/" + String(1 + int(9)) + "](https://x.y/" + String(1 + int(9)) + ") " + words(1)   // link pill (or link)
            case 13: out += ["---", "***", "___"][int(3)]   // divider
            case 14: out += words(1) + " [" + words(2) + "](http://x.y/z) " + words(2)   // styled link
            case 15: let d = ["*", "_"][int(2)]; out += d + words(2) + d + " " + words(1)   // italic at the line start
            case 16: out += "<u>" + words(2) + "</u> ~~" + words(2) + "~~ `" + words(1) + "` " + words(1)   // underline, strike, code
            case 17: out += words(1) + " **" + words(1) + "** *" + words(1) + "* https://e.co " + words(1)   // bold, italic, bare pill
            case 18: out += "> *" + words(2) + "* [" + words(1) + "](u)"
            case 5: out += "- " + words(3)
            case 6: out += "\(1 + int(9)). " + words(3)
            case 7: out += "- [" + (int(2) == 0 ? " " : "x") + "] " + (int(5) == 0 ? "" : words(3))
            case 8: out += "> " + words(3)
            case 9: out += "- [ ] " + words(1) + " **" + words(1) + "** " + words(2)
            case 10: out += "- "
            case 0: out += String(repeating: "#", count: 1 + int(3)) + " " + words(3)
            case 1: break   // blank line
            case 2: out += words(2) + " **" + words(2) + "** " + words(2)
            case 3: out += code()
            case 4: out += table()
            default: out += words(4)
            }
            if i < count - 1 || int(4) != 0 { out += "\n" }
        }
        return out
    }
}
