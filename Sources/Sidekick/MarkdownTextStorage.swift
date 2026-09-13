/// NSTextStorage subclass that owns the hybrid markdown editor's text +
/// attribute state. On each edit, processEditing() reparses the edited
/// paragraph (expanded to fenced-code-block / table boundaries) and applies
/// .sidekickHiddenMarker to syntax markers + visible attributes (bold /
/// italic / mono / heading sizes / code-block background) to content.
///
/// Round-trip invariant: storage.string is always byte-identical to the
/// concatenation of user edits. We NEVER mutate the backing string to
/// "hide" markers — invisibility is purely a layout-time concern (see
/// MarkdownLayoutManager).
import AppKit

final class MarkdownTextStorage: NSTextStorage {

    private let backing = NSMutableAttributedString()

    /// Builds a paragraph style with absolute (min==max) line height. All of
    /// storage's styles use absolute height rather than lineHeightMultiple —
    /// see HybridEditorView.makeNSView: caret height tracks layout-fragment
    /// height on macOS 14+, so a multiplier would inflate the caret rect with
    /// any font that has airy intrinsic metrics.
    private static func style(
        lineHeight: CGFloat,
        spacing: CGFloat,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacing = spacing
        return style
    }

    /// H1 style: paragraphSpacing adds room *after* the title line.
    /// Re-applied every edit pass by applyHeadings (clearManagedAttributes
    /// strips .paragraphStyle first), which is what makes the gap survive
    /// edits elsewhere.
    static let h1ParagraphStyle: NSParagraphStyle = style(lineHeight: 32, spacing: 4)
    private static let h2ParagraphStyle: NSParagraphStyle = style(lineHeight: 26, spacing: 3)
    private static let h3ParagraphStyle: NSParagraphStyle = style(lineHeight: 22, spacing: 2)

    /// Quote-line style: the `> ` prefix is hidden, so firstLineHeadIndent
    /// and headIndent are equal — quote lines never wrap into a hanging
    /// indent, they read as one indented block of italic text.
    private static let blockQuoteParagraphStyle: NSParagraphStyle = style(lineHeight: 20, spacing: 1, headIndent: 18, firstLineHeadIndent: 18)

    /// Default style for every reparsed range (before H1/H2/H3 override
    /// explicit heading paragraphs).
    static let bodyParagraphStyle: NSParagraphStyle = style(lineHeight: 20, spacing: 1)

    /// Bullet / checklist / numbered-list style: `headIndent = 14` hangs
    /// wrapped lines under the first content char instead of the bullet
    /// glyph (sized for SF Pro 15pt bold's glyph advance + space + a little
    /// breathing room). paragraphSpacing 7 (vs body's 1) gives list items
    /// per-row air without growing the line box (and thus the caret).
    static let bulletParagraphStyle: NSParagraphStyle = style(lineHeight: 20, spacing: 7, headIndent: 14)

    /// Like `bulletParagraphStyle` but headIndent is widened to the
    /// checklist glyph's fixed control-glyph width + trailing space, so
    /// wrapped lines hang under the first-line text, not the drawn square.
    static let checklistParagraphStyle: NSParagraphStyle = style(lineHeight: 20, spacing: 7, headIndent: MarkdownLayoutManager.checklistMarkerWidth + 4)

    /// Base editor font, matching HybridEditorView's textView.font. Used
    /// everywhere a font attribute needs a starting point or fallback.
    private static let bodyFont = NSFont.systemFont(ofSize: 15, weight: .regular)

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
    private func applyAttributes(forEditedRange editedRange: NSRange) {
        let ns = backing.string as NSString

        // Reparse range = paragraph containing the edit, expanded to any
        // fenced code block or table the edit touches (both span multiple
        // paragraphs, so an edit on one row must not leave sibling rows
        // carrying stale styling).
        let paragraphRange = ns.paragraphRange(for: editedRange)
        let fenceExpanded = expandToEnclosingFence(paragraphRange, in: ns)
        let reparseRange = expandToEnclosingTable(fenceExpanded, in: ns)

        guard reparseRange.location >= 0, reparseRange.location + reparseRange.length <= backing.length else { return }

        // Clear managed attributes first so deletions / pair-closures
        // correctly un-hide / un-style, then re-run every parser in
        // block-before-inline order (fenced wins over inline; inline code
        // last so it wins over bold inside `**\`code\`**`). Parser outputs
        // are ranges against `substring`; shift by `base` before applying.
        clearManagedAttributes(in: reparseRange)
        let substring = ns.substring(with: reparseRange)
        let base = reparseRange.location

        applyFenced(in: substring, offset: base)
        applyHeadings(in: substring, offset: base)
        applyChecklists(in: substring, offset: base)
        applyBullets(in: substring, offset: base)
        applyNumberedLists(in: substring, offset: base)
        applyBlockQuotes(in: substring, offset: base)
        applyTables(in: substring, offset: base)
        applyThematicBreak(in: substring, offset: base)
        applyBold(in: substring, offset: base)
        applyItalic(in: substring, offset: base)
        applyStrikethrough(in: substring, offset: base)
        applyUnderline(in: substring, offset: base)
        applyInlineCode(in: substring, offset: base)
        applyLinks(in: substring, offset: base)
        applyEmojiFont(in: substring, offset: base)   // pins Apple Color Emoji on surrogate pairs
    }

