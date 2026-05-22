/// NSLayoutManager subclass for Sidekick's hybrid markdown editor.
///
/// Reads the .sidekickHiddenMarker temporary attribute from self.textStorage
/// during glyph generation and sets NSLayoutManager.GlyphProperty.null on
/// the corresponding glyphs. `.null` produces a zero-width, invisible glyph,
/// which hides markdown syntax markers (e.g. the `**` in `**bold**`) without
/// mutating the text bytes — round-trip to .md stays byte-identical.
///
/// Native caret navigation is preserved (D-MH-03): arrow keys step through
/// the hidden markers like any other character. No setSelectedRange override.
///
/// Pattern source: Apple "Text System Architecture" — setGlyphs override pattern.
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md D-MH-01, D-MH-02, D-MH-03.
import AppKit
import CoreText

final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {

    /// Font used to render link-chip pill text. Sized smaller than the 15pt
    /// body so the pill sits comfortably inside an 18pt line box.
    private static let chipFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    /// Horizontal padding inside the pill, per side.
    private static let chipHPad: CGFloat = 6
    /// Pill corner radius.
    private static let chipCorner: CGFloat = 4

    override init() {
        super.init()
        self.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func setGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) {
        // Fast path: no text storage yet, or zero-length glyph range.
        guard let storage = self.textStorage, glyphRange.length > 0 else {
            super.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            return
        }

        // Allocate mutable copies of both buffers — we may need to substitute
        // the glyph (bullet marker → •) in addition to hiding glyphs.
        let count = glyphRange.length
        let mutableProperties = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { mutableProperties.deallocate() }
        let mutableGlyphs = UnsafeMutablePointer<CGGlyph>.allocate(capacity: count)
        defer { mutableGlyphs.deallocate() }
        // Seed both buffers with the source values so any slot we don't
        // explicitly overwrite (e.g. charIndex >= storage.length) carries
        // the original bytes through instead of undefined memory.
        mutableGlyphs.update(from: glyphs, count: count)
        mutableProperties.update(from: properties, count: count)

        // Precompute the U+2022 BULLET glyph in the current font for bullet-
        // marker substitution. Looked up once per setGlyphs call.
        var bulletGlyph: CGGlyph = 0
        var bulletScalar: UniChar = 0x2022
        CTFontGetGlyphsForCharacters(font as CTFont, &bulletScalar, &bulletGlyph, 1)

        for i in 0..<count {
            var prop = properties[i]
            let charIndex = characterIndexes[i]
            if charIndex < storage.length {
                let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
                if attrs[.sidekickLinkChip] != nil {
                    // Link-chip anchor. Mark as control char so the
                    // typesetter consults our delegate `boundingBoxForControlGlyphAt`
                    // for a custom width — the chip then lays out as a
                    // single non-breakable unit. Do NOT set .null even
                    // if the same char also carries .sidekickHiddenMarker.
                    prop.insert(.controlCharacter)
                } else if attrs[.sidekickChecklistMarker] != nil {
                    // Marker glyph stays visible (non-null) so the typesetter reserves
                    // its advance width. The custom square is painted in drawBackground.
                    // D-03a: do NOT set .null; do NOT substitute glyph.
                } else if attrs[.sidekickBulletMarker] != nil {
                    // Substitute the dash/star glyph with a bullet glyph.
                    // Keep visible — do NOT set .null.
                    if bulletGlyph != 0 {
                        mutableGlyphs[i] = bulletGlyph
                    }
                } else if attrs[.sidekickHiddenMarker] != nil {
                    // OR in .null — preserves any existing property bits.
                    prop.insert(.null)
                }
            }
            mutableProperties[i] = prop
        }

        super.setGlyphs(UnsafePointer(mutableGlyphs), properties: UnsafePointer(mutableProperties), characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
    }

    // MARK: - Link-chip control-glyph delegate

    /// Whitespace-action the chip-anchor control glyph. `.whitespace` lets us
    /// return a custom bounding box from `boundingBoxForControlGlyphAt` —
    /// other actions (`.lineBreak`, `.paragraphBreak`) ignore the bbox.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = self.textStorage,
              charIndex < storage.length else { return action }
        let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
        if attrs[.sidekickLinkChip] != nil {
            return .whitespace
        }
        return action
    }

    /// Size the chip-anchor control glyph to fit its display text plus
    /// horizontal padding. Returning a rect wider than a single glyph's
    /// advance is what makes the typesetter reserve the full pill width on
    /// the line — and wrap the chip whole if it doesn't fit.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: CGRect,
        glyphPosition: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let storage = self.textStorage,
              charIndex < storage.length else { return .zero }
        let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
        guard let display = attrs[.sidekickLinkChip] as? String else { return .zero }

        let attrStr = NSAttributedString(
            string: display,
            attributes: [.font: Self.chipFont]
        )
        let textWidth = ceil(attrStr.size().width)
        let chipWidth = textWidth + Self.chipHPad * 2
        // Height matches the proposed line height so the pill aligns with
        // the surrounding body text vertically. Origin x relative to glyph
        // position — return a rect anchored at (0, 0) of the glyph origin.
        return CGRect(x: 0, y: 0, width: chipWidth, height: proposedRect.height)
    }

    /// Draw a horizontal hairline across any glyph range whose backing
    /// characters carry `.sidekickThematicBreak`. The base implementation
    /// handles `.backgroundColor`-driven block fills (used by inline code +
    /// fenced code blocks); we extend it to paint the thematic-break rule
    /// after super so the hairline sits on top of any background. Drawing
    /// in the layout manager (vs. an NSTextAttachment / glyph substitution)
    /// keeps the source bytes lossless — the `---` chars survive round-trip
    /// and the caret can still navigate them like any other text.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let storage = self.textStorage,
              let container = self.textContainers.first,
              storage.length > 0 else { return }

        // Walk the visible glyph range looking for runs flagged with
        // `.sidekickThematicBreak`. The attribute is applied at the storage
        // layer line-by-line so each contiguous run corresponds to one line.
        let charRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0,
              charRange.location + charRange.length <= storage.length else { return }

        storage.enumerateAttribute(
            .sidekickThematicBreak,
            in: charRange,
            options: []
        ) { value, attrRange, _ in
            guard (value as? Bool) == true,
                  attrRange.length > 0 else { return }

            let runGlyphRange = self.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
            guard runGlyphRange.length > 0 else { return }

            let lineRect = self.lineFragmentUsedRect(
                forGlyphAt: runGlyphRange.location,
                effectiveRange: nil
            )
            let inset = container.lineFragmentPadding
            let usableWidth = container.size.width - inset * 2
            // Center the hairline vertically inside the line rect.
            let hairlineHeight: CGFloat = 1
            let hairlineY = origin.y + lineRect.midY - hairlineHeight / 2
            let hairlineRect = NSRect(
                x: origin.x + inset,
                y: hairlineY,
                width: max(0, usableWidth),
                height: hairlineHeight
            )

            NSColor.separatorColor.setFill()
            hairlineRect.fill()
        }

        // Checklist marker squares — drawn after super, same pattern as link-chip pill.
        // D-03a: marker glyph stays visible; drawBackground paints the square on top.
        storage.enumerateAttribute(
            .sidekickChecklistMarker,
            in: charRange,
            options: []
        ) { value, attrRange, _ in
            guard let isChecked = value as? Bool,
                  attrRange.length > 0 else { return }

            let glyphRange = self.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            let lineRect = self.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let glyphLocation = self.location(forGlyphAt: glyphRange.location)

            // UI-SPEC geometry (locked): 11×11pt square, 2pt corner radius
            let squareSide: CGFloat = 11
            let cornerRadius: CGFloat = 2
            let squareX = origin.x + lineRect.origin.x + glyphLocation.x
            // Center vertically in the 20pt line box (bulletParagraphStyle min/maxLineHeight = 20)
            let baselineY = origin.y + lineRect.origin.y + glyphLocation.y
            let squareY = baselineY - squareSide * 0.75   // visual center; tune via manual test
            let squareRect = NSRect(x: squareX, y: squareY, width: squareSide, height: squareSide)

            NSGraphicsContext.current?.saveGraphicsState()

            let path = NSBezierPath(roundedRect: squareRect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = 1

            if isChecked {
                NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.stroke()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: squareRect.minX + 2, y: squareRect.minY + 5))
                check.line(to: NSPoint(x: squareRect.minX + 4, y: squareRect.minY + 8))
                check.line(to: NSPoint(x: squareRect.minX + 9, y: squareRect.minY + 2))
                check.lineWidth = 1.5
                NSColor.textColor.setStroke()
                check.stroke()
            } else {
                NSColor.separatorColor.setStroke()
                path.stroke()
            }

            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Link-chip pills. Drawn after super (which paints inline-code /
        // fenced-code block backgrounds) so the pill sits on top of any
        // background — though chips don't normally overlap code spans.
        storage.enumerateAttribute(
            .sidekickLinkChip,
            in: charRange,
            options: []
        ) { value, attrRange, _ in
            guard let display = value as? String,
                  attrRange.length > 0 else { return }

            let glyphRange = self.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            // Glyph origin within the line fragment, plus the line fragment
            // origin within the text container — sum them and shift by the
            // draw origin to get window-space.
            let lineRect = self.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let glyphLocation = self.location(forGlyphAt: glyphRange.location)
            let bbox = self.boundingRect(forGlyphRange: glyphRange, in: container)

            let chipFont = Self.chipFont
            let hPad = Self.chipHPad
            let corner = Self.chipCorner

            // Vertical: center the pill on the glyph baseline. The chip
            // visual height is the font's line height plus a small inset so
            // the pill has breathing room above ascenders and below descenders.
            let chipHeight = ceil(chipFont.ascender - chipFont.descender) + 4
            let baselineY = origin.y + lineRect.origin.y + glyphLocation.y
            let pillY = baselineY - chipFont.ascender - 2

            // Width: prefer the bbox from boundingRect (which reflects the
            // delegate-supplied control-glyph width). Fall back to a measured
            // text width if bbox is zero for any reason.
            let attrStr = NSAttributedString(
                string: display,
                attributes: [.font: chipFont]
            )
            let measuredWidth = ceil(attrStr.size().width) + hPad * 2
            let pillWidth = bbox.width > 0 ? bbox.width : measuredWidth
            let pillX = origin.x + lineRect.origin.x + glyphLocation.x

            let pillRect = NSRect(x: pillX, y: pillY, width: pillWidth, height: chipHeight)

            // Pill fill — secondary background so it reads as a chip, not a
            // selection / code block.
            let path = NSBezierPath(roundedRect: pillRect, xRadius: corner, yRadius: corner)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            // Label text inside the pill, vertically centered.
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: chipFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let labelSize = (display as NSString).size(withAttributes: labelAttrs)
            let labelX = pillRect.minX + hPad
            let labelY = pillRect.midY - labelSize.height / 2
            (display as NSString).draw(
                at: NSPoint(x: labelX, y: labelY),
                withAttributes: labelAttrs
            )
        }
    }
}
