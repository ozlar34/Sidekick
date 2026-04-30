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

final class MarkdownTextStorage: NSTextStorage {

    private let backing = NSMutableAttributedString()

    /// Paragraph style applied to H1 paragraphs so the title line gets visible
    /// breathing room above the body. paragraphSpacing adds space *after* the
    /// paragraph, so attaching it to the H1 paragraph creates the gap before
    /// whatever follows. Re-applied on every edit pass via applyFirstLineH1
    /// and applyHeadings — clearManagedAttributes strips .paragraphStyle, so
    /// the re-application is what makes the gap survive edits elsewhere.
    private static let h1ParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 16
        // Absolute line-height clamp — see HybridEditorView.makeNSView for
        // the rationale (caret height tracks layout fragment height on
        // macOS 14+ via NSTextInsertionIndicator). 36pt over 28pt H1 gives
        // the title visible breathing room.
        style.minimumLineHeight = 36
        style.maximumLineHeight = 36
        return style
    }()

    /// Default paragraph style applied to every reparsed range in storage
    /// (before H1 optionally overrides on line 0 / heading paragraphs).
    /// Applied directly on storage rather than relying on
    /// `textView.defaultParagraphStyle` — the latter is unreliable in TextKit 1
    /// once storage starts setting its own paragraph styles anywhere, so we
    /// enforce the rhythm at the storage layer.
    static let bodyParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        // See HybridEditorView.makeNSView for why this is absolute (min==max)
        // instead of lineHeightMultiple — caret height tracks layout fragment
        // height on macOS 14+ (NSTextInsertionIndicator follows the layout
        // fragment), so a multiplier would inflate the caret rect with any
        // font that has airy intrinsic metrics. paragraphSpacing carries the
        // breathing-room budget instead, since it adds gap between paragraphs
        // without growing the line box.
        style.minimumLineHeight = 18
        style.maximumLineHeight = 18
        style.paragraphSpacing = 8
        return style
    }()

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
            // Always reapply first-line H1 after the paragraph reparse — the
            // reparse range is paragraph-scoped, so edits on later lines won't
            // touch line 0. Running this every pass keeps line 0's auto-H1
            // style consistent even as the edit happens elsewhere in the doc.
            applyFirstLineH1()
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
        // expanded to any fenced-code-block or table block that the edit touches.
        // Tables span multiple paragraphs (header / separator / body each get
        // their own paragraph break), so without expansion an edit on row N
        // would leave rows N±k carrying stale table styling.
        let paragraphRange = ns.paragraphRange(for: editedRange)
        let fenceExpanded = expandToEnclosingFence(paragraphRange, in: ns)
        let reparseRange = expandToEnclosingTable(fenceExpanded, in: ns)

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
            try applyTables(in: substring, offset: base)
            try applyBold(in: substring, offset: base)
            try applyItalic(in: substring, offset: base)
            try applyInlineCode(in: substring, offset: base)
            try applyLinks(in: substring, offset: base)   // D-LR-04, HYBRID-07
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

    /// Expand `range` to include the full table (header + separator + body)
    /// when the edit overlaps one. Mirrors `expandToEnclosingFence` —
    /// without this, an edit on the body row would only reparse that one
    /// paragraph and leave the header and separator rows carrying stale styling
    /// (header bold, separator hidden, pipes faded).
    ///
    /// Caret-at-end of the table is treated as inside, matching the fence guard.
    /// Tables that no longer parse (e.g. user just deleted the separator line)
    /// won't be found here — recovery happens on the next edit, same caveat as
    /// fenced blocks.
    private func expandToEnclosingTable(_ range: NSRange, in ns: NSString) -> NSRange {
        let tables = MarkdownInlineParser.findTableBlocks(in: ns as String)
        var expanded = range
        for t in tables {
            let tableWhole = NSUnionRange(NSUnionRange(t.headerRange, t.separatorRange), t.bodyRange)
            if NSIntersectionRange(tableWhole, range).length > 0
               || range.location == tableWhole.location + tableWhole.length {
                expanded = NSUnionRange(expanded, tableWhole)
            }
        }
        return expanded
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
        backing.removeAttribute(.link, range: range)            // D-LR-05 cleanup
        backing.removeAttribute(.underlineStyle, range: range)  // D-LR-03 cleanup
        // Reset font to the base 15pt editor font, matching
        // HybridEditorView textView.font. Code blocks and inline code
        // re-apply mono explicitly. Do NOT use 16pt — that's the preview
        // reader font (PATTERNS.md line 477).
        let baseFont = NSFont.systemFont(ofSize: 15, weight: .regular)
        backing.addAttribute(.font, value: baseFont, range: range)
        // Pin foreground to NSColor.textColor so it stays dynamic across
        // light/dark appearance and persists across note-switch full-text
        // replaces. Without this, text inserted by updateNSView has no
        // foregroundColor attribute and can render with a stale cached
        // value baked in at the previous appearance.
        backing.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        // Stamp the body paragraph style so every reparsed range picks up
        // lineHeightMultiple / paragraphSpacing. H1 paragraphs overwrite
        // this with h1ParagraphStyle in applyHeadings / applyFirstLineH1.
        backing.addAttribute(.paragraphStyle,
                             value: Self.bodyParagraphStyle,
                             range: range)
    }

    // MARK: - Per-construct attribute writers

    /// Apply bold styling: SemiBold on content, .sidekickHiddenMarker on `**` markers.
    private func applyBold(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findBoldRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            backing.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                 range: content)
        }
    }

    /// Apply italic styling: italic on content, .sidekickHiddenMarker on `*`/`_` markers.
    /// Resolves the italic cut via NSFontManager.convert(_:toHaveTrait:).
    private func applyItalic(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findItalicRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            let italic = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 15, weight: .regular),
                toHaveTrait: .italicFontMask
            )
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
                                 value: NSFont.monospacedSystemFont(ofSize: 15 * 0.9, weight: .regular),
                                 range: content)
            backing.addAttribute(.backgroundColor,
                                 value: NSColor.separatorColor.withAlphaComponent(0.15),
                                 range: content)
        }
    }

    /// Hides [, ], (, URL, ) marker ranges and styles the label with link-foreground + underline.
    /// Tags the label with AppKit's .link attribute when URL(string:) parses; omits .link otherwise (D-LR-06 fallback).
    /// Mirrors applyInlineCode shape. Per D-LR-02, D-LR-03, D-LR-05.
    private func applyLinks(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findLinkRanges(in: substring)
        for m in matches {
            // Hide bracket/paren/url markup (D-LR-02: everything except label is hidden)
            tagHiddenMarker(shifting: m.openBracketRange, by: offset)
            tagHiddenMarker(shifting: m.closeBracketRange, by: offset)
            tagHiddenMarker(shifting: m.openParenRange, by: offset)
            tagHiddenMarker(shifting: m.urlRange, by: offset)
            tagHiddenMarker(shifting: m.closeParenRange, by: offset)

            let label = shift(m.labelRange, by: offset)

            // Visible label styling (D-LR-03): link color + single underline
            backing.addAttribute(.foregroundColor, value: NSColor.linkColor, range: label)
            backing.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: label)

            // AppKit .link attribute on label (D-LR-05) — nil-fallback per D-LR-06
            let ns = backing.string as NSString
            let shiftedURLRange = shift(m.urlRange, by: offset)
            if shiftedURLRange.length > 0,
               shiftedURLRange.location + shiftedURLRange.length <= ns.length {
                let urlText = ns.substring(with: shiftedURLRange)
                if let url = URL(string: urlText) {
                    backing.addAttribute(.link, value: url, range: label)
                }
            }
        }
    }

    /// Render a plain first line as H1 (bold 14×1.5) when it doesn't already
    /// begin with a CommonMark block marker (`#`, `- `, `* `, ```` ``` ````).
    /// Preserves the SideNotes / Notes.app convention the v1.1 preview path
    /// used (commit e1d815e): the first line of a note is its title.
    ///
    /// Runs AFTER the per-construct inline parsers so the H1 font wins over any
    /// inline 14pt bold/italic/code fonts on line 0 — matches the existing
    /// visible behaviour of `# Heading with **bold**` lines (the heading font
    /// also wins). This is intentional: the first line is a title, not a mixed
    /// inline span.
    private func applyFirstLineH1() {
        guard backing.length > 0 else { return }
        let ns = backing.string as NSString
        let firstLineRange = ns.lineRange(for: NSRange(location: 0, length: 0))
        // Trim the trailing newline (if any) — style the content, not the line break.
        var contentLength = firstLineRange.length
        if contentLength > 0,
           ns.substring(with: NSRange(location: contentLength - 1, length: 1)) == "\n" {
            contentLength -= 1
        }
        guard contentLength > 0 else { return }
        let firstLine = ns.substring(with: NSRange(location: 0, length: contentLength))
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Don't clobber explicit block-level markers.
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("```") {
            return
        }
        let range = NSRange(location: 0, length: contentLength)
        backing.addAttribute(.font,
                             value: NSFont.systemFont(ofSize: 22, weight: .bold),
                             range: range)
        backing.addAttribute(.paragraphStyle,
                             value: Self.h1ParagraphStyle,
                             range: firstLineRange)
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
            case 1:        font = NSFont.systemFont(ofSize: 28, weight: .bold)
            case 2:        font = NSFont.systemFont(ofSize: 22, weight: .semibold)
            case 3, 4, 5, 6: font = NSFont.systemFont(ofSize: 18, weight: .semibold)
            default:       font = NSFont.systemFont(ofSize: 15, weight: .regular)
            }
            backing.addAttribute(.font, value: font, range: content)
            if m.level == 1 {
                let lineRange = (backing.string as NSString).lineRange(for: content)
                backing.addAttribute(.paragraphStyle,
                                     value: Self.h1ParagraphStyle,
                                     range: lineRange)
            }
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
            // Bullet glyph uses SF Pro bold at body size. MarkdownLayoutManager
            // substitutes U+2022 using whatever font is on the marker char; SF
            // Pro's bullet glyph sits at x-height mid reliably, while Geist's
            // bullet drifts vertically and looks off-centered with body text.
            // Matching body size (15pt) also keeps line height consistent
            // with surrounding lines so bullet rows don't grow taller than
            // non-bullet rows.
            backing.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: 15, weight: .bold),
                                 range: markerRange)
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

    /// Apply table styling: hide the `| --- | --- |` separator row entirely,
    /// semibold the header row content, and fade `|` characters to a subtle
    /// color so cells read more like a table without claiming grid alignment.
    ///
    /// Round-trip stays byte-identical — the separator row is hidden via the
    /// existing `.sidekickHiddenMarker` glyph-substitution path (D-MH-02) so
    /// the bytes survive untouched and re-emerge in the saved .md file.
    ///
    /// Limitations matching `applyFenced`: a table that is currently broken
    /// (e.g. user just deleted the separator) will not be detected, leaving
    /// stale styling on the former-table rows until the next edit on those
    /// rows clears it.
    private func applyTables(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findTableBlocks(in: substring)
        for m in matches {
            // Hide the entire separator line (including its trailing newline)
            // so the layout collapses the row to nothing visible.
            tagHiddenMarker(shifting: m.separatorRange, by: offset)

            // Semibold the header row content. Inline parsers (bold/italic/code/
            // link) run after this and may override the font on inner spans —
            // expected: `**foo**` inside a header should still render bolder
            // emphasis, just on top of the header's semibold baseline.
            let header = shift(m.headerRange, by: offset)
            if header.length > 0,
               header.location >= 0,
               header.location + header.length <= backing.length {
                backing.addAttribute(.font,
                                     value: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                     range: header)
            }

            // Fade every `|` in the header + body to tertiary so the dividers
            // recede visually. Bounds-checked per pipe — defensive against
            // future parser drift even though collectPipeOffsets is bounded.
            for pipe in m.pipeRanges {
                let shifted = shift(pipe, by: offset)
                guard shifted.location >= 0,
                      shifted.length > 0,
                      shifted.location + shifted.length <= backing.length else { continue }
                backing.addAttribute(.foregroundColor,
                                     value: NSColor.tertiaryLabelColor,
                                     range: shifted)
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