    /// Expand `range` to the enclosing fenced-code-block, if any (caret-at-
    /// end of the fence counts as inside).
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

    /// Expand `range` to the enclosing table (header + separator + body),
    /// if any (caret-at-end counts as inside, mirroring
    /// `expandToEnclosingFence`).
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

    /// Clear all Sidekick-managed attributes on `range` before re-applying —
    /// stale attributes from deleted markers (e.g. typing `**foo**` then
    /// deleting the closing `**`) must never leak into plain text.
    private func clearManagedAttributes(in range: NSRange) {
        backing.removeAttribute(.sidekickHiddenMarker, range: range)
        backing.removeAttribute(.sidekickBulletMarker, range: range)
        backing.removeAttribute(.sidekickChecklistMarker, range: range)
        backing.removeAttribute(.sidekickNumberedMarker, range: range)
        backing.removeAttribute(.sidekickThematicBreak, range: range)
        backing.removeAttribute(.sidekickLinkChip, range: range)
        backing.removeAttribute(.sidekickLinkTailAnchor, range: range)
        backing.removeAttribute(.backgroundColor, range: range)
        backing.removeAttribute(.paragraphStyle, range: range)
        backing.removeAttribute(.link, range: range)
        backing.removeAttribute(.toolTip, range: range)
        backing.removeAttribute(.underlineStyle, range: range)
        backing.removeAttribute(.strikethroughStyle, range: range)
        // Reset to the base editor font; code / inline-code re-apply mono explicitly.
        backing.addAttribute(.font, value: Self.bodyFont, range: range)
        // Pin foreground to NSColor.textColor so it stays dynamic across
        // light/dark appearance and persists across note-switch full-text
        // replaces — otherwise inserted text can render with a stale color
        // baked in at the previous appearance.
        backing.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        // Body style by default; applyHeadings overwrites explicit `# ` lines.
        backing.addAttribute(.paragraphStyle, value: Self.bodyParagraphStyle, range: range)
    }

    // MARK: - Per-construct attribute writers

    /// Apply bold styling: rebuild the font at the existing size with .bold
    /// weight, preserving heading size + any italic trait. NSFontManager
    /// .convert(toHaveTrait: .boldFontMask) is a no-op on H2/H3 (already
    /// semibold) and H1 (already bold), so we go through systemFont directly.
    private func applyBold(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findBoldRanges(in: substring)
        for m in matches {
            hideMarkers(open: m.markerOpenRange, close: m.markerCloseRange, offset: offset)
            let content = shift(m.contentRange, by: offset)
            remapFont(in: content) { base in
                let wasItalic = base.fontDescriptor.symbolicTraits.contains(.italic)
                var bold = NSFont.systemFont(ofSize: base.pointSize, weight: .bold)
                if wasItalic {
                    bold = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
                }
                return bold
            }
        }
    }

