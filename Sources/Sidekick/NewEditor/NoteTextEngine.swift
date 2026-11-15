import AppKit

/// All layout-engine-specific code of the new editor lives here: the TextKit 1 stack and the
/// geometry queries (caret, line, glyph positions). Nothing else in the editor view module
/// touches `NSLayoutManager`; a second engine adapter would replace this file.
@MainActor
enum NoteTextEngine {
    struct Stack {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    /// Storage, layout manager and container, assembled in the order TextKit 1 needs.
    static func makeStack() -> Stack {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return Stack(storage: storage, layoutManager: layoutManager, container: container)
    }

    /// Makes `tv` lay out and draw `storage` (note switch). The layout manager keeps its container.
    static func show(_ storage: NSTextStorage, in tv: NSTextView) {
        tv.layoutManager?.replaceTextStorage(storage)
    }

    // MARK: Geometry (all rects in the text view's own coordinates)

    /// Rect of the insertion point for a caret at UTF-16 offset `location`.
    static func caretRect(in tv: NSTextView, at location: Int) -> NSRect {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return .zero }
        lm.ensureLayout(for: tc)
        let origin = tv.textContainerOrigin
        let length = (tv.string as NSString).length
        var rect: NSRect
        if location >= length {
            let extra = lm.extraLineFragmentRect
            if length == 0 || extra.height > 0 {
                rect = NSRect(x: extra.minX + tc.lineFragmentPadding, y: extra.minY, width: 1, height: extra.height)
            } else {
                let g = lm.numberOfGlyphs - 1
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let box = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                rect = NSRect(x: box.maxX, y: frag.minY, width: 1, height: frag.height)
            }
        } else {
            let g = lm.glyphIndexForCharacter(at: location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: g)
            // An empty line has no used width; its caret sits at the padded left edge.
            let x = used.width == 0 ? frag.minX + tc.lineFragmentPadding : used.minX + loc.x
            rect = NSRect(x: x, y: frag.minY, width: 1, height: frag.height)
        }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Number of visual lines, counting the empty line after a final line break.
    static func lineCount(in tv: NSTextView) -> Int {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        var n = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in n += 1 }
        if lm.extraLineFragmentRect.height > 0 { n += 1 }
        return n
    }
}
