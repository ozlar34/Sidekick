import AppKit
import Foundation
import Network

/// In-process debug control server. Dormant unless the process is launched with
/// `--debug-port <n>`; then a tiny HTTP server on 127.0.0.1:<n> exposes the live
/// panel, editor, and store so an external driver (curl, a script, an agent)
/// can summon the panel, open notes, synthesize real clicks and keystrokes,
/// read caret / glyph geometry, and capture pixel screenshots of the panel.
///
/// Companion flag `--debug-notes-folder <path>` points the NoteStore at a
/// throwaway folder for that process only (never written to UserDefaults), so
/// a harness-driven instance can never touch the user's real notes.
///
/// Class: verifier (standing component). Attention saved: editor bugs can be
/// reproduced, screenshotted, and regression-checked without a human at the
/// keyboard. Cost: this file, compiled in but inert without the flag.
///
/// Endpoints (all JSON; POST bodies are JSON objects):
///   GET  /state                 → panel/window/editor/store snapshot
///   GET  /glyphs                → per-character glyph rects (text-container coords)
///   POST /summon  /dismiss      → toggle the panel
///   POST /open   {id|title}     → select a note
///   POST /set    {text}         → replace editor body through the user edit path
///   POST /click  {x,y,count?,space?,drag_to?}   → real NSEvent click (text coords)
///   POST /key    {key,mods?} | {chars,mods?}    → real NSEvent key press
///   POST /type   {text}         → one key event per character
///   POST /select {location,length}              → programmatic caret placement
///   POST /screenshot {path,region?}             → PNG of the panel (window pixels)
@MainActor
final class DebugHarness {

    // MARK: - Launch-argument parsing

    static var port: UInt16? {
        argValue("--debug-port").flatMap { UInt16($0) }
    }

    static var notesFolderOverride: URL? {
        argValue("--debug-notes-folder").map { URL(fileURLWithPath: $0) }
    }

    private static func argValue(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - Lifetime

    private unowned let app: AppDelegate
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(app: AppDelegate) {
        self.app = app
    }

    func start(port: UInt16) {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { state in
                NSLog("[Sidekick.debug] listener \(state)")
            }
            l.start(queue: .main)
            listener = l
            NSLog("[Sidekick.debug] control server on 127.0.0.1:\(port)")
        } catch {
            NSLog("[Sidekick.debug] failed to start: \(error)")
        }
    }

