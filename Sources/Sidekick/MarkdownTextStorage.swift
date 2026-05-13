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

    /// Paragraph style applied to H1 paragraphs (explicit `# ` headings) so
    /// the title line gets visible breathing room above the body.
    /// paragraphSpacing adds space *after* the paragraph, so attaching it to
    /// the H1 paragraph creates the gap before whatever follows. Re-applied
    /// on every edit pass via applyHeadings — clearManagedAttributes strips
    /// .paragraphStyle, so the re-application is what makes the gap survive
    /// edits elsewhere.
    static let h1ParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.minimumLineHeight = 32
        style.maximumLineHeight = 32
        return style
    }()

    private static let h2ParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 3
        style.minimumLineHeight = 26
        style.maximumLineHeight = 26
        return style
    }()

    private static let h3ParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2
        style.minimumLineHeight = 22
        style.maximumLineHeight = 22
        return style
    }()

    /// Default paragraph style applied to every reparsed range in storage
    /// (before H1 optionally overrides on line 0 / heading paragraphs).
    /// Applied directly on storage rather than relying on
    /// `textView.defaultParagraphStyle` — the latter is unreliable in TextKit 1
    /// once storage starts setting its own paragraph styles anywhere, so we
    /// enforce the rhythm at the storage layer.
    /// Paragraph style applied to lines beginning with `> ` so the rendered
    /// quote sits indented from the body margin (Apple Notes parity). Both
    /// firstLineHeadIndent and headIndent are set to the same value because
    /// quote lines never wrap into a hanging indent — the marker is hidden
    /// and the content reads as a single block of indented italic text.
    private static let blockQuoteParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 18
        style.headIndent = 18
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        style.paragraphSpacing = 1
        return style
    }()

    static let bodyParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        // See HybridEditorView.makeNSView for why this is absolute (min==max)
        // instead of lineHeightMultiple — caret height tracks layout fragment
        // height on macOS 14+ (NSTextInsertionIndicator follows the layout
        // fragment), so a multiplier would inflate the caret rect with any
        // font that has airy intrinsic metrics. paragraphSpacing carries the
        // breathing-room budget instead, since it adds gap between paragraphs
        // without growing the line box.
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        style.paragraphSpacing = 1
        return style
    }()

    /// Paragraph style applied to bullet / checklist / numbered list lines so
    /// wrapped lines hang under the first character of content instead of
    /// flushing back under the bullet glyph. `headIndent = 14` is sized to:
    /// SF Pro 15pt bold • glyph advance (~5.5pt) + space char (~4pt) + ~4pt
    /// of visual breathing room. paragraphSpacing of 4 (vs body's 1) gives
    /// list items per-row air without growing the line box (and thus the
    /// caret) — matches the body-style tradeoff documented above.
    static let bulletParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 14
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        style.paragraphSpacing = 7
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
            try applyChecklists(in: substring, offset: base)
            try applyBullets(in: substring, offset: base)
            try applyNumberedLists(in: substring, offset: base)
            try applyBlockQuotes(in: substring, offset: base)
            try applyTables(in: substring, offset: base)
            try applyThematicBreak(in: substring, offset: base)
            try applyBold(in: substring, offset: base)
            try applyItalic(in: substring, offset: base)
            try applyStrikethrough(in: substring, offset: base)
            try applyUnderline(in: substring, offset: base)
            try applyInlineCode(in: substring, offset: base)
            try applyLinks(in: substring, offset: base)   // D-LR-04, HYBRID-07
            applyEmojiFont(in: substring, offset: base)   // F-07: pin Apple Color Emoji on surrogate pairs
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
        backing.removeAttribute(.sidekickChecklistMarker, range: range)
        backing.removeAttribute(.sidekickNumberedMarker, range: range)
        backing.removeAttribute(.sidekickThematicBreak, range: range)
        backing.removeAttribute(.sidekickLinkChip, range: range)
        backing.removeAttribute(.backgroundColor, range: range)
        backing.removeAttribute(.paragraphStyle, range: range)
        backing.removeAttribute(.link, range: range)            // D-LR-05 cleanup
        backing.removeAttribute(.underlineStyle, range: range)  // D-LR-03 + applyUnderline cleanup
        backing.removeAttribute(.strikethroughStyle, range: range)  // applyStrikethrough cleanup
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
        // lineHeightMultiple / paragraphSpacing. Explicit `# ` heading
        // paragraphs overwrite this with h1ParagraphStyle in applyHeadings.
        backing.addAttribute(.paragraphStyle,
                             value: Self.bodyParagraphStyle,
                             range: range)
    }

    // MARK: - Per-construct attribute writers

    /// Apply bold styling: rebuild the font at the existing size with .bold
    /// weight, preserving heading size + any italic trait. NSFontManager
    /// .convert(toHaveTrait: .boldFontMask) is a no-op on H2/H3 (already
    /// semibold) and H1 (already bold), so we go through systemFont directly.
    private func applyBold(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findBoldRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            backing.enumerateAttribute(.font, in: content, options: []) { value, range, _ in
                let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: 15, weight: .regular)
                let wasItalic = base.fontDescriptor.symbolicTraits.contains(.italic)
                var bold = NSFont.systemFont(ofSize: base.pointSize, weight: .bold)
                if wasItalic {
                    bold = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
                }
                backing.addAttribute(.font, value: bold, range: range)
            }
        }
    }

    /// Apply italic styling: add the italic trait to whatever font already
    /// lives on the content range, preserving heading size + bold trait.
    private func applyItalic(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findItalicRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            backing.enumerateAttribute(.font, in: content, options: []) { value, range, _ in
                let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: 15, weight: .regular)
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                backing.addAttribute(.font, value: italic, range: range)
            }
        }
    }

    /// Apply strikethrough styling: single-line strikethrough on content,
    /// .sidekickHiddenMarker on `~~` markers. Mirrors `applyBold`.
    private func applyStrikethrough(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findStrikethroughRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            backing.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: content)
        }
    }

    /// Apply underline styling for `<u>…</u>`: single-line underline on
    /// content, .sidekickHiddenMarker on the `<u>` / `</u>` tags. Asymmetric
    /// markers handled by the StrikethroughMatch / UnderlineMatch range fields.
    /// Runs BEFORE applyLinks so a link inside `<u>` still gets its own
    /// linkColor + underline applied on top.
    private func applyUnderline(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findUnderlineRanges(in: substring)
        for m in matches {
            tagHiddenMarker(shifting: m.markerOpenRange, by: offset)
            tagHiddenMarker(shifting: m.markerCloseRange, by: offset)
            let content = shift(m.contentRange, by: offset)
            backing.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: content)
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
                                 value: NSColor.quaternaryLabelColor,
                                 range: content)
        }
    }

    /// Hides [, ], (, URL, ) marker ranges and styles the label with link-foreground + underline.
    /// Tags the label with AppKit's .link attribute when URL(string:) parses; omits .link otherwise (D-LR-06 fallback).
    /// Mirrors applyInlineCode shape. Per D-LR-02, D-LR-03, D-LR-05.
    ///
    /// Phase B extension: when the markdown label equals the URL (modulo
    /// chip-display stripping), or for bare URLs in body text, the URL is
    /// collapsed into a single rendered "link-chip" via `.sidekickLinkChip`.
    /// Source bytes are preserved — only attributes change.
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

            // Inspect the label text and the URL text. If they match (after
            // chip-display stripping) the label is itself a raw URL — collapse
            // into a chip. Otherwise keep the styled-label rendering.
            let ns = backing.string as NSString
            let shiftedURLRange = shift(m.urlRange, by: offset)
            guard label.length > 0,
                  label.location + label.length <= ns.length,
                  shiftedURLRange.length > 0,
                  shiftedURLRange.location + shiftedURLRange.length <= ns.length else {
                continue
            }
            let labelText = ns.substring(with: label)
            let urlText = ns.substring(with: shiftedURLRange)
            let labelChip = MarkdownInlineParser.chipDisplayText(forURL: labelText)
            let urlChip = MarkdownInlineParser.chipDisplayText(forURL: urlText)

            if labelChip == urlChip {
                // Label is the URL — hide the whole label and chip the first char.
                tagHiddenMarker(shifting: m.labelRange, by: offset)
                let firstCharRange = NSRange(location: label.location, length: 1)
                backing.addAttribute(.sidekickLinkChip,
                                     value: urlChip,
                                     range: firstCharRange)
                if let url = URL(string: urlText) {
                    backing.addAttribute(.link, value: url, range: firstCharRange)
                }
                // Defeat NSTextView's automatic linkTextAttributes (linkColor +
                // single underline) on the chip anchor — the pill is our
                // visual, the system underline would render below it.
                backing.addAttribute(.underlineStyle, value: 0, range: firstCharRange)
            } else {
                // Visible label styling (D-LR-03): link color + single underline
                backing.addAttribute(.foregroundColor, value: NSColor.linkColor, range: label)
                backing.addAttribute(.underlineStyle,
                                     value: NSUnderlineStyle.single.rawValue,
                                     range: label)
                // AppKit .link attribute on label (D-LR-05) — nil-fallback per D-LR-06
                if let url = URL(string: urlText) {
                    backing.addAttribute(.link, value: url, range: label)
                }
            }
        }

        // Bare-URL auto-link pass. Each detected range becomes a chip:
        // every char hidden, first char carries `.sidekickLinkChip` (display
        // text) plus `.link` so cmd-click / system handling still works.
        let autoLinks = MarkdownInlineParser.findAutoLinkRanges(in: substring)
        let ns = backing.string as NSString
        for r in autoLinks {
            let shifted = shift(r, by: offset)
            guard shifted.length > 0,
                  shifted.location + shifted.length <= ns.length else { continue }
            let urlText = ns.substring(with: shifted)

            tagHiddenMarker(shifting: r, by: offset)

            let firstCharRange = NSRange(location: shifted.location, length: 1)
            let displayText = MarkdownInlineParser.chipDisplayText(forURL: urlText)
            backing.addAttribute(.sidekickLinkChip,
                                 value: displayText,
                                 range: firstCharRange)
            if let url = URL(string: urlText) {
                backing.addAttribute(.link, value: url, range: firstCharRange)
            }
            // Defeat NSTextView's automatic linkTextAttributes underline on
            // the chip anchor (see [url](url) branch above).
            backing.addAttribute(.underlineStyle, value: 0, range: firstCharRange)
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
            case 1:        font = NSFont.systemFont(ofSize: 28, weight: .semibold)
            case 2:        font = NSFont.systemFont(ofSize: 22, weight: .semibold)
            case 3, 4, 5, 6: font = NSFont.systemFont(ofSize: 18, weight: .semibold)
            default:       font = NSFont.systemFont(ofSize: 15, weight: .regular)
            }
            backing.addAttribute(.font, value: font, range: content)
            let headingStyle: NSParagraphStyle?
            switch m.level {
            case 1: headingStyle = Self.h1ParagraphStyle
            case 2: headingStyle = Self.h2ParagraphStyle
            case 3, 4, 5, 6: headingStyle = Self.h3ParagraphStyle
            default: headingStyle = nil
            }
            if let style = headingStyle {
                // F-06: apply heading paragraphStyle to the line WITHOUT the
                // trailing \n. The terminator inherits bodyParagraphStyle from
                // clearManagedAttributes, so when the caret sits on the empty
                // line directly after a heading (post-Enter) the trailing-line
                // layout fragment uses body metrics (18pt) instead of the
                // heading's tall line box (32pt for h1). Without this, AppKit
                // also uses the \n's heading-styled attrs to seed
                // typingAttributes when the caret moves there, which leaks H1
                // into the next typed char.
                let ns = backing.string as NSString
                var lineStart = 0, lineEnd = 0, contentsEnd = 0
                ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: content)
                let withoutTerminator = NSRange(
                    location: lineStart,
                    length: contentsEnd - lineStart
                )
                backing.addAttribute(.paragraphStyle, value: style, range: withoutTerminator)
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
            // Bullet glyph uses SF Pro bold at body size — MarkdownLayoutManager
            // substitutes U+2022 using the marker char's font, and matching body
            // size (15pt) keeps line height consistent with surrounding rows.
            backing.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: 15, weight: .bold),
                                 range: markerRange)
            // Hanging indent: stamp bulletParagraphStyle on the whole line so
            // wrapped lines align under the first char of content (not under
            // the bullet glyph). Mirrors applyBlockQuotes line-range pattern.
            let lineRange = (backing.string as NSString).lineRange(for: shifted)
            backing.addAttribute(.paragraphStyle,
                                 value: Self.bulletParagraphStyle,
                                 range: lineRange)
        }
    }

    /// Apply numbered-list styling: tag the `N.` prefix with `.sidekickNumberedMarker`
    /// and `NSColor.secondaryLabelColor` so it is visually distinct from plain `1.`
    /// typed inline. Only the digits+dot are styled — the trailing space stays at
    /// the default text color. Color is reset by `clearManagedAttributes` via its
    /// global `.foregroundColor` reset to `.textColor`.
    private func applyNumberedLists(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findNumberedPrefixes(in: substring)
        for m in matches {
            let marker = shift(m.markerRange, by: offset)
            guard marker.length >= 1,
                  marker.location >= 0,
                  marker.location + marker.length <= backing.length else { continue }
            backing.addAttribute(.sidekickNumberedMarker, value: true, range: marker)
            backing.addAttribute(.foregroundColor,
                                 value: NSColor.secondaryLabelColor,
                                 range: marker)
            // Hanging indent + per-item air — same style bullets use. headIndent
            // is sized for a single-digit marker (`1.`); multi-digit lists will
            // wrap with the same hang and the marker just visually exceeds it —
            // acceptable for a notes app, full digit-aware indent is overkill.
            let lineRange = (backing.string as NSString).lineRange(for: marker)
            backing.addAttribute(.paragraphStyle,
                                 value: Self.bulletParagraphStyle,
                                 range: lineRange)
        }
    }

    /// Apply task-list (checklist) styling: tag the leading `-` with
    /// `.sidekickChecklistMarker` (value=isChecked) so the layout manager
    /// substitutes ◯/◉; hide the surrounding ` [ ]` / ` [x]` chars via
    /// `.sidekickHiddenMarker`. The trailing space stays visible so the
    /// rendered result is `◯ item` / `◉ item`.
    ///
    /// On checked items, dim the content with strikethrough + tertiary color
    /// to match Apple Notes' done-item treatment. Round-trip stays byte-
    /// identical — only attributes change.
    ///
    /// Runs BEFORE `applyBullets` (parser order in `applyAttributes`) and the
    /// bullet regex excludes task-list lines via negative lookahead, so the
    /// dash never gets the bullet attribute on a checklist line.
    private func applyChecklists(in substring: String, offset: Int) throws {
        let matches = MarkdownInlineParser.findChecklistPrefixes(in: substring)
        for m in matches {
            let marker = shift(m.markerRange, by: offset)
            guard marker.length == 1,
                  marker.location >= 0,
                  marker.location + marker.length <= backing.length else { continue }
            backing.addAttribute(.sidekickChecklistMarker, value: m.isChecked, range: marker)
            // Use the same bold body-size font as the bullet marker so the
            // ◯/◉ glyph reads at consistent weight with surrounding text.
            backing.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: 15, weight: .bold),
                                 range: marker)
            // Hanging indent + per-item air — same style bullets use. Applied
            // for both checked and unchecked rows so the visual rhythm matches
            // bullets and numbered lists.
            let lineRange = (backing.string as NSString).lineRange(for: marker)
            backing.addAttribute(.paragraphStyle,
                                 value: Self.bulletParagraphStyle,
                                 range: lineRange)

            tagHiddenMarker(shifting: m.hiddenRange, by: offset)

            if m.isChecked {
                let content = shift(m.contentRange, by: offset)
                if content.length > 0,
                   content.location >= 0,
                   content.location + content.length <= backing.length {
                    backing.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue,
                                         range: content)
                    backing.addAttribute(.foregroundColor,
                                         value: NSColor.tertiaryLabelColor,
                                         range: content)
                }
            }
        }
    }

    /// Apply blockquote styling: hide the `> ` line prefix, indent the line via
    /// `blockQuoteParagraphStyle`, and tint the content secondary + italic so
    /// the quote reads visually distinct from body text. Mirrors `applyBullets`
    /// shape — line-prefix scan, marker hide, paragraph-style stamp on the
    /// containing line. Round-trip stays byte-identical (`> ` is hidden, not
    /// removed). Runs after bullets so a bulleted blockquote (`> - foo`) still
    /// gets its bullet glyph; quote indent stacks with the bullet's own indent.
    private func applyBlockQuotes(in substring: String, offset: Int) throws {
        let prefixes = MarkdownInlineParser.findBlockQuotePrefixes(in: substring)
        for prefixRange in prefixes {
            let shifted = shift(prefixRange, by: offset)
            guard shifted.length == 2,
                  shifted.location >= 0,
                  shifted.location + shifted.length <= backing.length else { continue }

            // Hide the `> ` chars via the standard hidden-marker path.
            backing.addAttribute(.sidekickHiddenMarker, value: true, range: shifted)

            // Stamp the quote paragraph style on the whole line so the indent
            // applies to the visible content (the hidden `> ` chars carry it
            // too, but they collapse to zero width so the visual indent comes
            // entirely from headIndent / firstLineHeadIndent).
            let lineRange = (backing.string as NSString).lineRange(for: shifted)
            backing.addAttribute(.paragraphStyle,
                                 value: Self.blockQuoteParagraphStyle,
                                 range: lineRange)

            // Style the visible content (everything after `> ` on this line,
            // excluding the trailing newline) with secondary color + italic.
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

            backing.addAttribute(.foregroundColor,
                                 value: NSColor.secondaryLabelColor,
                                 range: contentRange)

            // Italic on top of whatever font already lives on the content
            // (preserves bold/heading/inline-code overrides set by other
            // parsers — italic just augments the existing trait).
            backing.enumerateAttribute(.font, in: contentRange, options: []) { value, range, _ in
                let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: 15, weight: .regular)
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                backing.addAttribute(.font, value: italic, range: range)
            }
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
                                     value: NSColor.quaternaryLabelColor,
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

    /// Apply thematic-break styling: tag the dash/asterisk/underscore line with
    /// `.sidekickThematicBreak` (read by the layout manager's drawBackground
    /// override to paint the hairline) AND with `.sidekickHiddenMarker` so the
    /// glyphs collapse to zero width — the raw `---` source chars survive in
    /// the buffer (D-T-03 round-trip) but the user only sees the hairline.
    /// The line's trailing newline is intentionally NOT in the parser's range,
    /// so it stays visible and the line fragment retains its line-box height
    /// (giving drawBackground a non-empty rect to draw into).
    private func applyThematicBreak(in substring: String, offset: Int) throws {
        let ranges = MarkdownInlineParser.findThematicBreaks(in: substring)
        for r in ranges {
            let shifted = shift(r, by: offset)
            guard shifted.length > 0,
                  shifted.location >= 0,
                  shifted.location + shifted.length <= backing.length else { continue }
            backing.addAttribute(.sidekickThematicBreak, value: true, range: shifted)
            backing.addAttribute(.sidekickHiddenMarker, value: true, range: shifted)
        }
    }

    /// F-07 fix: pin Apple Color Emoji on every emoji surrogate pair in the
    /// reparse range, preserving the size of the primary font already applied
    /// at that position (so emoji in an H1 line stays 28pt, body emoji stays
    /// 15pt). Without this, AppKit's `setGlyphs` re-layout path after a text
    /// edit calls into the layout manager with the primary font (e.g.
    /// systemFont 15pt) for the entire paragraph in a single call. The
    /// primary font has no glyph for emoji surrogate pair characters, so
    /// AppKit marks the surrogate halves with `.null` glyph property and
    /// (critically) skips the secondary font-cascade pass that would have
    /// substituted Apple Color Emoji. The emoji's bytes survive in storage
    /// but render invisibly. Setting an explicit `.font = AppleColorEmoji`
    /// on the surrogate pair range short-circuits AppKit's font-cascade
    /// path: it sees the explicit font, generates the emoji glyph natively,
    /// and never marks anything null.
    ///
    /// Iterates UTF-16 code units in `substring`. A high surrogate
    /// (0xD800–0xDBFF) followed by a low surrogate (0xDC00–0xDFFF) is the
    /// surface form of a non-BMP scalar — that's where every emoji past
    /// U+FFFF lives, plus a long tail of CJK extension blocks. We pin
    /// AppleColorEmoji on every such pair (CJK extension chars are rare in
    /// notes and would render either way; doing the cheap pass everywhere
    /// keeps the rule simple).
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
                    // Surrogate pair — pin AppleColorEmoji at the ambient
                    // font size (preserves H1/H2/H3 sizing, mono code size).
                    let pairRange = NSRange(location: offset + i, length: 2)
                    if pairRange.location >= 0,
                       pairRange.location + pairRange.length <= backing.length {
                        let ambientFont = (backing.attribute(.font, at: pairRange.location, effectiveRange: nil) as? NSFont)
                            ?? NSFont.systemFont(ofSize: 15, weight: .regular)
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
