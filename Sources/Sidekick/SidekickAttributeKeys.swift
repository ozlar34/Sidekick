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

    /// Marks a bullet-list marker character (`-` or `*` at line start) for
    /// glyph substitution. `MarkdownLayoutManager.setGlyphs(...)` replaces
    /// the dash/star glyph with U+2022 BULLET (`•`) from the same font so
    /// the user sees a visible bullet without mutating the underlying bytes.
    /// The trailing space after the marker stays visible (not tagged) so
    /// the rendered result is `• item` instead of the tight `•item`.
    static let sidekickBulletMarker = NSAttributedString.Key("sidekickBulletMarker")

    /// Marks the `-` character of a GFM task-list line (`- [ ] ` / `- [x] `)
    /// for glyph substitution. Value is `Bool` — `false` substitutes U+25EF
    /// (◯ unchecked), `true` substitutes U+25C9 (◉ checked).
    /// `MarkdownLayoutManager.setGlyphs(...)` reads the bool and picks the
    /// glyph; the surrounding ` [ ]` / ` [x]` chars are hidden via
    /// `.sidekickHiddenMarker` so the rendered result is `◯ item` / `◉ item`
    /// without mutating the underlying bytes (round-trip safe).
    /// Mouse hits on this marker character flip the underlying ` ` ↔ `x` byte.
    static let sidekickChecklistMarker = NSAttributedString.Key("sidekickChecklistMarker")

    /// Marks the `N.` prefix of a numbered list line (`\d+\.` at line start).
    /// Value is `Bool` (`true`). MarkdownTextStorage applies
    /// `NSColor.secondaryLabelColor` to this range so the marker is visually
    /// distinct from plain `1.` typed inline. The color is cleared by
    /// `clearManagedAttributes` via its global `.foregroundColor` reset.
    static let sidekickNumberedMarker = NSAttributedString.Key("sidekickNumberedMarker")

    /// Marks the FIRST character of a URL run that should render as a single
    /// "link chip" pill (bare URLs, and `[url](url)` markdown links where the
    /// label equals the URL). Value is `String` — the display text shown
    /// inside the pill (URL with `https?://`, leading `www.`, trailing `/`
    /// stripped). The remaining URL characters carry `.sidekickHiddenMarker`
    /// so they collapse to zero-width invisible glyphs.
    ///
    /// `MarkdownLayoutManager` keeps the chip-anchor glyph visible by marking
    /// it as `.controlCharacter` (instead of `.null`) in `setGlyphs(...)`,
    /// then — acting as its own `NSLayoutManagerDelegate` — returns a custom
    /// bounding box wide enough to fit the display text. The pill background
    /// and label are painted in `drawBackground(forGlyphRange:at:)`.
    ///
    /// Source bytes survive round-trip (D-T-03): only attributes change, the
    /// full URL stays in the buffer. Native caret navigation steps through
    /// the hidden chars one at a time (D-MH-03).
    static let sidekickLinkChip = NSAttributedString.Key("sidekickLinkChip")

    /// Marks a markdown thematic-break line (`---` / `***` / `___` standalone).
    /// Value is `Bool` (`true`). MarkdownTextStorage tags the line content
    /// range and dims it to tertiary; MarkdownLayoutManager reads this attribute
    /// in `drawBackground(forGlyphRange:at:)` to draw a 1pt hairline horizontally
    /// across the line's used rect. Source bytes stay intact — the dashes still
    /// round-trip to disk (D-T-03), they're just visually muted underneath the
    /// rendered hairline.
    static let sidekickThematicBreak = NSAttributedString.Key("sidekickThematicBreak")
}