    // MARK: - Minimal HTTP/1.1

    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.drop(conn) } }
            if case .cancelled = state { Task { @MainActor in self?.drop(conn) } }
        }
        conn.start(queue: .main)
        readRequest(conn, buffer: Data())
    }

    private func drop(_ conn: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = Self.parse(buf) {
                    let (status, body) = self.route(req)
                    self.respond(conn, status: status, json: body)
                } else if isComplete || error != nil {
                    conn.cancel()
                } else {
                    self.readRequest(conn, buffer: buf)
                }
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let json: [String: Any]
    }

    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return Request(method: String(parts[0]), path: String(parts[1]), json: json)
    }

    private func respond(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Routing

    private func route(_ req: Request) -> (Int, [String: Any]) {
        do {
            switch (req.method, req.path) {
            case ("GET", "/state"):        return (200, try state())
            case ("GET", "/glyphs"):       return (200, try glyphs())
            case ("POST", "/summon"):      return (200, summon(true))
            case ("POST", "/dismiss"):     return (200, summon(false))
            case ("POST", "/open"):        return (200, try open(req.json))
            case ("POST", "/set"):         return (200, try setText(req.json))
            case ("POST", "/click"):       return (200, try click(req.json))
            case ("POST", "/key"):         return (200, try key(req.json))
            case ("POST", "/type"):        return (200, try type(req.json))
            case ("POST", "/select"):      return (200, try select(req.json))
            case ("POST", "/screenshot"):  return (200, try screenshot(req.json))
            default:                       return (404, ["error": "no route \(req.method) \(req.path)"])
            }
        } catch let e as HarnessError {
            return (400, ["error": e.message])
        } catch {
            return (500, ["error": "\(error)"])
        }
    }

    private struct HarnessError: Error { let message: String }
    private func fail(_ m: String) -> HarnessError { HarnessError(message: m) }

    // MARK: - Lookups

    private var panel: SidekickPanel? { app.panelController.panel }

    private func textView() throws -> HybridTextView {
        guard let panel, let tv = Self.findTextView(in: panel.contentView) as? HybridTextView else {
            throw fail("editor not mounted (summon the panel and open a note first)")
        }
        return tv
    }

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    private func rect(_ r: NSRect) -> [String: Any] {
        ["x": r.origin.x, "y": r.origin.y, "w": r.size.width, "h": r.size.height]
    }

    // MARK: - GET /state

    private func state() throws -> [String: Any] {
        var out: [String: Any] = [:]
        let store = app.store
        out["notes"] = (store?.notes ?? []).map { n -> [String: Any] in
            ["id": n.id.uuidString, "title": n.title, "filename": n.filename, "bodyLength": (n.body as NSString).length]
        }
        out["selectedNoteID"] = app.panelController.panelState.selectedNoteID?.uuidString ?? NSNull()
        if let id = app.panelController.panelState.selectedNoteID,
           let n = store?.notes.first(where: { $0.id == id }) {
            out["selectedNoteBody"] = n.body
        }
        out["panelVisible"] = panel?.isVisible ?? false
        out["panelIsKey"] = panel?.isKeyWindow ?? false
        if let panel {
            out["windowFrame"] = rect(panel.frame)
            out["windowNumber"] = panel.windowNumber
            out["firstResponder"] = panel.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? NSNull()
        }
        if let panel, let tv = Self.findTextView(in: panel.contentView) {
            var ed: [String: Any] = [:]
            ed["text"] = tv.string
            ed["length"] = (tv.string as NSString).length
            let sel = tv.selectedRange()
            ed["selection"] = ["location": sel.location, "length": sel.length]
            ed["frame"] = rect(tv.frame)
            ed["frameInWindow"] = rect(tv.convert(tv.bounds, to: nil))
            ed["visibleRect"] = rect(tv.visibleRect)
            ed["textContainerOrigin"] = ["x": tv.textContainerOrigin.x, "y": tv.textContainerOrigin.y]
            ed["isFirstResponder"] = panel.firstResponder === tv
            ed["isHidden"] = tv.isHiddenOrHasHiddenAncestor
            ed["alpha"] = tv.alphaValue
            ed["layerOpacity"] = tv.layer?.opacity ?? NSNull()
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                ed["usedRect"] = rect(lm.usedRect(for: tc))
                ed["numberOfGlyphs"] = lm.numberOfGlyphs
                ed["hasNonContiguousLayout"] = lm.hasNonContiguousLayout
                // Caret rect in text-container coords: insertion point for the
                // selection start, from the glyph geometry.
                if sel.location <= (tv.string as NSString).length {
                    let glyph = lm.glyphIndexForCharacter(at: min(sel.location, max(0, lm.numberOfGlyphs - 1)))
                    let frag = lm.lineFragmentRect(forGlyphAt: min(glyph, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
                    let loc = lm.location(forGlyphAt: min(glyph, max(0, lm.numberOfGlyphs - 1)))
                    ed["caretRect"] = rect(NSRect(x: frag.origin.x + loc.x, y: frag.origin.y, width: 1, height: frag.height))
                }
            }
            if let storage = tv.textStorage {
                var attrs: [String: Any] = [:]
                attrs["length"] = storage.length
                attrs["storageClass"] = String(describing: Swift.type(of: storage))
                ed["storage"] = attrs
            }
            if let sv = tv.enclosingScrollView {
                ed["clipBounds"] = rect(sv.contentView.bounds)
                ed["scrollFrameInWindow"] = rect(sv.convert(sv.bounds, to: nil))
            }
            out["editor"] = ed
        } else {
            out["editor"] = NSNull()
        }
        return out
    }

    // MARK: - GET /glyphs

    private func glyphs() throws -> [String: Any] {
        let tv = try textView()
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage else {
            throw fail("no layout manager")
        }
        lm.ensureLayout(for: tc)
        let ns = storage.string as NSString
        var items: [[String: Any]] = []
        for i in 0..<ns.length {
            let g = lm.glyphIndexForCharacter(at: i)
            var item: [String: Any] = ["index": i, "glyph": g]
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            item["char"] = ch
            if g < lm.numberOfGlyphs {
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let loc = lm.location(forGlyphAt: g)
                let br = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                item["fragment"] = rect(frag)
                item["x"] = frag.origin.x + loc.x
                item["bounds"] = rect(br)
                item["hidden"] = lm.propertyForGlyph(at: g).contains(.null)
                item["notShown"] = lm.notShownAttribute(forGlyphAt: g)
            }
            var markers: [String] = []
            for key: NSAttributedString.Key in [.sidekickHiddenMarker, .sidekickThematicBreak, .sidekickChecklistMarker] {
                if storage.attribute(key, at: i, effectiveRange: nil) != nil { markers.append(key.rawValue) }
            }
            if storage.attribute(.link, at: i, effectiveRange: nil) != nil { markers.append("link") }
            item["markers"] = markers
            items.append(item)
        }
        return ["length": ns.length, "glyphs": items, "usedRect": rect(lm.usedRect(for: tc))]
    }

    // MARK: - Panel / store

    private func summon(_ show: Bool) -> [String: Any] {
        let visible = panel?.isVisible ?? false
        if show != visible { app.panelController.toggle() }
        return ["panelVisible": panel?.isVisible ?? false]
    }

    private func open(_ json: [String: Any]) throws -> [String: Any] {
        guard let store = app.store else { throw fail("no store") }
        var target: Note?
        if let s = json["id"] as? String, let id = UUID(uuidString: s) {
            target = store.notes.first { $0.id == id }
        } else if let t = json["title"] as? String {
            target = store.notes.first { $0.title == t }
        }
        guard let target else { throw fail("note not found") }
        app.panelController.panelState.selectedNoteID = target.id
        return ["selectedNoteID": target.id.uuidString]
    }

    // MARK: - Editor mutation

    private func setText(_ json: [String: Any]) throws -> [String: Any] {
        let tv = try textView()
        guard let text = json["text"] as? String else { throw fail("text required") }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        guard tv.shouldChangeText(in: full, replacementString: text) else { throw fail("edit refused") }
        tv.textStorage?.replaceCharacters(in: full, with: text)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        return ["length": (tv.string as NSString).length]
    }

    private func select(_ json: [String: Any]) throws -> [String: Any] {
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
    private func click(_ json: [String: Any]) throws -> [String: Any] {
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

    private func windowPoint(x: Double, y: Double, space: String, in tv: NSTextView) throws -> NSPoint {
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

    private static func modifiers(_ raw: Any?) -> NSEvent.ModifierFlags {
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
    private static let namedKeys: [String: (UInt16, String)] = [
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

    private func key(_ json: [String: Any]) throws -> [String: Any] {
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

    private func type(_ json: [String: Any]) throws -> [String: Any] {
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

    private func sendKey(chars: String, keyCode: UInt16, mods: NSEvent.ModifierFlags,
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

    // MARK: - POST /screenshot

    /// Captures the panel's real window pixels (CoreGraphics window capture of
    /// our own window needs no Screen Recording permission). `region` is
    /// "panel" (default) or "editor" (cropped to the text view's frame).
    /// Returns pixel stats for the captured region so a driver can detect an
    /// unpainted editor without image tooling: `inkFraction` is the share of
    /// pixels that differ from the region's dominant color.
    private func screenshot(_ json: [String: Any]) throws -> [String: Any] {
        guard let panel else { throw fail("no panel") }
        guard let path = json["path"] as? String else { throw fail("path required") }
        let region = json["region"] as? String ?? "panel"

        var cg: CGImage?
        var source = "window"
        cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                     [.boundsIgnoreFraming, .bestResolution])
        if cg == nil || cg!.width <= 1, let cv = panel.contentView,
           let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
            cv.cacheDisplay(in: cv.bounds, to: rep)
            cg = rep.cgImage
            source = "cacheDisplay"
        }
        guard var image = cg else { throw fail("capture failed") }

        let scale = CGFloat(image.width) / panel.frame.width
        var cropRect: NSRect? = nil
        if region == "editor", let tv = Self.findTextView(in: panel.contentView) {
            let inWin = tv.convert(tv.visibleRect, to: nil)   // bottom-left origin
            // Window pixels have a top-left origin.
            let px = NSRect(x: inWin.origin.x * scale,
                            y: (panel.frame.height - inWin.maxY) * scale,
                            width: inWin.width * scale,
                            height: inWin.height * scale)
            cropRect = px
            if let c = image.cropping(to: px) { image = c }
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw fail("png encode failed") }
        try png.write(to: URL(fileURLWithPath: path))

        var out: [String: Any] = ["path": path, "width": image.width, "height": image.height,
                                  "source": source, "scale": scale]
        if let cropRect { out["cropPixels"] = rect(cropRect) }
        out.merge(Self.pixelStats(image)) { a, _ in a }
        return out
    }

    /// Dominant color + fraction of pixels that differ from it by more than a
    /// small tolerance. Empty editor ⇒ inkFraction ≈ 0.
    private static func pixelStats(_ image: CGImage) -> [String: Any] {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [:] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Quantize to 4 bits per channel to find the dominant color.
        var hist: [UInt32: Int] = [:]
        let step = max(1, (w * h) / 200_000)
        var i = 0
        while i < w * h {
            let o = i * 4
            let key = UInt32(buf[o] >> 4) << 8 | UInt32(buf[o + 1] >> 4) << 4 | UInt32(buf[o + 2] >> 4)
            hist[key, default: 0] += 1
            i += step
        }
        guard let dom = hist.max(by: { $0.value < $1.value })?.key else { return [:] }
        let dr = Int((dom >> 8) & 0xF) << 4, dg = Int((dom >> 4) & 0xF) << 4, db = Int(dom & 0xF) << 4
        var ink = 0, total = 0
        i = 0
        while i < w * h {
            let o = i * 4
            let d = abs(Int(buf[o]) - dr) + abs(Int(buf[o + 1]) - dg) + abs(Int(buf[o + 2]) - db)
            if d > 60 { ink += 1 }
            total += 1
            i += step
        }
        return ["dominant": [dr, dg, db], "inkFraction": Double(ink) / Double(max(total, 1)), "sampled": total]
    }
}
