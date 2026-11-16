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
                let indent = (lm as? NoteLayoutManager).map { NoteBuffer.indent(for: $0.tailKind) } ?? 0
                rect = NSRect(x: extra.minX + tc.lineFragmentPadding + indent, y: extra.minY, width: 1, height: extra.height)
            } else {
                let g = lm.numberOfGlyphs - 1
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                // The end of the used rect less the right padding. (The bounding box of a glyph is not usable on a line
                // that holds an attachment, a pill: it comes back as the box of the whole run.)
                let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
                rect = NSRect(x: used.maxX - tc.lineFragmentPadding, y: frag.minY, width: 1, height: frag.height)
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

    // MARK: Links and pills

    /// A link or a pill that answers to Cmd+click and hover: where it is drawn (one rect per line it spans)
    /// and the address it opens.
    struct HoverTarget: Equatable {
        var range: NSRange
        var address: String
        var rects: [NSRect]
    }

    /// Address of the link or pill character `index` stands for, if it is one.
    static func address(ofCharacterAt index: Int, in storage: NSTextStorage) -> String? {
        guard index >= 0, index < storage.length, let style = storage.attribute(.noteStyle, at: index, effectiveRange: nil) as? NoteRunStyle else { return nil }
        if style.pill != nil, (storage.string as NSString).character(at: index) == 0xFFFC { return style.pillText }
        return style.link
    }

    /// The link or pill drawn at `point` (view coordinates): its address. Nil for anything else, also for the empty
    /// space after a line.
    static func address(in tv: NSTextView, at point: NSPoint) -> String? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage, storage.length > 0 else { return nil }
        let origin = tv.textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs, lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        return address(ofCharacterAt: lm.characterIndexForGlyph(at: glyph), in: storage)
    }

    /// Every link and pill (`visible` limits them to what is on screen), in document order.
    static func hoverTargets(in tv: NSTextView, visibleOnly visible: Bool = false) -> [HoverTarget] {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage, storage.length > 0 else { return [] }
        let origin = tv.textContainerOrigin
        var chars = NSRange(location: 0, length: storage.length)
        if visible {
            let area = tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            chars = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: area, in: tc), actualGlyphRange: nil)
        } else {
            lm.ensureLayout(for: tc)
        }
        var out: [HoverTarget] = []
        storage.enumerateAttribute(.noteStyle, in: chars, options: []) { value, range, _ in
            guard let style = value as? NoteRunStyle, style.link != nil || style.pill != nil else { return }
            var pieces = [range]
            if style.pill != nil { pieces = (range.location..<NSMaxRange(range)).filter { address(ofCharacterAt: $0, in: storage) != nil }.map { NSRange(location: $0, length: 1) } }
            for piece in pieces {
                guard let address = address(ofCharacterAt: piece.location, in: storage) else { continue }
                var rects: [NSRect] = []
                let glyphs = lm.glyphRange(forCharacterRange: piece, actualCharacterRange: nil)
                lm.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(lineGlyphs, glyphs)
                    guard part.length > 0 else { return }
                    rects.append(lm.boundingRect(forGlyphRange: part, in: tc).offsetBy(dx: origin.x, dy: origin.y))
                }
                if !rects.isEmpty { out.append(HoverTarget(range: piece, address: address, rects: rects)) }
            }
        }
        return out
    }

    // MARK: Block markers

    /// One drawn block marker: bullet, number or checkbox of the paragraph that starts at `start`
    /// (`start == string length` for the empty last paragraph). `rect` is the marker's frame in view coordinates;
    /// for a checkbox it is also the click target.
    struct Marker: Equatable {
        enum Shape: Equatable { case bullet, number(String), checkbox(checked: Bool), divider }
        var start: Int
        var shape: Shape
        var rect: NSRect
    }

    /// Kind of the empty last paragraph (it has no character to carry one) and the literal number of the
    /// document block at an index (for lists that start at a number other than 1).
    static func configure(_ tv: NSTextView, tailKind: BlockKind, startNumber: @escaping (Int) -> Int?) {
        guard let lm = tv.layoutManager as? NoteLayoutManager else { return }
        lm.startNumber = startNumber
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
    var startNumber: (Int) -> Int? = { _ in nil }

    private static let markerFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let numberFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let squareSide: CGFloat = 11

    /// Baseline of the first line of a paragraph with a 20 pt line box and 15 pt body font.
    private func baseline(ofLineAt frag: NSRect, glyph: Int?) -> CGFloat {
        if let g = glyph, g < numberOfGlyphs { return frag.minY + location(forGlyphAt: g).y }
        let f = Self.numberFont
        return frag.minY + (frag.height - (f.ascender - f.descender)) / 2 + f.ascender
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
                let f = Self.numberFont
                out.append(.init(start: start, shape: .number(numberText(at: start, paragraphIndex: paragraphIndex())),
                                 rect: NSRect(x: x, y: base - f.ascender, width: NoteBuffer.indent(for: kind), height: f.ascender - f.descender)))
            case .checklist(let checked):
                let side = Self.squareSide
                out.append(.init(start: start, shape: .checkbox(checked: checked),
                                 rect: NSRect(x: x, y: base - Self.markerFont.capHeight / 2 - side / 2, width: side, height: side)))
            case .divider:   // a hairline across the text width, centred on its (empty) line
                out.append(.init(start: start, shape: .divider,
                                 rect: NSRect(x: x, y: frag.midY - 0.5, width: max(0, tc.size.width - padding * 2), height: 1)))
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

    /// The number shown for the numbered paragraph at `start`: the literal number of the first item of its run
    /// plus the items before it.
    private func numberText(at start: Int, paragraphIndex: Int) -> String {
        guard let storage = textStorage else { return "1." }
        let ns = storage.string as NSString
        var before = 0
        var p = start
        while p > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: p - 1, length: 0))
            guard NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: prev.location, effectiveRange: nil)) == .numbered else { break }
            before += 1; p = prev.location
        }
        let first = startNumber(paragraphIndex - before) ?? 1
        return "\(first + before)."
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        for m in markers(in: glyphsToShow) {
            let rect = m.rect.offsetBy(dx: origin.x, dy: origin.y)
            switch m.shape {
            case .bullet:
                ("\u{2022}" as NSString).draw(at: rect.origin, withAttributes: [.font: Self.markerFont, .foregroundColor: NSColor.textColor])
            case .number(let text):
                (text as NSString).draw(at: rect.origin, withAttributes: [.font: Self.numberFont, .foregroundColor: NSColor.secondaryLabelColor])
            case .divider:
                NSColor.tertiaryLabelColor.setFill()
                rect.fill()
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
