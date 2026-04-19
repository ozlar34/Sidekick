/// NSTextStorage subclass that owns the hybrid markdown editor's text +
/// attribute state. Overrides the four required NSTextStorage methods
/// (string / attributes / replaceCharacters / setAttributes) backed by an
/// internal NSMutableAttributedString. On each edit, processEditing()
/// reparses ONLY the edited paragraph — expanded to fenced-code-block
/// boundaries — and applies .sidekickHiddenMarker to syntax markers +
/// visible attributes (bold / italic / mono / heading sizes / code block
/// background) to content.
///
/// Round-trip invariant: storage.string is always byte-identical to the
/// concatenation of user edits. We NEVER mutate the backing string to
/// "hide" markers — invisibility is purely a layout-time concern
/// (see MarkdownLayoutManager).
///
/// Pattern source: FormattingToolbarView.swift (UTF-16 discipline + NSString
/// line/paragraph arithmetic), PerformWrapTests.swift (windowless AppKit test
/// pattern — used by the companion test file).
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md
///   D-ES-02 (storage owns both text + attributes),
///   D-PS-02 (paragraph-range + fence-expansion reparse),
///   D-PS-03 (fenced code block as paragraph-style block),
///   D-MH-02 (.sidekickHiddenMarker attribute key),
///   D-T-03 (byte-identical round trip).
import AppKit

class MarkdownTextStorage: NSTextStorage {

    private let backing = NSMutableAttributedString()

    // MARK: - Required overrides (NSTextStorage subclass contract)

