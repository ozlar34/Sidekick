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

    /// Horizontal advance reserved for a checklist marker. The marker char is
    /// laid out as a control glyph (same mechanism as the link-chip anchor):
    /// the underlying `-` glyph is suppressed entirely and this width is what
    /// the typesetter reserves on the line. Sized to seat the 11pt drawn square
    /// (see `drawBackground`) with clear air before it; the remaining gap to the
    /// item text comes from the trailing space char. `checklistParagraphStyle`'s
    /// `headIndent` is matched to this width so wrapped lines align under the
    /// first-line content.
    static let checklistMarkerWidth: CGFloat = 14

    /// Frame of the drawn checklist square, in the marker glyph's line-fragment
    /// coordinate space. Single source of truth shared by `drawBackground`
    /// (painting) and `HybridTextView.mouseDown` (hit-testing) so the painted
    /// square and the tap zone can never drift apart.
    ///
    /// The square is centered on the text **cap-height** band rather than the
    /// full 20pt line box — centering on the line box leaves the square sitting
    /// visibly low relative to the adjacent content.
    static func checklistSquareRect(lineFragmentRect: NSRect,
                                    glyphLocation: NSPoint,
                                    markerFont: NSFont) -> NSRect {
        let squareSide: CGFloat = 11
        let x = lineFragmentRect.origin.x + glyphLocation.x
        let baselineY = lineFragmentRect.origin.y + glyphLocation.y
        let y = baselineY - markerFont.capHeight / 2 - squareSide / 2
        return NSRect(x: x, y: y, width: squareSide, height: squareSide)
    }

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
                    // Treat the marker char as a control glyph — same mechanism
                    // as the link-chip anchor. `.whitespace` (see `shouldUse`)
                    // suppresses the underlying `-` glyph entirely (so it no
                    // longer shows through the drawn square) and lets
                    // `boundingBoxForControlGlyphAt` reserve an exact advance
                    // width for the square plus its gap to the content.
                    prop.insert(.controlCharacter)
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
        // Both the link-chip anchor and the checklist marker are laid out as
        // control glyphs. `.whitespace` is the action that makes the typesetter
        // consult `boundingBoxForControlGlyphAt` for a custom advance width.
        if attrs[.sidekickLinkChip] != nil || attrs[.sidekickChecklistMarker] != nil {
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

        // Checklist marker: reserve a fixed advance for the drawn square. The
        // box is anchored at the glyph origin; height matches the line so the
        // square (painted in `drawBackground`) seats inside the line box.
        if attrs[.sidekickChecklistMarker] != nil {
            return CGRect(x: 0, y: 0, width: Self.checklistMarkerWidth, height: proposedRect.height)
        }

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

            // Find the line fragment to draw the hairline in. Anchor on the
            // HR paragraph's TRAILING newline (the char immediately after the
            // dash run), not the first dash. Why: in some glyph-layout paths
            // (notably the full-text-replace path on note switch), the HR's
            // .null dash glyphs get absorbed into the line fragment of the
            // PRECEDING empty paragraph instead of starting a new line —
            // chars `\n---` end up sharing one fragment with the dashes'
            // trailing `\n` orphaned on its own next-line fragment. Anchoring
            // on the trailing `\n` follows the HR's true paragraph and
            // sidesteps that layout quirk. In the typed-incrementally path
            // (where dashes generate their own line fragment normally), the
            // trailing `\n` is in the SAME fragment as the dashes, so the
            // anchor yields identical geometry. Either way the hairline lands
            // on the HR's own line, never the line above.
            let trailingNewlineChar = attrRange.location + attrRange.length
            let anchorGlyphIndex: Int
            if trailingNewlineChar < storage.length {
                anchorGlyphIndex = self.glyphIndexForCharacter(at: trailingNewlineChar)
            } else {
                // HR is at end-of-buffer with no trailing newline — fall back
                // to the dash run's own first glyph.
                anchorGlyphIndex = runGlyphRange.location
            }

            let lineRect = self.lineFragmentUsedRect(
                forGlyphAt: anchorGlyphIndex,
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
            let markerFont = (storage.attribute(.font, at: attrRange.location, effectiveRange: nil) as? NSFont)
                ?? NSFont.systemFont(ofSize: 15)

            // UI-SPEC geometry (locked): 11×11pt square, 2pt corner radius.
            // Frame comes from the shared helper so painting and hit-testing
            // (HybridTextView.mouseDown) use identical geometry.
            let cornerRadius: CGFloat = 2
            let squareRect = Self.checklistSquareRect(
                lineFragmentRect: lineRect,
                glyphLocation: glyphLocation,
                markerFont: markerFont
            ).offsetBy(dx: origin.x, dy: origin.y)

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