    /// Apply italic styling: add the italic trait to whatever font already
    /// lives on the content range, preserving heading size + bold trait.
    private func applyItalic(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findItalicRanges(in: substring)
        for m in matches {
            hideMarkers(open: m.markerOpenRange, close: m.markerCloseRange, offset: offset)
            remapFont(in: shift(m.contentRange, by: offset)) {
                NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask)
            }
        }
    }

    /// Apply strikethrough / underline styling — the two constructs differ
    /// only in which attribute key carries the single-underline style.
    private func applyUnderlineStyleMarkers(_ matches: [MarkerPairMatch], key: NSAttributedString.Key, offset: Int) {
        for m in matches {
            hideMarkers(open: m.markerOpenRange, close: m.markerCloseRange, offset: offset)
            backing.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: shift(m.contentRange, by: offset))
        }
    }

    /// Apply strikethrough styling: single-line strikethrough on content,
    /// hidden `~~` markers.
    private func applyStrikethrough(in substring: String, offset: Int) {
        applyUnderlineStyleMarkers(MarkdownInlineParser.findStrikethroughRanges(in: substring), key: .strikethroughStyle, offset: offset)
    }

    /// Apply underline styling for `<u>…</u>`: single-line underline on
    /// content, hidden `<u>` / `</u>` tags. Runs BEFORE applyLinks so a link
    /// inside `<u>` still gets its own linkColor + underline applied on top.
    private func applyUnderline(in substring: String, offset: Int) {
        applyUnderlineStyleMarkers(MarkdownInlineParser.findUnderlineRanges(in: substring), key: .underlineStyle, offset: offset)
    }

    /// Apply inline code styling: monospaced 0.9em font + separator-color background.
    /// Inline code is applied last among inline constructs so the code font wins
    /// over bold/italic when inline code overlaps (CommonMark: code spans win).
    private func applyInlineCode(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findInlineCodeRanges(in: substring)
        for m in matches {
            hideMarkers(open: m.markerOpenRange, close: m.markerCloseRange, offset: offset)
            let content = shift(m.contentRange, by: offset)
            backing.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 15 * 0.9, weight: .regular), range: content)
            backing.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: content)
        }
    }

    /// Hides the `[`, `]`, `(`, url, `)` marker ranges. When the label
    /// equals the URL (modulo chip-display stripping), or for a bare URL in
    /// body text, collapses it into a single rendered "link-chip" via
    /// `applyChip`. Otherwise styles the label with link-foreground +
    /// underline, and tags it with AppKit's `.link` when `URL(string:)`
    /// parses (omitted otherwise).
    private func applyLinks(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findLinkRanges(in: substring)
        for m in matches {
            // Hide everything except the label.
            tagHiddenMarker(shifting: m.openBracketRange, by: offset)
            tagHiddenMarker(shifting: m.closeBracketRange, by: offset)
            tagHiddenMarker(shifting: m.openParenRange, by: offset)
            tagHiddenMarker(shifting: m.urlRange, by: offset)
            tagHiddenMarker(shifting: m.closeParenRange, by: offset)

            guard let label = inBounds(m.labelRange, by: offset),
                  let shiftedURLRange = inBounds(m.urlRange, by: offset) else { continue }
            let ns = backing.string as NSString
            let labelText = ns.substring(with: label)
            let urlText = ns.substring(with: shiftedURLRange)
            let labelChip = MarkdownInlineParser.chipDisplayText(forURL: labelText)
            let urlChip = MarkdownInlineParser.chipDisplayText(forURL: urlText)

            // If the label matches the URL (after chip-display stripping),
            // the label is itself a raw URL — collapse into a chip;
            // otherwise keep the styled-label rendering.
            if labelChip == urlChip {
                applyChip(hiding: m.labelRange, offset: offset, urlText: urlText)
            } else {
                // Visible label styling: link color + single underline.
                backing.addAttribute(.foregroundColor, value: NSColor.linkColor, range: label)
                backing.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
                // AppKit .link attribute on label; omitted when URL(string:) can't parse it.
                if let url = URL(string: urlText) {
                    backing.addAttribute(.link, value: url, range: label)
                }

                // Tag the hidden `](url)` tail (contiguous by construction)
                // so HybridEditorView's caret-rescue can hop across it in
                // one move.
                let tailStart = m.closeBracketRange.location
                let tailLength = (m.closeParenRange.location + m.closeParenRange.length) - tailStart
                let tailRange = shift(NSRange(location: tailStart, length: tailLength), by: offset)
                backing.addAttribute(.sidekickLinkTailAnchor, value: true, range: tailRange)
            }
        }

        // Bare-URL pass: each detected range becomes a chip via applyChip.
        let autoLinks = MarkdownInlineParser.findAutoLinkRanges(in: substring)
        let ns = backing.string as NSString
        for r in autoLinks {
            guard let shifted = inBounds(r, by: offset) else { continue }
            applyChip(hiding: r, offset: offset, urlText: ns.substring(with: shifted))
        }
    }

    /// Renders a link-chip: hides `hiding`, then anchors `.sidekickLinkChip`
    /// (display text), `.link` (if parseable), and a hover `.toolTip` on its
    /// first character.
    private func applyChip(hiding: NSRange, offset: Int, urlText: String) {
        tagHiddenMarker(shifting: hiding, by: offset)
        guard let shiftedHiding = inBounds(hiding, by: offset) else { return }
        let firstCharRange = NSRange(location: shiftedHiding.location, length: 1)
        backing.addAttribute(.sidekickLinkChip, value: MarkdownInlineParser.chipDisplayText(forURL: urlText), range: firstCharRange)
        if let url = URL(string: urlText) {
            backing.addAttribute(.link, value: url, range: firstCharRange)
        }
        // Hover reveals the full destination and signals the pill is clickable (⌘-click opens it).
        backing.addAttribute(.toolTip, value: urlText, range: firstCharRange)
        // Defeats NSTextView's automatic link underline — the chip pill is the visual.
        backing.addAttribute(.underlineStyle, value: 0, range: firstCharRange)
    }

    /// Apply heading styling: level-specific font + paragraph style on
    /// content, hides the `# ` prefix.
    private func applyHeadings(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findHeadingPrefixes(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.prefixRange, by: offset)
            let content = shift(m.contentRange, by: offset)

            let font: NSFont
            let headingStyle: NSParagraphStyle?
            switch m.level {
            case 1:
                font = NSFont.systemFont(ofSize: 28, weight: .semibold)
                headingStyle = Self.h1ParagraphStyle
            case 2:
                font = NSFont.systemFont(ofSize: 22, weight: .semibold)
                headingStyle = Self.h2ParagraphStyle
            case 3, 4, 5, 6:
                font = NSFont.systemFont(ofSize: 18, weight: .semibold)
                headingStyle = Self.h3ParagraphStyle
            default:
                font = Self.bodyFont
                headingStyle = nil
            }
            backing.addAttribute(.font, value: font, range: content)

            if let headingStyle {
                // Excludes the trailing \n so it keeps bodyParagraphStyle
                // (set by clearManagedAttributes) — otherwise the post-
                // heading empty line would inherit the heading's tall line
                // box, and AppKit would leak H1 into typingAttributes when
                // the caret lands there.
                let ns = backing.string as NSString
                var lineStart = 0, lineEnd = 0, contentsEnd = 0
                ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: content)
                backing.addAttribute(.paragraphStyle, value: headingStyle, range: NSRange(location: lineStart, length: contentsEnd - lineStart))
            }
        }
    }

    /// Apply bullet styling: tags the dash/star with `.sidekickBulletMarker`
    /// (glyph-substituted to • by the layout manager) and hangs wrapped
    /// lines under the first content char via `bulletParagraphStyle`.
    private func applyBullets(in substring: String, offset: Int) {
        let prefixes = MarkdownInlineParser.findBulletPrefixes(in: substring)
        for prefixRange in prefixes {
            // Tag only the dash/star char (not the trailing space) so the
            // rendered output is `• item`, not the too-tight `•item`.
            guard let markerRange = inBounds(NSRange(location: prefixRange.location, length: 1), by: offset) else { continue }
            backing.addAttribute(.sidekickBulletMarker, value: true, range: markerRange)
            // Bullet glyph uses SF Pro bold at body size — MarkdownLayoutManager
            // substitutes U+2022 using the marker char's font, and matching body
            // size (15pt) keeps line height consistent with surrounding rows.
            backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .bold), range: markerRange)
            let lineRange = (backing.string as NSString).lineRange(for: markerRange)
            backing.addAttribute(.paragraphStyle, value: Self.bulletParagraphStyle, range: lineRange)
        }
    }

    /// Apply numbered-list styling: tags `N.` with `.sidekickNumberedMarker`
    /// + `.secondaryLabelColor` (only digits+dot; the trailing space keeps
    /// the default color, reset each pass by `clearManagedAttributes`).
    private func applyNumberedLists(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findNumberedPrefixes(in: substring)
        for m in matches {
            guard let marker = inBounds(m.markerRange, by: offset) else { continue }
            backing.addAttribute(.sidekickNumberedMarker, value: true, range: marker)
            backing.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
            // Same hanging-indent style as bullets; headIndent is sized for
            // a single-digit marker, so multi-digit numbers just slightly
            // exceed it — acceptable for a notes app.
            let lineRange = (backing.string as NSString).lineRange(for: marker)
            backing.addAttribute(.paragraphStyle, value: Self.bulletParagraphStyle, range: lineRange)
        }
    }

    /// Apply task-list styling: tags the leading `-` with
    /// `.sidekickChecklistMarker` (value = isChecked) so the layout manager
    /// paints a custom square glyph, hides the surrounding ` [ ]` / ` [x]`
    /// chars, and (when checked) dims the content with strikethrough +
    /// tertiary color, matching Apple Notes.
    private func applyChecklists(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findChecklistPrefixes(in: substring)
        for m in matches {
            guard m.markerRange.length == 1, let marker = inBounds(m.markerRange, by: offset) else { continue }
            backing.addAttribute(.sidekickChecklistMarker, value: m.isChecked, range: marker)
            // Same bold body-size font as the bullet marker so the ◯/◉ glyph
            // reads at a consistent weight with surrounding text.
            backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .semibold), range: marker)
            let lineRange = (backing.string as NSString).lineRange(for: marker)
            backing.addAttribute(.paragraphStyle, value: Self.checklistParagraphStyle, range: lineRange)

            tagHiddenMarker(shifting: m.hiddenRange, by: offset)

            if m.isChecked, let content = inBounds(m.contentRange, by: offset) {
                backing.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                backing.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: content)
            }
        }
    }

    /// Apply blockquote styling: hides the `> ` prefix, indents the line
    /// via `blockQuoteParagraphStyle`, and tints content secondary +
    /// italic. Runs after bullets so a bulleted blockquote (`> - foo`)
    /// keeps its bullet glyph with the quote indent stacked on top.
    private func applyBlockQuotes(in substring: String, offset: Int) {
        let prefixes = MarkdownInlineParser.findBlockQuotePrefixes(in: substring)
        for prefixRange in prefixes {
            guard prefixRange.length == 2, let shifted = inBounds(prefixRange, by: offset) else { continue }

            tagHiddenMarker(shifting: prefixRange, by: offset)

            // Whole-line paragraph style; the hidden `> ` chars collapse to
            // zero width, so the visual indent comes entirely from
            // headIndent / firstLineHeadIndent.
            let lineRange = (backing.string as NSString).lineRange(for: shifted)
            backing.addAttribute(.paragraphStyle, value: Self.blockQuoteParagraphStyle, range: lineRange)

            // Content is everything after `> ` on this line, excluding the
            // trailing newline if present.
            let contentStart = shifted.location + shifted.length
            let lineEnd = lineRange.location + lineRange.length
            var contentEnd = lineEnd
            if contentEnd > contentStart {
                let lastChar = (backing.string as NSString).character(at: contentEnd - 1)
                if lastChar == 0x0A /* \n */ || lastChar == 0x0D /* \r */ {
                    contentEnd -= 1
                }
            }
            let contentLen = max(0, contentEnd - contentStart)
            guard contentLen > 0 else { continue }
            let contentRange = NSRange(location: contentStart, length: contentLen)

            backing.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: contentRange)
            // Augments whatever font is already there (preserves bold/heading/code overrides).
            remapFont(in: contentRange) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        }
    }

    /// Apply fenced-code-block styling: hides fence lines, monospaces +
    /// tints content. Runs first in applyAttributes so inline parsers can't
    /// overwrite the code font.
    private func applyFenced(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findFencedCodeBlocks(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.fenceOpenRange, by: offset)
            tagHiddenMarker(shifting: m.fenceCloseRange, by: offset)
            if let content = inBounds(m.contentRange, by: offset) {
                backing.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: content)
                backing.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: content)
            }
        }
    }

    /// Apply table styling: hides the separator row, semibolds the header,
    /// and fades `|` chars. Same staleness caveat as `applyFenced` for a
    /// currently-broken table (e.g. separator just deleted).
    private func applyTables(in substring: String, offset: Int) {
        let matches = MarkdownInlineParser.findTableBlocks(in: substring)
        for m in matches {
            // Hide the entire separator line (including its trailing newline)
            // so the layout collapses the row to nothing visible.
            tagHiddenMarker(shifting: m.separatorRange, by: offset)

            // Inline parsers (bold/italic/code/link) run after this and may
            // override the font on inner spans — expected: `**foo**` inside
            // a header should still render bolder, just on top of the
            // header's semibold baseline.
            if let header = inBounds(m.headerRange, by: offset) {
                backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .semibold), range: header)
            }

            for pipe in m.pipeRanges {
                guard let shifted = inBounds(pipe, by: offset) else { continue }
                backing.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: shifted)
            }
        }
    }

    /// Apply thematic-break styling: tags the `---` line with
    /// `.sidekickThematicBreak` (painted as a hairline by the layout
    /// manager) and hides its glyphs. The trailing newline is intentionally
    /// excluded from the range so the line fragment keeps a non-empty
    /// line-box height for drawBackground to paint into.
    private func applyThematicBreak(in substring: String, offset: Int) {
        let ranges = MarkdownInlineParser.findThematicBreaks(in: substring)
        for r in ranges {
            guard let shifted = inBounds(r, by: offset) else { continue }
            backing.addAttribute(.sidekickThematicBreak, value: true, range: shifted)
            backing.addAttribute(.sidekickHiddenMarker, value: true, range: shifted)
        }
    }

    /// Pins Apple Color Emoji on every surrogate-pair (emoji) run, at the
    /// ambient font's point size. Without this, AppKit's post-edit re-layout
    /// hands the primary font (which has no emoji glyph) to the whole
    /// paragraph, marks the surrogate halves `.null`, and skips the
    /// font-cascade pass that would have substituted emoji — bytes survive
    /// but render invisibly. An explicit font short-circuits that.
    private func applyEmojiFont(in substring: String, offset: Int) {
        let ns = substring as NSString
        let length = ns.length
        guard length >= 2 else { return }
        var i = 0
        while i < length - 1 {
            let high = ns.character(at: i)
            if high >= 0xD800 && high <= 0xDBFF {
                let low = ns.character(at: i + 1)
                if low >= 0xDC00 && low <= 0xDFFF {
                    let pairRange = NSRange(location: offset + i, length: 2)
                    if pairRange.location >= 0,
                       pairRange.location + pairRange.length <= backing.length {
                        let ambientFont = (backing.attribute(.font, at: pairRange.location, effectiveRange: nil) as? NSFont) ?? Self.bodyFont
                        let emojiFont = NSFont(name: "AppleColorEmoji", size: ambientFont.pointSize)
                            ?? NSFont(name: "AppleColorEmojiUI", size: ambientFont.pointSize)
                            ?? ambientFont
                        backing.addAttribute(.font, value: emojiFont, range: pairRange)
                    }
                    i += 2
                    continue
                }
            }
            i += 1
        }
    }

    // MARK: - Helpers

    /// Shift `r` by `offset` and return it only if it's non-empty and
    /// within `backing`'s bounds; nil otherwise. Centralizes the guard
    /// duplicated across every per-construct writer above.
    private func inBounds(_ r: NSRange, by offset: Int) -> NSRange? {
        let shifted = NSRange(location: r.location + offset, length: r.length)
        guard shifted.length > 0,
              shifted.location >= 0,
              shifted.location + shifted.length <= backing.length else { return nil }
        return shifted
    }

    /// Hides a parser range (relative to substring at `offset`) via
    /// `.sidekickHiddenMarker`, guarded by `inBounds` so an out-of-bounds
    /// range can never crash the storage.
    private func tagHiddenMarker(shifting r: NSRange, by offset: Int) {
        guard let shifted = inBounds(r, by: offset) else { return }
        backing.addAttribute(.sidekickHiddenMarker, value: true, range: shifted)
    }

    /// Hides a paired marker's open + close ranges — the shared first step
    /// for bold / italic / inline-code / strikethrough / underline.
    private func hideMarkers(open: NSRange, close: NSRange, offset: Int) {
        tagHiddenMarker(shifting: open, by: offset)
        tagHiddenMarker(shifting: close, by: offset)
    }

    /// Remaps the font attribute across `range` via `transform`, seeding
    /// each run with `.bodyFont` when no font attribute is set yet. Shared
    /// by applyBold/applyItalic/applyBlockQuotes, which only differ in how
    /// they transform the existing font.
    private func remapFont(in range: NSRange, _ transform: (NSFont) -> NSFont) {
        backing.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let base = (value as? NSFont) ?? Self.bodyFont
            backing.addAttribute(.font, value: transform(base), range: subrange)
        }
    }

    /// Shift an NSRange by `offset` (converts a parser-relative range to a
    /// full-document range in the backing store).
    private func shift(_ r: NSRange, by offset: Int) -> NSRange {
        NSRange(location: r.location + offset, length: r.length)
    }
}
