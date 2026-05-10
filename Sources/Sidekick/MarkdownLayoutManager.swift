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

final class MarkdownLayoutManager: NSLayoutManager {

    override init() {
        super.init()
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

        // Precompute checklist glyphs. The SF system font (used by storage at
        // 15pt bold) does NOT ship U+25EF LARGE CIRCLE or U+25C9 FISHEYE — both
        // resolve to glyph 0, which silently falls through and renders the raw
        // `-` instead. We use ○ U+25CB / ● U+25CF (both present in SF Pro)
        // with ☐/☑ ballot boxes as a defensive cascade for any future font
        // that lacks even those.
        func resolve(_ scalars: [UniChar]) -> CGGlyph {
            for var s in scalars {
                var g: CGGlyph = 0
                CTFontGetGlyphsForCharacters(font as CTFont, &s, &g, 1)
                if g != 0 { return g }
            }
            return 0
        }
        let checklistEmptyGlyph = resolve([0x25CB, 0x25EF, 0x2610])
        let checklistFilledGlyph = resolve([0x25CF, 0x25C9, 0x2611])

        for i in 0..<count {
            var prop = properties[i]
            let charIndex = characterIndexes[i]
            if charIndex < storage.length {
                let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
                if let checked = attrs[.sidekickChecklistMarker] as? Bool {
                    // Substitute the dash with ◯ (unchecked) or ◉ (checked).
                    // Keep visible — do NOT set .null.
                    let target = checked ? checklistFilledGlyph : checklistEmptyGlyph
                    if target != 0 {
                        mutableGlyphs[i] = target
                    }
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
    }
}
