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
    var listener: NWListener?
    var connections: [ObjectIdentifier: NWConnection] = [:]

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

    // MARK: - Routing

    func route(_ req: Request) -> (Int, [String: Any]) {
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

    struct HarnessError: Error { let message: String }
    func fail(_ m: String) -> HarnessError { HarnessError(message: m) }

    // MARK: - Lookups

    var panel: SidekickPanel? { app.panelController.panel }

    func textView() throws -> HybridTextView {
        guard let panel, let tv = Self.findTextView(in: panel.contentView) as? HybridTextView else {
            throw fail("editor not mounted (summon the panel and open a note first)")
        }
        return tv
    }

    static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    func rect(_ r: NSRect) -> [String: Any] {
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
        out["appIsActive"] = NSApp.isActive
        out["screens"] = NSScreen.screens.map { ["frame": rect($0.frame), "visible": rect($0.visibleFrame), "scale": $0.backingScaleFactor] }
        if let panel {
            out["windowFrame"] = rect(panel.frame)
            out["windowAlpha"] = panel.alphaValue
            out["windowOnScreen"] = panel.isOnActiveSpace
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

}
