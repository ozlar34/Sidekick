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

        // Allocate a mutable copy of the properties buffer. The parameter is
        // UnsafePointer (immutable) — we cannot mutate it in place. Per the
        // canonical Apple override pattern, allocate a parallel buffer,
        // copy, mutate, then pass to super.
        let count = glyphRange.length
        let mutableProperties = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { mutableProperties.deallocate() }

        for i in 0..<count {
            var prop = properties[i]
            let charIndex = characterIndexes[i]
            // Guard against OOB: charIndex must be < storage.length.
            if charIndex < storage.length {
                let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
                if attrs[.sidekickHiddenMarker] != nil {
                    // OR in .null — preserves any existing property bits.
                    prop.insert(.null)
                }
            }
            mutableProperties[i] = prop
        }

        super.setGlyphs(glyphs, properties: UnsafePointer(mutableProperties), characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
    }
}
