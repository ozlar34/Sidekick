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
                let indent = (lm as? NoteLayoutManager).map { $0.tailIndent(blockIndex: (tv.string as NSString).components(separatedBy: "\n").count - 1) } ?? 0
                rect = NSRect(x: extra.minX + tc.lineFragmentPadding + indent, y: extra.minY, width: 1, height: extra.height)
            } else {
                let g = lm.numberOfGlyphs - 1
                // The end of the text on its line (the used rect ends one padding past it). (The last glyph's bounding box is not it: for a heading it
                // reaches past the text, by a constant that does not depend on the text.)
                let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
                rect = NSRect(x: used.maxX - tc.lineFragmentPadding, y: used.minY, width: 1, height: used.height)
            }
        } else {
            let g = lm.glyphIndexForCharacter(at: location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: g)
            // An empty line has no used width; its caret sits at the padded left edge plus the paragraph's indent.
            // (The glyph location is measured from the fragment edge and already holds padding and indent.)
            let indent = (tv.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
            let x = used.width == 0 ? frag.minX + tc.lineFragmentPadding + indent : frag.minX + loc.x
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

    // MARK: Block markers

    /// One drawn block marker: bullet, number or checkbox of the paragraph that starts at `start`
    /// (`start == string length` for the empty last paragraph). `rect` is the marker's frame in view coordinates;
    /// for a checkbox it is also the click target.
    struct Marker: Equatable {
        enum Shape: Equatable { case bullet, number(String), checkbox(checked: Bool) }
        var start: Int
        var shape: Shape
        var rect: NSRect
    }

    /// Kind of the empty last paragraph (it has no character to carry one) and the literal number of the
    /// document block at an index, with its delimiter (`7.`, `3)`), exactly as the file spells it.
    static func configure(_ tv: NSTextView, tailKind: BlockKind, markerText: @escaping (Int) -> String?) {
        guard let lm = tv.layoutManager as? NoteLayoutManager else { return }
        lm.markerText = markerText
        setTailKind(tailKind, in: tv)
    }

    static func setTailKind(_ kind: BlockKind, in tv: NSTextView) {
        guard let lm = tv.layoutManager as? NoteLayoutManager, lm.tailKind != kind else { return }
        lm.tailKind = kind
        tv.needsDisplay = true
    }

    /// Every drawn marker, in document order.
    static func markers(in tv: NSTextView) -> [Marker] {
        guard let lm = tv.layoutManager as? NoteLayoutManager, let tc = tv.textContainer else { return [] }
        lm.ensureLayout(for: tc)
        let origin = tv.textContainerOrigin
        return lm.markers(in: NSRange(location: 0, length: lm.numberOfGlyphs)).map { m in
            var m = m; m.rect = m.rect.offsetBy(dx: origin.x, dy: origin.y); return m
        }
    }

    /// Start of the paragraph whose drawn checkbox contains `point` (view coordinates), if any.
    static func checkbox(in tv: NSTextView, at point: NSPoint) -> (start: Int, checked: Bool)? {
        for m in markers(in: tv) {
            if case .checkbox(let checked) = m.shape, m.rect.insetBy(dx: -2, dy: -2).contains(point) { return (m.start, checked) }
        }
        return nil
    }
}

/// Draws the markers that are not characters: bullet, number, checkbox. They come from each paragraph's block kind
/// and leave no trace in the text, the caret positions or the file.
@MainActor
final class NoteLayoutManager: NSLayoutManager {
    var tailKind: BlockKind = .paragraph
    var markerText: (Int) -> String? = { _ in nil }

    private static let markerFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        private static let squareSide: CGFloat = 11

    /// Baseline of the first line of a paragraph with a 20 pt line box and 15 pt body font.
    private func baseline(ofLineAt frag: NSRect, glyph: Int?) -> CGFloat {
        if let g = glyph, g < numberOfGlyphs { return frag.minY + location(forGlyphAt: g).y }
        let f = NoteBuffer.numberFont
        return frag.minY + (frag.height - (f.ascender - f.descender)) / 2 + f.ascender
    }

    /// Text indent of the empty last paragraph.
    func tailIndent(blockIndex: Int) -> CGFloat {
        tailKind == .numbered ? NoteBuffer.numberIndent(for: markerText(blockIndex) ?? "1.") : NoteBuffer.indent(for: tailKind)
    }

    func markers(in glyphRange: NSRange) -> [NoteTextEngine.Marker] {
        guard let storage = textStorage, let tc = textContainers.first else { return [] }
        var out: [NoteTextEngine.Marker] = []
        let ns = storage.string as NSString
        func marker(kind: BlockKind, start: Int, frag: NSRect, glyph: Int?, paragraphIndex: () -> Int) {
            let padding = tc.lineFragmentPadding
            let x = frag.minX + padding
            let base = baseline(ofLineAt: frag, glyph: glyph)
            switch kind {
            case .bullet:
                let f = Self.markerFont
                out.append(.init(start: start, shape: .bullet, rect: NSRect(x: x, y: base - f.ascender, width: 8, height: f.ascender - f.descender)))
            case .numbered:
                let f = NoteBuffer.numberFont
                let text = markerText(paragraphIndex()) ?? "1."
                out.append(.init(start: start, shape: .number(text),
                                 rect: NSRect(x: x, y: base - f.ascender, width: NoteBuffer.numberWidth(text), height: f.ascender - f.descender)))
            case .checklist(let checked):
                let side = Self.squareSide
                out.append(.init(start: start, shape: .checkbox(checked: checked),
                                 rect: NSRect(x: x, y: base - Self.markerFont.capHeight / 2 - side / 2, width: side, height: side)))
            default: break
            }
        }
        if ns.length > 0 {
            let chars = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var loc = chars.location
            var newlines: Int?   // paragraph index of `loc`, counted lazily
            var counted = 0
            while loc < min(ns.length, NSMaxRange(chars)) {
                let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let kind = NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: para.location, effectiveRange: nil))
                if para.location >= chars.location {
                    let g = glyphIndexForCharacter(at: para.location)
                    let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                    marker(kind: kind, start: para.location, frag: frag, glyph: g) {
                        if newlines == nil { newlines = 0; counted = 0 }
                        for i in counted..<para.location where ns.character(at: i) == 0x0A { newlines! += 1 }
                        counted = para.location
                        return newlines!
                    }
                }
                loc = NSMaxRange(para)
            }
        }
        // The empty last paragraph has no glyph; its line is the extra line fragment.
        if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A, tailKind != .paragraph {
            let extra = extraLineFragmentRect
            if extra.height > 0 {
                marker(kind: tailKind, start: ns.length, frag: extra, glyph: nil) { ns.components(separatedBy: "\n").count - 1 }
            }
        }
        return out
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawCodeAndTables(forGlyphRange: glyphsToShow, at: origin)
        for m in markers(in: glyphsToShow) {
            let rect = m.rect.offsetBy(dx: origin.x, dy: origin.y)
            switch m.shape {
            case .bullet:
                ("\u{2022}" as NSString).draw(at: rect.origin, withAttributes: [.font: Self.markerFont, .foregroundColor: NSColor.textColor])
            case .number(let text):
                (text as NSString).draw(at: rect.origin, withAttributes: [.font: NoteBuffer.numberFont, .foregroundColor: NSColor.secondaryLabelColor])
            case .checkbox(let checked):
                NSGraphicsContext.current?.saveGraphicsState()
                let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                path.lineWidth = 1
                if checked {
                    NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
                    path.fill()
                    NSColor.separatorColor.setStroke()
                    path.stroke()
                    let check = NSBezierPath()
                    check.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 5))
                    check.line(to: NSPoint(x: rect.minX + 4, y: rect.minY + 8))
                    check.line(to: NSPoint(x: rect.minX + 9, y: rect.minY + 2))
                    check.lineWidth = 1.5
                    NSColor.textColor.setStroke()
                    check.stroke()
                } else {
                    NSColor.separatorColor.setStroke()
                    path.stroke()
                }
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        }
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
extension NoteLayoutManager {
    private static let codeOutset: CGFloat = 4

    func drawCodeAndTables(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
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
