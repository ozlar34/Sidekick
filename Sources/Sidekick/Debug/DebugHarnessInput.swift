import AppKit
import Foundation

/// Input half of `DebugHarness`: editor mutation plus synthesized mouse and
/// keyboard events routed through the production `mouseDown` / `keyDown`
/// paths. Command routing lives in `DebugHarness.swift`.
extension DebugHarness {

    // MARK: - Editor mutation

    func setText(_ json: [String: Any]) throws -> [String: Any] {
        let tv = try textView()
        guard let text = json["text"] as? String else { throw fail("text required") }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        guard tv.shouldChangeText(in: full, replacementString: text) else { throw fail("edit refused") }
        tv.textStorage?.replaceCharacters(in: full, with: text)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        return ["length": (tv.string as NSString).length]
    }

    func select(_ json: [String: Any]) throws -> [String: Any] {
        let tv = try textView()
        let loc = json["location"] as? Int ?? 0
        let len = json["length"] as? Int ?? 0
        tv.setSelectedRange(NSRange(location: loc, length: len))
        let sel = tv.selectedRange()
        return ["selection": ["location": sel.location, "length": sel.length]]
    }

    /// Real left-click through the full `HybridTextView.mouseDown` path.
    /// Coordinates default to TEXT-CONTAINER space (what /glyphs reports);
    /// pass `space: "window"` for window coordinates. The matching mouseUp is
    /// queued FIRST so NSTextView's drag-tracking loop returns immediately
    /// (same trick as Tests/SidekickTests/Support/SyntheticMouse.swift).
    func click(_ json: [String: Any]) throws -> [String: Any] {
        let tv = try textView()
        guard let panel, let x = json["x"] as? Double, let y = json["y"] as? Double else {
            throw fail("x, y required")
        }
        let count = json["count"] as? Int ?? 1
        let mods = Self.modifiers(json["mods"])
        let space = json["space"] as? String ?? "text"
        let winPoint = try windowPoint(x: x, y: y, space: space, in: tv)
        panel.makeKey()
        let ts = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, _ p: NSPoint, _ t: TimeInterval) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: t,
                                             windowNumber: panel.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: count, pressure: 1)
            else { throw fail("event creation failed") }
            return e
        }
        let down = try ev(.leftMouseDown, winPoint, ts)
        if let dragTo = json["drag_to"] as? [String: Any],
           let dx = dragTo["x"] as? Double, let dy = dragTo["y"] as? Double {
            let p2 = try windowPoint(x: dx, y: dy, space: space, in: tv)
            panel.postEvent(try ev(.leftMouseDragged, p2, ts + 0.03), atStart: false)
            panel.postEvent(try ev(.leftMouseUp, p2, ts + 0.06), atStart: false)
        } else {
            panel.postEvent(try ev(.leftMouseUp, winPoint, ts + 0.05), atStart: false)
        }
        let before = tv.selectedRange()
        // Route through the window so the scroll view / hit-testing path is
        // exercised; the down lands on whichever view owns the point.
        panel.sendEvent(down)
        if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
        let after = tv.selectedRange()
        return [
            "before": ["location": before.location, "length": before.length],
            "selection": ["location": after.location, "length": after.length],
            "windowPoint": ["x": winPoint.x, "y": winPoint.y],
            "hitView": String(describing: panel.contentView?.hitTest(winPoint).map { Swift.type(of: $0) } as Any),
        ]
    }

    func windowPoint(x: Double, y: Double, space: String, in tv: NSTextView) throws -> NSPoint {
        switch space {
        case "text":
            let viewPoint = NSPoint(x: x + tv.textContainerOrigin.x, y: y + tv.textContainerOrigin.y)
            return tv.convert(viewPoint, to: nil)
        case "view":
            return tv.convert(NSPoint(x: x, y: y), to: nil)
        case "window":
            return NSPoint(x: x, y: y)
        default:
            throw fail("space must be text|view|window")
        }
    }

    static func modifiers(_ raw: Any?) -> NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        for s in (raw as? [String]) ?? [] {
            switch s.lowercased() {
            case "cmd", "command": m.insert(.command)
            case "shift": m.insert(.shift)
            case "opt", "option", "alt": m.insert(.option)
            case "ctrl", "control": m.insert(.control)
            default: break
            }
        }
        return m
    }

    /// Named special keys → (keyCode, characters). Characters follow what
    /// AppKit delivers for the physical key so `interpretKeyEvents` maps them
    /// to the right selector (moveLeft:, deleteBackward:, insertNewline:, …).
    static let namedKeys: [String: (UInt16, String)] = [
        "return": (36, "\r"), "enter": (36, "\r"),
        "tab": (48, "\t"),
        "space": (49, " "),
        "delete": (51, "\u{7F}"), "backspace": (51, "\u{7F}"),
        "forwarddelete": (117, "\u{F728}"),
        "escape": (53, "\u{1B}"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
        "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
    ]

    func key(_ json: [String: Any]) throws -> [String: Any] {
        let tv = try textView()
        guard let panel else { throw fail("no panel") }
        let mods = Self.modifiers(json["mods"])
        var keyCode: UInt16 = 0
        var chars: String
        if let name = json["key"] as? String, let k = Self.namedKeys[name.lowercased()] {
            keyCode = k.0
            chars = k.1
        } else if let c = json["chars"] as? String {
            chars = c
            keyCode = json["keyCode"] as? UInt16 ?? 0
        } else {
            throw fail("key (named) or chars required")
        }
        try sendKey(chars: chars, keyCode: keyCode, mods: mods, panel: panel, tv: tv)
        let sel = tv.selectedRange()
        return ["selection": ["location": sel.location, "length": sel.length], "text": tv.string]
    }

    func type(_ json: [String: Any]) throws -> [String: Any] {
        let tv = try textView()
        guard let panel, let text = json["text"] as? String else { throw fail("text required") }
        for ch in text {
            let s = String(ch)
            if s == "\n" {
                try sendKey(chars: "\r", keyCode: 36, mods: [], panel: panel, tv: tv)
            } else {
                try sendKey(chars: s, keyCode: 0, mods: [], panel: panel, tv: tv)
            }
        }
        let sel = tv.selectedRange()
        return ["selection": ["location": sel.location, "length": sel.length], "text": tv.string]
    }

    func sendKey(chars: String, keyCode: UInt16, mods: NSEvent.ModifierFlags,
                         panel: SidekickPanel, tv: NSTextView) throws {
        panel.makeKey()
        if panel.firstResponder !== tv { panel.makeFirstResponder(tv) }
        let ts = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ts,
                                          windowNumber: panel.windowNumber, context: nil, characters: chars,
                                          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode),
              let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: mods, timestamp: ts + 0.02,
                                        windowNumber: panel.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)
        else { throw fail("key event creation failed") }
        // Cmd-shortcuts must go through performKeyEquivalent (menu routing);
        // everything else is a plain keyDown to the first responder.
        if mods.contains(.command), panel.performKeyEquivalent(with: down) {
            return
        }
        panel.sendEvent(down)
        panel.sendEvent(up)
    }

}
