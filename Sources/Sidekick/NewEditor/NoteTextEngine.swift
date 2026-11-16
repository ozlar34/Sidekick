import AppKit
import NoteDocument

/// All layout-engine-specific code of the new editor lives here: the TextKit 1 stack and the
/// geometry queries (caret, line, glyph positions). Nothing else in the editor view module
/// touches `NSLayoutManager`; a second engine adapter would replace this file.
@MainActor
enum NoteTextEngine {
    struct Stack {
        let storage: NSTextStorage
        let layoutManager: NoteLayoutManager
        let container: NSTextContainer
    }

    /// Storage, layout manager and container, assembled in the order TextKit 1 needs.
    static func makeStack() -> Stack {
        let storage = NSTextStorage()
        let layoutManager = NoteLayoutManager()
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
                // End of the used width of the last line: the last glyph's box reaches past the text on large headings.
                let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
                rect = NSRect(x: used.maxX - tc.lineFragmentPadding, y: used.minY, width: 1, height: used.height)
            }
        } else {
            let g = lm.glyphIndexForCharacter(at: location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: g)
            // An empty line has no used width; its caret sits at the padded left edge.
            let x = used.width == 0 ? frag.minX + tc.lineFragmentPadding : used.minX + loc.x
            // The used rect, not the fragment: the fragment also holds the space before a table or code block.
            rect = NSRect(x: x, y: used.minY, width: 1, height: used.height)
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

// MARK: Code block and table drawing

extension NoteTextEngine {
    /// A table drawn as a grid: one rect per row (header first) and the x of every vertical line, left to right.
    struct TableGrid { var rows: [NSRect]; var columnEdges: [CGFloat] }

    /// Background rect of every code block, in view coordinates.
    static func codeBackgrounds(in tv: NSTextView) -> [NSRect] {
        guard let lm = tv.layoutManager as? NoteLayoutManager, let tc = tv.textContainer else { return [] }
        lm.ensureLayout(for: tc)
        let origin = tv.textContainerOrigin
        return lm.blocks(of: .fence, in: NSRange(location: 0, length: lm.textStorage?.length ?? 0)).compactMap { lm.codeRect(for: $0) }
            .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// Grid of every table, in view coordinates.
    static func tableGrids(in tv: NSTextView) -> [TableGrid] {
        guard let lm = tv.layoutManager as? NoteLayoutManager, let tc = tv.textContainer else { return [] }
        lm.ensureLayout(for: tc)
        let origin = tv.textContainerOrigin
        return lm.blocks(of: .table, in: NSRange(location: 0, length: lm.textStorage?.length ?? 0)).compactMap { lm.grid(for: $0) }
            .map { g in TableGrid(rows: g.rows.map { $0.offsetBy(dx: origin.x, dy: origin.y) }, columnEdges: g.columnEdges.map { $0 + origin.x }) }
    }
}

/// Draws what is not text: the background of code blocks and the grid of tables. Both come from the paragraph's
/// block kind (and, for a table, its tab stops) and leave no trace in the text, the caret positions or the file.
@MainActor
final class NoteLayoutManager: NSLayoutManager {
    private static let codeOutset: CGFloat = 4

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        NSColor.quaternaryLabelColor.setFill()
        for para in blocks(of: .fence, in: chars) {
            if let rect = codeRect(for: para) { NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4).fill() }
        }
        for para in blocks(of: .table, in: chars) {
            guard let grid = grid(for: para), let header = grid.rows.first, let last = grid.rows.last else { continue }
            let left = grid.columnEdges[0] + origin.x, right = grid.columnEdges[grid.columnEdges.count - 1] + origin.x
            let top = header.minY + origin.y, bottom = last.maxY + origin.y
            NSColor.quaternaryLabelColor.setFill()
            NSRect(x: left, y: top, width: right - left, height: header.height).fill()
            NSColor.separatorColor.setFill()
            let line: CGFloat = 1
            NSRect(x: left, y: top, width: right - left, height: line).fill()
            for row in grid.rows { NSRect(x: left, y: row.maxY + origin.y - (row == last ? line : 0), width: right - left, height: line).fill() }
            for x in grid.columnEdges {
                NSRect(x: x + origin.x - (x == grid.columnEdges.last ? line : 0), y: top, width: line, height: bottom - top).fill()
            }
        }
    }

    /// Ranges (each with its "\n") of the paragraphs of `kind` that meet `chars`.
    func blocks(of kind: BlockKind, in chars: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return [] }
        var out: [NSRange] = []
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while loc < ns.length, loc < max(NSMaxRange(chars), chars.location + 1) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: para.location, effectiveRange: nil)) == kind { out.append(para) }
            loc = NSMaxRange(para)
        }
        return out
    }

    /// Union of the used rects of the lines of `chars`, in container coordinates.
    private func usedRect(of chars: NSRange) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
        var union: NSRect?
        enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in union = union.map { $0.union(used) } ?? used }
        return union
    }

    /// Full-width background of a code block, in container coordinates.
    func codeRect(for para: NSRange) -> NSRect? {
        guard let tc = textContainers.first, let used = usedRect(of: para) else { return nil }
        let out = Self.codeOutset
        return NSRect(x: -out, y: used.minY - out, width: tc.size.width + 2 * out, height: used.height + 2 * out)
    }

    /// Rows and column edges of a table, in container coordinates.
    func grid(for para: NSRange) -> NoteTextEngine.TableGrid? {
        guard let storage = textStorage, let tc = textContainers.first,
              let style = storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        let ns = storage.string as NSString
        var rows: [NSRect] = []
        var start = para.location
        for i in para.location..<NSMaxRange(para) where ns.character(at: i) == 0x2028 || i == NSMaxRange(para) - 1 {
            guard let r = usedRect(of: NSRange(location: start, length: i + 1 - start)) else { return nil }
            rows.append(r); start = i + 1
        }
        let pad = NoteBuffer.tableCellPadding
        let textStart = tc.lineFragmentPadding
        let stops = style.tabStops.map(\.location)
        let columnEdges = ([0] + stops).map { textStart + $0 - pad }
        let left = columnEdges[0], right = columnEdges[columnEdges.count - 1]
        // Every row spans the whole grid, so that its rect is the row of the grid and not the width of its text.
        return NoteTextEngine.TableGrid(rows: rows.map { NSRect(x: left, y: $0.minY, width: right - left, height: $0.height) },
                                        columnEdges: columnEdges)
    }
}
