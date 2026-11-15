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
        textView = NoteTextView.make()
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
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

    deinit { MainActor.assumeIsolated { window.orderOut(nil) } }

    var string: String { textView.string }
    var length: Int { (textView.string as NSString).length }
    var location: Int { textView.selectedRange().location }
    var caret: NSRect { NoteTextEngine.caretRect(in: textView, at: location) }
    var markdown: String { textView.markdown }

    func select(_ location: Int) { textView.setSelectedRange(NSRange(location: location, length: 0)) }

    enum Key {
        case left, right, up, down, enter, backspace, forwardDelete
        var code: UInt16 {
            switch self {
            case .left: return 123; case .right: return 124; case .down: return 125; case .up: return 126
            case .enter: return 36; case .backspace: return 51; case .forwardDelete: return 117
            }
        }
        var chars: String {
            switch self {
            case .left: return "\u{F702}"; case .right: return "\u{F703}"; case .down: return "\u{F701}"; case .up: return "\u{F700}"
            case .enter: return "\r"; case .backspace: return "\u{7F}"; case .forwardDelete: return "\u{F728}"
            }
        }
    }

    func press(_ key: Key, shift: Bool = false) { send(chars: key.chars, keyCode: key.code, mods: shift ? [.shift] : []) }

    func type(_ text: String) {
        for ch in text {
            if ch == "\n" { press(.enter) } else { send(chars: String(ch), keyCode: 0, mods: []) }
        }
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

    /// Where AppKit itself reports the insertion point (screen -> view coordinates).
    var appKitCaretOrigin: NSPoint {
        var actual = NSRange()
        let screen = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: &actual)
        let inWindow = window.convertFromScreen(screen)
        return textView.convert(inWindow, from: nil).origin
    }
}

/// Small seeded generator of markdown inside the scope of this slice (paragraphs, headings, bold).
struct NewEditorNoteGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9 : seed }
    private mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    private mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    private static let words = ["alpha", "beta", "gamma", "x", "caf\u{e9}", "\u{65E5}\u{672C}", "snake_case", "a*b", "42"]

    private mutating func words(_ max: Int) -> String {
        (0..<(1 + int(max))).map { _ in Self.words[int(Self.words.count)] }.joined(separator: " ")
    }

    mutating func markdown() -> String {
        var out = ""
        let count = 1 + int(6)
        for i in 0..<count {
            switch int(5) {
            case 0: out += String(repeating: "#", count: 1 + int(3)) + " " + words(3)
            case 1: break   // blank line
            case 2: out += words(2) + " **" + words(2) + "** " + words(2)
            default: out += words(4)
            }
            if i < count - 1 || int(4) != 0 { out += "\n" }
        }
        return out
    }
}