    override var string: String { backing.string }

    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        let delta = (str as NSString).length - range.length
        edited(.editedCharacters, range: range, changeInLength: delta)
        endEditing()
    }

    override func setAttributes(
        _ attrs: [NSAttributedString.Key: Any]?,
        range: NSRange
    ) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: - Edit callback — reparse the edited paragraph

    override func processEditing() {
        // Apply attributes BEFORE super.processEditing() per NSTextStorage
        // contract: layout managers are notified of the edit by super, and
        // that notification must reflect all attribute mutations from this
        // edit pass. Calling super first means layout managers see a stale
        // view and attribute-only addAttribute calls inside applyAttributes
        // land outside the edit's atomic notification window.
        if backing.length > 0 {
            applyAttributes(forEditedRange: editedRange)
        }
        super.processEditing()
    }

    // MARK: - Parser → attribute application

    /// Compute the reparse range and apply all markdown attributes within it.
    ///
    /// Implementation notes:
    ///   1. Order matters: fenced blocks first (they own their region), then
    ///      headings/bullets/bold/italic/inline-code. This matches CommonMark
    ///      block-before-inline precedence and ensures the code-font set by
    ///      fenced blocks isn't overwritten by bold/italic scanners.
    ///   2. Our parsers are total functions (return [] on error rather than
    ///      throwing), so the catch below is defensive only. If a future
    ///      parser ever throws, the fallback clears attributes and NSLogs.
    private func applyAttributes(forEditedRange editedRange: NSRange) {
        let ns = backing.string as NSString

        // Compute the reparse range: paragraph-containing-edit (D-PS-02),
        // expanded to any fenced-code-block that the edit touches.
        let paragraphRange = ns.paragraphRange(for: editedRange)
        let reparseRange = expandToEnclosingFence(paragraphRange, in: ns)

        // Guard: reparseRange must be within the backing store's bounds.
        guard reparseRange.location >= 0,
              reparseRange.location + reparseRange.length <= backing.length else {
            NSLog("[Sidekick] markdown parse error: reparseRange \(reparseRange) out of bounds for length \(backing.length)")
            return
        }

        // 1) Clear all Sidekick-managed attributes on the reparse range so
        //    deletions / pair-closures correctly un-hide / un-style.
        clearManagedAttributes(in: reparseRange)

        // 2) Run the six parsers against the REPARSE RANGE SUBSTRING.
        //    All parser outputs are NSRanges against `substring`; shift by
        //    `base` before applying to backing storage (D-PS-02).
        let substring = ns.substring(with: reparseRange)
        let base = reparseRange.location

        // Defensive catch: since all six parsers are total functions, this
        // catch is a belt-and-suspenders guard against future throwing changes.
        // If it fires, bytes are preserved — only attributes are cleared.
        do {
            // Apply in block-before-inline order (fenced wins over inline):
            // fenced code first (block), then headings/bullets (block-level),
            // then bold/italic/inline-code (inline). Inline code is applied
            // last among inline constructs so `code` inside `**bold**` text
            // preserves the monospaced font over the bold font.
            try applyFenced(in: substring, offset: base)
            try applyHeadings(in: substring, offset: base)
            try applyBullets(in: substring, offset: base)
            try applyBold(in: substring, offset: base)
            try applyItalic(in: substring, offset: base)
            try applyInlineCode(in: substring, offset: base)
        } catch {
            // Parser failure fallback: clear attributes on the edited range
            // (leave bytes intact — STORAGE-01 / D-T-03 round-trip is sacred).
            NSLog("[Sidekick] markdown parse error at range \(editedRange): \(error.localizedDescription)")
            clearManagedAttributes(in: reparseRange)
        }
    }

    /// Expand `range` to include the full fenced-code-block if the edit overlaps
    /// one. This scan is O(document lines) and runs at most once per keystroke —
    /// acceptable for Sidekick's use case (notes are tens of paragraphs, not books).
    ///
    /// Fence-expansion guard: if the edit caret is exactly at the end of a fence,
    /// we still expand — the guard `range.location == fenceWhole.location + fenceWhole.length`
    /// handles that caret-at-end case (D-PS-02 requirement).
    private func expandToEnclosingFence(_ range: NSRange, in ns: NSString) -> NSRange {
        let fences = MarkdownInlineParser.findFencedCodeBlocks(in: ns as String)
        for f in fences {
            let fenceWhole = NSUnionRange(NSUnionRange(f.fenceOpenRange, f.contentRange), f.fenceCloseRange)
            if NSIntersectionRange(fenceWhole, range).length > 0
               || range.location == fenceWhole.location + fenceWhole.length {
                return NSUnionRange(range, fenceWhole)
            }
        }
        return range
    }

    /// Clear all Sidekick-managed attributes (font, background, hidden-marker)
    /// on `range` before re-applying. Stale attributes from deleted markers
    /// (e.g. typing `**foo**` then deleting the closing `**`) are cleared here
    /// so the storage never leaks bold/italic styling into plain text.
    private func clearManagedAttributes(in range: NSRange) {
        backing.removeAttribute(.sidekickHiddenMarker, range: range)
        backing.removeAttribute(.sidekickBulletMarker, range: range)
        backing.removeAttribute(.backgroundColor, range: range)
        backing.removeAttribute(.paragraphStyle, range: range)
        // Reset font to the base monospaced 14pt editor font, matching
        // EditorPaneView.swift:74 (.system(size: 14, design: .monospaced)).
        // Do NOT use 16pt — that's the preview reader font (PATTERNS.md line 477).
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        backing.addAttribute(.font, value: baseFont, range: range)
        // Pin foreground to NSColor.textColor so it stays dynamic across
        // light/dark appearance and persists across note-switch full-text
        // replaces. Without this, text inserted by updateNSView has no
        // foregroundColor attribute and can render with a stale cached
        // value baked in at the previous appearance.
        backing.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
    }

    // MARK: - Per-construct attribute writers

    /// Apply bold styling: semibold font on content, .sidekickHiddenMarker on `**` markers.
    /// Font weight: NSFont.systemFont(ofSize: 14, weight: .semibold) — matches Theme.sidekick.
    private func applyBold(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findBoldRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            backing.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                 range: content)
        }
    }

    /// Apply italic styling: italic font trait on content, .sidekickHiddenMarker on `*`/`_` markers.
    /// Uses NSFontManager to convert the base mono font to italic trait.
    private func applyItalic(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findItalicRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            let base = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            backing.addAttribute(.font, value: italic, range: content)
        }
    }

    /// Apply inline code styling: monospaced 0.9em font + separator-color background.
    /// Inline code is applied last among inline constructs so the code font wins
    /// over bold/italic when inline code overlaps (CommonMark: code spans win).
    private func applyInlineCode(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findInlineCodeRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            backing.addAttribute(.font,
                                 value: NSFont.monospacedSystemFont(ofSize: 14 * 0.9, weight: .regular),
                                 range: content)
            backing.addAttribute(.backgroundColor,
                                 value: NSColor.separatorColor.withAlphaComponent(0.15),
                                 range: content)
        }
    }

    /// Apply heading styling: level-specific font size on content, .sidekickHiddenMarker on `# ` prefix.
    /// H1: bold 1.5em, H2: semibold 1.25em, H3–H6: semibold 14pt (Theme parity table, PATTERNS.md:470-474).
    private func applyHeadings(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findHeadingPrefixes(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.prefixRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            let font: NSFont
            switch m.level {
            case 1:        font = NSFont.systemFont(ofSize: 14 * 1.5, weight: .bold)
            case 2:        font = NSFont.systemFont(ofSize: 14 * 1.25, weight: .semibold)
            case 3, 4, 5, 6: font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            default:       font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            }
            backing.addAttribute(.font, value: font, range: content)
        }
    }

    /// Apply bullet styling: .sidekickHiddenMarker on the `- `/`* ` prefix + NSTextList
    /// paragraph style on the whole line so NSLayoutManager renders a visible `•` glyph.
    ///
    /// HYBRID-06: the visible bullet comes from NSParagraphStyle.textLists so the raw
    /// `- ` / `* ` characters are hidden (sidekickHiddenMarker) without mutating the buffer.
    /// The pair: hidden raw prefix + visible NSTextList disc bullet = round-trip safe.
    private func applyBullets(in substring: String, offset: Int) throws {
        let prefixes = MarkdownInlineParser.findBulletPrefixes(in: substring)
        for prefixRange in prefixes {
            let shifted = shift(prefixRange, by: offset)
            // prefixRange covers `- ` or `* ` (two chars). Tag ONLY the
            // dash/star char with .sidekickBulletMarker so the layout
            // manager substitutes its glyph with U+2022 BULLET. Leave the
            // trailing space visible so the rendered output is `• item`
            // (bullet + space + text) instead of the too-tight `•item`.
            // Round-trip stays byte-identical because we never mutate bytes.
            guard shifted.length >= 1,
                  shifted.location >= 0,
                  shifted.location + 1 <= backing.length else { continue }
            let markerRange = NSRange(location: shifted.location, length: 1)
            backing.addAttribute(.sidekickBulletMarker, value: true, range: markerRange)
        }
    }

    /// Apply fenced-code-block styling: .sidekickHiddenMarker on fence lines,
    /// monospaced font + separator-color background (0.1 alpha) on content.
    /// Fences are applied FIRST in applyAttributes() so later inline parsers
    /// do not overwrite the monospaced font inside fenced blocks.
    private func applyFenced(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findFencedCodeBlocks(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.fenceOpenRange, by: offset)
            tagHiddenMarker(shifting: m.fenceCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            // Only apply content attributes if content is non-empty.
            if content.length > 0 {
                backing.addAttribute(.font,
                                     value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                     range: content)
                backing.addAttribute(.backgroundColor,
                                     value: NSColor.separatorColor.withAlphaComponent(0.1),
                                     range: content)
            }
        }
    }

    // MARK: - Helpers

    /// Tag a range (relative to substring at `offset`) with .sidekickHiddenMarker.
    /// Includes a bounds guard (T-09-10 mitigation) so an out-of-bounds parser
    /// range can never crash the storage.
    private func tagHiddenMarker(shifting r: NSRange, by offset: Int) {
        let shifted = NSRange(location: r.location + offset, length: r.length)
        guard shifted.location >= 0,
              shifted.length > 0,
              shifted.location + shifted.length <= backing.length else { return }
        backing.addAttribute(.sidekickHiddenMarker, value: true, range: shifted)
    }

    /// Shift an NSRange by `offset` (converts a parser-relative range to a
    /// full-document range in the backing store).
    private func shift(_ r: NSRange, by offset: Int) -> NSRange {
        NSRange(location: r.location + offset, length: r.length)
    }
}
