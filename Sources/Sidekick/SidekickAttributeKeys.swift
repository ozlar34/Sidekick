/// Custom NSAttributedString keys used inside Sidekick's hybrid markdown
/// editor. One key per purpose; all strings namespaced with "sidekick" to
/// avoid colliding with AppKit-defined keys. Grow this file only when a
/// second custom key is genuinely needed — loose coupling between
/// MarkdownTextStorage (sets the key) and MarkdownLayoutManager (reads it)
/// is the whole point.
///
/// Pattern source: AppKit NSAttributedString.Key extension convention.
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md D-MH-02.
import AppKit

extension NSAttributedString.Key {
    /// Marks a run of characters as a markdown syntax marker (e.g. the `**`
    /// in `**bold**`). `MarkdownLayoutManager.setGlyphs(...)` reads this
    /// attribute during glyph generation and sets NSGlyphProperty.null on
    /// the corresponding glyphs, hiding them visually without mutating the
    /// underlying text storage. Round-trip to disk is preserved because the
    /// characters remain in the buffer.
    static let sidekickHiddenMarker = NSAttributedString.Key("sidekickHiddenMarker")
}
