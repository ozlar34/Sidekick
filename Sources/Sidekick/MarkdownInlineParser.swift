/// Pure-function markdown range finder for the hybrid live-preview editor.
///
/// Six static functions locate marker-vs-content NSRanges for bold, italic,
/// inline code, headings (H1–H6), bullets (- / *), and fenced code blocks.
/// All offsets are UTF-16 code units (NSRange-compatible) so output drops
/// straight into NSTextStorage.setAttributes(_:range:). No AppKit imports —
/// keeps the layer trivially unit-testable and main-actor-free.
///
/// Pattern source: FormattingToolbarView.applyMarkdownWrap (static-funcs-on-
/// a-type + UTF-16 discipline at Sources/Sidekick/FormattingToolbarView.swift:87-127).
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md D-PS-01, D-PS-05, D-MH-04.
import Foundation

// MARK: - Result types

struct BoldMatch {
    let markerOpenRange: NSRange
    let contentRange: NSRange
    let markerCloseRange: NSRange
}

struct ItalicMatch {
    let markerOpenRange: NSRange
    let contentRange: NSRange
    let markerCloseRange: NSRange
}

struct InlineCodeMatch {
    let markerOpenRange: NSRange
    let contentRange: NSRange
    let markerCloseRange: NSRange
}

struct StrikethroughMatch {
    let markerOpenRange: NSRange   // length 2 (`~~`)
    let contentRange: NSRange
    let markerCloseRange: NSRange  // length 2 (`~~`)
}

struct UnderlineMatch {
    let markerOpenRange: NSRange   // length 3 (`<u>`)
    let contentRange: NSRange
    let markerCloseRange: NSRange  // length 4 (`</u>`)
}

struct HeadingMatch {
    let level: Int
    let prefixRange: NSRange
    let contentRange: NSRange
}

struct FencedCodeMatch {
    let fenceOpenRange: NSRange
    let contentRange: NSRange
    let fenceCloseRange: NSRange
}

struct LinkMatch {
    let openBracketRange: NSRange     // "[", length 1
    let labelRange: NSRange            // content between brackets
    let closeBracketRange: NSRange    // "]", length 1
    let openParenRange: NSRange       // "(", length 1
    let urlRange: NSRange              // content between parens (may be length 0)
    let closeParenRange: NSRange      // ")", length 1
}

/// GFM task-list line prefix: `- [ ] ` (unchecked) or `- [x] ` (checked).
/// Total prefix length is always 6 UTF-16 units (dash + space + `[` +
/// state char + `]` + trailing space). The trailing space is intentionally
/// left visible so the rendered result is `○ item` (with breathing room
/// after the substituted glyph), not the tight `○item`.
struct ChecklistMatch {
    /// The `-` char at line start. Length 1. Glyph-substituted to ○/●.
    let markerRange: NSRange
    /// ` [ ]` or ` [x]` — the 4 chars between dash and trailing space.
    /// Fully hidden via `.sidekickHiddenMarker`.
    let hiddenRange: NSRange
    /// Line content after the `- [ ] ` / `- [x] ` prefix, excluding any
    /// trailing newline. Length 0 when the line is exactly the prefix.
    let contentRange: NSRange
    let isChecked: Bool
}

/// Numbered list line prefix: `N. ` where N is one or more digits.
/// `markerRange` covers the number+dot only (`N.`), excluding the trailing
/// space, so `.secondaryLabelColor` is applied only to the marker itself.
struct NumberedMatch {
    /// The `N.` part (digits + dot), excluding trailing space. Variable length.
    let markerRange: NSRange
    /// The full `N. ` prefix (digits + dot + space).
    let fullPrefixRange: NSRange
}

struct TableMatch {
    /// Header line content (excluding trailing newline). Always non-empty.
    let headerRange: NSRange
    /// Separator line INCLUDING its trailing newline (if any). Hiding this whole
    /// range collapses the visual line so the `| --- | --- |` row disappears.
    let separatorRange: NSRange
    /// Combined body lines (each row's full line range, contiguous). Length 0
    /// when the table has only a header + separator with no body rows.
    let bodyRange: NSRange
    /// Every `|` character inside header + body lines (length 1 each). Used to
    /// fade pipes to a subtle color so cells read more like a table.
    let pipeRanges: [NSRange]
}

// MARK: - MarkdownInlineParser

/// Namespace type for all markdown range-finding pure functions.
/// All returned NSRanges are UTF-16 offsets (NSRange-compatible).
enum MarkdownInlineParser {

    // MARK: - Cached regexes (D-RF-01 — addresses 09-REVIEW MD-01)
    // Compiled once per process. `try!` is safe: these are compile-time-constant
    // patterns; a compile failure indicates a code defect, not a runtime condition.
    private static let boldRegex = try! NSRegularExpression(
        pattern: "\\*\\*([^*]|\\*(?!\\*))+?\\*\\*",
        options: []
    )
    private static let italicAsteriskRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*(?!\\*)([^*\\n]+?)(?<!\\*)\\*(?!\\*)",
        options: []
    )
    private static let italicUnderscoreRegex = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_])_([^_\\n]+?)_(?![A-Za-z0-9_])",
        options: []
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "`([^`\\n]+?)`",
        options: []
    )
    private static let headingRegex = try! NSRegularExpression(
        pattern: "^(#{1,6}) (.*)$",
        options: []
    )
    // Bullet pattern excludes task-list lines via negative lookahead: a line
    // starting with `- [ ] ` or `- [x] ` / `- [X] ` is a checklist, not a
    // plain bullet, so the dash must NOT be tagged with `.sidekickBulletMarker`
    // (would clash with `.sidekickChecklistMarker`).
    private static let bulletRegex = try! NSRegularExpression(
        pattern: "^(- (?!\\[[ xX]\\] )|\\* )",
        options: []
    )
    private static let numberedListRegex = try! NSRegularExpression(
        pattern: #"^\d+\."#,
        options: []
    )
    private static let checklistRegex = try! NSRegularExpression(
        pattern: "^- \\[([ xX])\\] ",
        options: []
    )
    private static let blockQuoteRegex = try! NSRegularExpression(
        pattern: "^> ",
        options: []
    )
    // Thematic break: a line consisting only of three or more `-` characters,
    // with optional surrounding whitespace. CommonMark also permits `*` and
    // `_` runs, but we intentionally restrict to dashes — `***` collides with
    // bold-italic typing (`**` + `**`) and produced surprise horizontal rules.
    // The regex is run against single-line text (newline stripped before
    // matching) so `^…$` anchors the whole line.
    private static let thematicBreakRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*-{3,}[ \\t]*$",
        options: []
    )
    private static let fenceRegex = try! NSRegularExpression(
        pattern: "^```[a-zA-Z0-9]*$",
        options: []
    )
    private static let linkRegex = try! NSRegularExpression(
        pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]*)\\)",
        options: []
    )
    private static let strikethroughRegex = try! NSRegularExpression(
        pattern: "~~([^~\\n]+?)~~",
        options: []
    )
    // Underline is HTML, not markdown — `<u>foo</u>`. Match across non-newline
    // content; pair-only-hide (D-MH-04) drops unclosed `<u>` tags.
    private static let underlineRegex = try! NSRegularExpression(
        pattern: "<u>([^\\n]+?)</u>",
        options: []
    )

    // MARK: Bold

    /// Returns ranges for all paired `**…**` bold markers in `string`.
    ///
    /// - Each BoldMatch contains UTF-16 NSRanges for the open marker (length 2),
    ///   the content between markers, and the close marker (length 2).
    /// - Unclosed pairs (e.g. `**foo` with no closing `**`) return nothing — D-MH-04.
    /// - Degenerate empty pairs (e.g. `** **`) are skipped (zero-length content).
    static func findBoldRanges(in string: String) -> [BoldMatch] {
        let ns = string as NSString

        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = Self.boldRegex.matches(in: string, range: fullRange)

        return rawMatches.compactMap { match -> BoldMatch? in
            let r = match.range
            // A valid **…** needs at least 4 characters (open + 1 content char + close)
            // Content length is total - 4 (two 2-char markers)
            let contentLength = r.length - 4
            guard contentLength > 0 else { return nil }

            // Skip degenerate whitespace-only pairs (e.g. "** **") — these render
            // nothing meaningful and match the plan's "empty pair → skip" intent (D-T-01).
            let contentNS = ns.substring(with: NSRange(location: r.location + 2, length: contentLength)) as NSString
            let trimmed = contentNS.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let markerOpen = NSRange(location: r.location, length: 2)
            let content = NSRange(location: r.location + 2, length: contentLength)
            let markerClose = NSRange(location: r.location + r.length - 2, length: 2)
            return BoldMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose)
        }
    }

    // MARK: Italic

    /// Returns ranges for all paired `*…*` or `_…_` italic markers in `string`.
    ///
    /// - Uses two passes: one for `*…*` (with look-arounds to avoid claiming `**bold**`)
    ///   and one for `_…_` (with word-boundary look-arounds per CommonMark).
    /// - Returns union of both passes as ItalicMatch values.
    static func findItalicRanges(in string: String) -> [ItalicMatch] {
        let ns = string as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var results: [ItalicMatch] = []

        // Pass 1: *…* — look-arounds prevent matching inside **bold**
        let asteriskMatches = Self.italicAsteriskRegex.matches(in: string, range: fullRange)
        for match in asteriskMatches {
            let r = match.range
            let contentLength = r.length - 2
            guard contentLength > 0 else { continue }
            let markerOpen = NSRange(location: r.location, length: 1)
            let content = NSRange(location: r.location + 1, length: contentLength)
            let markerClose = NSRange(location: r.location + r.length - 1, length: 1)
            results.append(ItalicMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose))
        }

        // Pass 2: _…_ — word-boundary look-arounds per CommonMark
        let underscoreMatches = Self.italicUnderscoreRegex.matches(in: string, range: fullRange)
        for match in underscoreMatches {
            let r = match.range
            let contentLength = r.length - 2
            guard contentLength > 0 else { continue }
            let markerOpen = NSRange(location: r.location, length: 1)
            let content = NSRange(location: r.location + 1, length: contentLength)
            let markerClose = NSRange(location: r.location + r.length - 1, length: 1)
            results.append(ItalicMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose))
        }

        return results
    }

    // MARK: Inline Code

    /// Returns ranges for all paired `` `…` `` inline code markers in `string`.
    ///
    /// - Marker ranges are 1 UTF-16 unit each (single backtick).
    /// - Unclosed backticks return nothing (D-MH-04 pair-only principle).
    static func findInlineCodeRanges(in string: String) -> [InlineCodeMatch] {
        let ns = string as NSString

        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = Self.inlineCodeRegex.matches(in: string, range: fullRange)

        return rawMatches.compactMap { match -> InlineCodeMatch? in
            let r = match.range
            let contentLength = r.length - 2
            guard contentLength > 0 else { return nil }
            let markerOpen = NSRange(location: r.location, length: 1)
            let content = NSRange(location: r.location + 1, length: contentLength)
            let markerClose = NSRange(location: r.location + r.length - 1, length: 1)
            return InlineCodeMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose)
        }
    }

    // MARK: Strikethrough

    /// Returns ranges for all paired `~~…~~` strikethrough markers in `string`.
    /// Mirrors `findBoldRanges` shape: 2-char open + content + 2-char close,
    /// degenerate empty/whitespace pairs skipped.
    static func findStrikethroughRanges(in string: String) -> [StrikethroughMatch] {
        let ns = string as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = Self.strikethroughRegex.matches(in: string, range: fullRange)

        return rawMatches.compactMap { match -> StrikethroughMatch? in
            let r = match.range
            let contentLength = r.length - 4
            guard contentLength > 0 else { return nil }
            let contentNS = ns.substring(with: NSRange(location: r.location + 2, length: contentLength)) as NSString
            let trimmed = contentNS.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let markerOpen = NSRange(location: r.location, length: 2)
            let content = NSRange(location: r.location + 2, length: contentLength)
            let markerClose = NSRange(location: r.location + r.length - 2, length: 2)
            return StrikethroughMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose)
        }
    }

    // MARK: Underline

    /// Returns ranges for all paired `<u>…</u>` underline markers in `string`.
    /// Asymmetric markers — open is 3 chars, close is 4 chars. Total non-content
    /// length = 7; degenerate empty pairs skipped.
    static func findUnderlineRanges(in string: String) -> [UnderlineMatch] {
        let ns = string as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = Self.underlineRegex.matches(in: string, range: fullRange)

        return rawMatches.compactMap { match -> UnderlineMatch? in
            let r = match.range
            let contentLength = r.length - 7
            guard contentLength > 0 else { return nil }

            let markerOpen = NSRange(location: r.location, length: 3)
            let content = NSRange(location: r.location + 3, length: contentLength)
            let markerClose = NSRange(location: r.location + r.length - 4, length: 4)
            return UnderlineMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose)
        }
    }

    // MARK: Headings

    /// Returns ranges for all `# `–`###### ` heading prefixes in `string`.
    ///
    /// - Scans line-by-line via NSString.lineRange(for:) for UTF-16 correctness.
    /// - Requires `# ` (hash + space) at line start; `#foo` does NOT match.
    /// - Levels 1–6 only; 7+ hashes are rejected.
    /// - prefixRange covers the hashes + trailing space (level + 1 UTF-16 units).
    /// - contentRange covers the heading text (trailing newline excluded).
    static func findHeadingPrefixes(in string: String) -> [HeadingMatch] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        var results: [HeadingMatch] = []
        var lineStart = 0

        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            // Extract the line text (without the trailing newline for matching)
            let lineEnd = lineRange.location + lineRange.length
            // Determine if the line ends with a newline character
            let hasTrailingNewline: Bool
            if lineRange.length > 0 {
                let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                let lastChar = ns.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n" || lastChar == "\r")
            } else {
                hasTrailingNewline = false
            }

            // Build the line content for regex matching (strip trailing newline for clean matching)
            let matchLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
            let lineMatchRange = NSRange(location: lineRange.location, length: matchLength)
            let lineText = ns.substring(with: lineMatchRange)

            // Run the heading regex against this line
            let lineNS = lineText as NSString
            let lineFullRange = NSRange(location: 0, length: lineNS.length)
            let headingMatches = Self.headingRegex.matches(in: lineText, range: lineFullRange)

            if let m = headingMatches.first {
                // Group 1 is the hashes, group 2 is the content
                let hashesRange = m.range(at: 1)
                let contentLocalRange = m.range(at: 2)

                if hashesRange.location != NSNotFound && contentLocalRange.location != NSNotFound {
                    let level = hashesRange.length
                    // Prefix covers hashes + space = level + 1 UTF-16 units
                    let prefixRange = NSRange(location: lineRange.location, length: level + 1)
                    // Content range in the full string
                    let contentRange = NSRange(
                        location: lineRange.location + contentLocalRange.location,
                        length: contentLocalRange.length
                    )
                    results.append(HeadingMatch(level: level, prefixRange: prefixRange, contentRange: contentRange))
                }
            }

            // Advance to next line
            lineStart = lineEnd
            if lineStart == lineRange.location {
                // Safety: avoid infinite loop if lineRange didn't advance
                break
            }
        }

        return results
    }

    // MARK: Bullets

    /// Returns prefix NSRanges for all `- ` or `* ` bullet list markers in `string`.
    ///
    /// - Scans line-by-line; only matches at line start.
    /// - Each returned NSRange has length 2 (the marker + space, UTF-16 units).
    /// - `-foo` (no trailing space) does NOT match.
    static func findBulletPrefixes(in string: String) -> [NSRange] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        var results: [NSRange] = []
        var lineStart = 0

        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = lineRange.location + lineRange.length

            // Extract line text for regex matching
            let hasTrailingNewline: Bool
            if lineRange.length > 0 {
                let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                let lastChar = ns.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n" || lastChar == "\r")
            } else {
                hasTrailingNewline = false
            }

            let matchLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
            let lineText = ns.substring(with: NSRange(location: lineRange.location, length: matchLength))
            let lineNS = lineText as NSString
            let lineFullRange = NSRange(location: 0, length: lineNS.length)

            let bulletMatches = Self.bulletRegex.matches(in: lineText, range: lineFullRange)
            if bulletMatches.first != nil {
                // Prefix is always 2 UTF-16 units at line start
                let prefixRange = NSRange(location: lineRange.location, length: 2)
                results.append(prefixRange)
            }

            lineStart = lineEnd
            if lineStart == lineRange.location {
                break
            }
        }

        return results
    }

    // MARK: Numbered lists

    /// Returns `NumberedMatch` values for every `N. ` numbered-list prefix in `string`.
    ///
    /// - Scans line-by-line; only matches `\d+\.` at line start followed by a space.
    /// - `markerRange` covers `N.` (digits + dot, no trailing space); variable length.
    /// - `fullPrefixRange` covers `N. ` (digits + dot + space).
    static func findNumberedPrefixes(in string: String) -> [NumberedMatch] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        var results: [NumberedMatch] = []
        var lineStart = 0

        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = lineRange.location + lineRange.length

            let hasTrailingNewline: Bool
            if lineRange.length > 0 {
                let lastChar = ns.substring(with: NSRange(location: lineEnd - 1, length: 1))
                hasTrailingNewline = (lastChar == "\n" || lastChar == "\r")
            } else {
                hasTrailingNewline = false
            }

            let matchLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
            let lineText = ns.substring(with: NSRange(location: lineRange.location, length: matchLength))
            let lineFullRange = NSRange(location: 0, length: (lineText as NSString).length)

            if let match = Self.numberedListRegex.firstMatch(in: lineText, range: lineFullRange) {
                // match covers `N.` — the digits+dot without the trailing space
                let dotEnd = match.range.location + match.range.length
                // require at least one char after the dot (the space) within the line
                guard dotEnd < matchLength else {
                    lineStart = lineEnd
                    if lineStart == lineRange.location { break }
                    continue
                }
                let markerLen = match.range.length  // e.g. 2 for "1.", 3 for "10."
                let markerRange = NSRange(location: lineRange.location, length: markerLen)
                let fullPrefixRange = NSRange(location: lineRange.location, length: markerLen + 1)
                results.append(NumberedMatch(markerRange: markerRange, fullPrefixRange: fullPrefixRange))
            }

            lineStart = lineEnd
            if lineStart == lineRange.location {
                break
            }
        }

        return results
    }

    // MARK: Blockquotes

    /// Returns prefix NSRanges for all `> ` blockquote markers in `string`.
    ///
    /// - Scans line-by-line; only matches at line start.
    /// - Each returned NSRange has length 2 (the `>` + space, UTF-16 units).
    /// - `>foo` (no trailing space) does NOT match.
    static func findBlockQuotePrefixes(in string: String) -> [NSRange] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        var results: [NSRange] = []
        var lineStart = 0

        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = lineRange.location + lineRange.length

            let hasTrailingNewline: Bool
            if lineRange.length > 0 {
                let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                let lastChar = ns.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n" || lastChar == "\r")
            } else {
                hasTrailingNewline = false
            }

            let matchLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
            let lineText = ns.substring(with: NSRange(location: lineRange.location, length: matchLength))
            let lineNS = lineText as NSString
            let lineFullRange = NSRange(location: 0, length: lineNS.length)

            if Self.blockQuoteRegex.firstMatch(in: lineText, range: lineFullRange) != nil {
                let prefixRange = NSRange(location: lineRange.location, length: 2)
                results.append(prefixRange)
            }

            lineStart = lineEnd
            if lineStart == lineRange.location {
                break
            }
        }

        return results
    }

    // MARK: Thematic breaks (`---`)

    /// Returns the line-content NSRange (no trailing newline) for every
    /// thematic-break line in `string`. A thematic break is a line containing
    /// only three-or-more `-` characters with optional surrounding spaces/tabs.
    /// CommonMark also accepts `***` and `___`, but we restrict to dashes —
    /// `***` collides with bold-italic typing (`**` + `**`) and produced
    /// surprise rules.
    ///
    /// To rule out heading underlines (`Title\n---`) and table separators,
    /// callers (MarkdownTextStorage.applyThematicBreak) should additionally
    /// check that the previous line is empty. Fenced-code-block expansion is
    /// handled at the storage layer (the reparse range subsumes the fence).
    static func findThematicBreaks(in string: String) -> [NSRange] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        var results: [NSRange] = []
        var lineStart = 0

        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = lineRange.location + lineRange.length

            let hasTrailingNewline: Bool
            if lineRange.length > 0 {
                let lastChar = ns.substring(with: NSRange(location: lineEnd - 1, length: 1))
                hasTrailingNewline = (lastChar == "\n" || lastChar == "\r")
            } else {
                hasTrailingNewline = false
            }

            let matchLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
            let lineText = ns.substring(with: NSRange(location: lineRange.location, length: matchLength))
            let lineFullRange = NSRange(location: 0, length: (lineText as NSString).length)

            if Self.thematicBreakRegex.firstMatch(in: lineText, range: lineFullRange) != nil {
                // Heading-underline guard: a `---` line directly under a non-
                // empty line is a setext H2 underline, not a thematic break.
                // Same for `===`. We don't support setext headings, but the
                // visual ambiguity is enough to skip the hairline render — the
                // user expects the dashes to read as text in that case.
                let prevLineIsEmpty: Bool
                if lineRange.location == 0 {
                    prevLineIsEmpty = true
                } else {
                    let prevLineRange = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
                    let prevText = ns.substring(with: prevLineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                    prevLineIsEmpty = prevText.isEmpty
                }
                if prevLineIsEmpty {
                    results.append(NSRange(location: lineRange.location, length: matchLength))
                }
            }

            lineStart = lineEnd
            if lineStart == lineRange.location {
                break
            }
        }

        return results
    }

    // MARK: Checklists (GFM task lists)

    /// Returns matches for all `- [ ] ` / `- [x] ` task-list prefixes in `string`.
    ///
    /// - Scans line-by-line; only matches at line start (no indentation handling
    ///   yet — keeping scope tight per the feature spec).
    /// - The dash gets `markerRange` (length 1, glyph-substituted at layout time).
    /// - The 4 chars after the dash (` [ ]` / ` [x]`) become `hiddenRange`.
    /// - Trailing space (1 char) intentionally stays VISIBLE — gives the rendered
    ///   `◯ ` / `◉ ` glyph breathing room before the content text.
    /// - `isChecked` is true when the state char is `x` or `X`.
    static func findChecklistPrefixes(in string: String) -> [ChecklistMatch] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        var results: [ChecklistMatch] = []
        var lineStart = 0

        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = lineRange.location + lineRange.length

            let hasTrailingNewline: Bool
            if lineRange.length > 0 {
                let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                let lastChar = ns.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n" || lastChar == "\r")
            } else {
                hasTrailingNewline = false
            }

            let matchLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
            let lineText = ns.substring(with: NSRange(location: lineRange.location, length: matchLength))
            let lineNS = lineText as NSString
            let lineFullRange = NSRange(location: 0, length: lineNS.length)

            if let m = Self.checklistRegex.firstMatch(in: lineText, range: lineFullRange) {
                // Group 1 is the state char (` `, `x`, or `X`).
                let stateGroup = m.range(at: 1)
                guard stateGroup.location != NSNotFound, stateGroup.length == 1 else {
                    lineStart = lineEnd
                    if lineStart == lineRange.location { break }
                    continue
                }
                let stateChar = lineNS.substring(with: stateGroup).lowercased()
                let isChecked = (stateChar == "x")

                let base = lineRange.location
                let markerRange = NSRange(location: base, length: 1)        // `-`
                let hiddenRange = NSRange(location: base + 1, length: 4)    // ` [ ]` or ` [x]`
                // Content starts after the trailing space (6 chars total prefix).
                // Total prefix is always 6; line content range is the rest of the
                // line (excluding the trailing newline if present).
                let contentStart = base + 6
                let contentEnd = lineRange.location + matchLength
                let contentLen = max(0, contentEnd - contentStart)
                let contentRange = NSRange(location: contentStart, length: contentLen)

                results.append(ChecklistMatch(
                    markerRange: markerRange,
                    hiddenRange: hiddenRange,
                    contentRange: contentRange,
                    isChecked: isChecked
                ))
            }

            lineStart = lineEnd
            if lineStart == lineRange.location {
                break
            }
        }

        return results
    }

    // MARK: Links

    /// Finds fully-closed markdown link patterns `[label](url)` per D-LR-01 (pair-only-hide).
    /// Returns empty when no closed pair exists. Regex pattern per D-LR-06:
    /// `\[([^\]\n]+)\]\(([^)\n]*)\)` — capture group 1 = label, group 2 = url.
    /// UTF-16-safe — all NSRanges are in UTF-16 code units relative to `string`.
    static func findLinkRanges(in string: String) -> [LinkMatch] {
        let ns = string as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = Self.linkRegex.matches(in: string, range: fullRange)
        return rawMatches.compactMap { match -> LinkMatch? in
            let labelRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            guard labelRange.location != NSNotFound,
                  urlRange.location != NSNotFound else { return nil }
            let full = match.range
            // Reconstruct bracket/paren ranges by construction:
            //   "[" = full.location (length 1)
            //   label = labelRange
            //   "]" = labelRange.location + labelRange.length (length 1)
            //   "(" = closeBracket.location + 1 (length 1)
            //   url = urlRange
            //   ")" = urlRange.location + urlRange.length (length 1)
            let openBracket = NSRange(location: full.location, length: 1)
            let closeBracket = NSRange(location: labelRange.location + labelRange.length, length: 1)
            let openParen = NSRange(location: closeBracket.location + 1, length: 1)
            let closeParen = NSRange(location: urlRange.location + urlRange.length, length: 1)
            return LinkMatch(
                openBracketRange: openBracket,
                labelRange: labelRange,
                closeBracketRange: closeBracket,
                openParenRange: openParen,
                urlRange: urlRange,
                closeParenRange: closeParen
            )
        }
    }

    /// Bare-URL detector for the link-chip render path (Phase B). Uses
    /// `NSDataDetector(.link)` because manual http(s) regex chokes on URL
    /// edge cases (parens, trailing punctuation) that DataDetector already
    /// handles. Returns ranges that do NOT overlap any markdown link bracket
    /// pair from `findLinkRanges`, so `[label](url)` patterns retain their
    /// existing styled-label behavior.
    static func findAutoLinkRanges(in string: String) -> [NSRange] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        let detector: NSDataDetector
        do {
            detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch {
            return []
        }

        // Build a "claimed" mask of UTF-16 ranges covered by any markdown
        // link's `[...]( ... )` span — auto-link candidates that fall inside
        // are dropped (the [label](url) path already styles them).
        let mdLinks = findLinkRanges(in: string)
        let claimedSpans: [NSRange] = mdLinks.map { m in
            // Full bracket-paren span: openBracket → closeParen.
            let start = m.openBracketRange.location
            let end = m.closeParenRange.location + m.closeParenRange.length
            return NSRange(location: start, length: end - start)
        }

        let candidates = detector.matches(in: string, range: NSRange(location: 0, length: fullLength))
        return candidates.compactMap { r -> NSRange? in
            let range = r.range
            guard range.length > 0,
                  range.location + range.length <= fullLength else { return nil }
            for claimed in claimedSpans {
                if NSIntersectionRange(range, claimed).length > 0 { return nil }
            }
            return range
        }
    }

    /// Compute the display label for a link-chip pill. Strips `http://` /
    /// `https://`, leading `www.`, trailing `/`. Falls back to the raw URL
    /// if stripping would yield an empty string.
    static func chipDisplayText(forURL urlString: String) -> String {
        var s = urlString
        if s.hasPrefix("https://") { s.removeFirst("https://".count) }
        else if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        if s.hasPrefix("www.") { s.removeFirst("www.".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? urlString : s
    }

    // MARK: Fenced Code Blocks

    /// Returns matches for all paired ` ``` `…` ``` ` fenced code blocks in `string`.
    ///
    /// - Scans line-by-line; a line matching `^```[a-zA-Z0-9]*$` opens a fence.
    /// - fenceOpenRange covers the opening fence line including its trailing newline.
    /// - contentRange covers all lines between the fences (including their newlines).
    /// - fenceCloseRange covers the closing fence line including its trailing newline.
    /// - Unterminated fences (no closing line) return nothing — D-MH-04 pair principle.
    static func findFencedCodeBlocks(in string: String) -> [FencedCodeMatch] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        var results: [FencedCodeMatch] = []
        var inFence = false
        var fenceOpenRange = NSRange(location: 0, length: 0)
        var contentStart = 0
        var lineStart = 0

        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = lineRange.location + lineRange.length

            // Extract line text without trailing newline for fence detection
            let hasTrailingNewline: Bool
            if lineRange.length > 0 {
                let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                let lastChar = ns.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n" || lastChar == "\r")
            } else {
                hasTrailingNewline = false
            }

            let matchLength = hasTrailingNewline ? lineRange.length - 1 : lineRange.length
            let lineText = ns.substring(with: NSRange(location: lineRange.location, length: matchLength))
            let lineNS = lineText as NSString
            let lineFullRange = NSRange(location: 0, length: lineNS.length)

            let isFenceLine = Self.fenceRegex.firstMatch(in: lineText, range: lineFullRange) != nil

            if isFenceLine {
                if !inFence {
                    // Opening fence: record open range (includes trailing newline)
                    inFence = true
                    fenceOpenRange = lineRange
                    contentStart = lineEnd
                } else {
                    // Closing fence: emit match
                    inFence = false
                    let fenceCloseRange = lineRange
                    let contentLength = lineRange.location - contentStart
                    let contentRange = NSRange(location: contentStart, length: max(0, contentLength))
                    results.append(FencedCodeMatch(
                        fenceOpenRange: fenceOpenRange,
                        contentRange: contentRange,
                        fenceCloseRange: fenceCloseRange
                    ))
                }
            }

            lineStart = lineEnd
            if lineStart == lineRange.location {
                break
            }
        }

        // Unterminated fence (inFence == true at end of string): yield NO match per spec
        return results
    }

    // MARK: Tables

    /// Returns matches for all GFM-style markdown tables in `string`.
    ///
    /// Detection rules (deliberately permissive):
    ///   - Header line: contains at least one `|` and at least one non-pipe char.
    ///   - Separator line (immediately below header): contains only whitespace,
    ///     pipes, colons, and dashes; AND has at least one `|`; AND has at least one `-`.
    ///   - Body lines: each subsequent line containing `|`, until the first
    ///     non-pipe line (or end of string).
    ///
    /// Unterminated tables (header without a matching separator) return nothing —
    /// matches the pair-only-hide principle (D-MH-04). All NSRanges are UTF-16.
    static func findTableBlocks(in string: String) -> [TableMatch] {
        let ns = string as NSString
        let fullLength = ns.length
        guard fullLength > 0 else { return [] }

        // Lines inside a fenced code block are claimed by the fence and must not
        // be re-interpreted as table syntax (CommonMark: code spans win, and
        // visually `\`\`\`` blocks must preserve the literal source line-for-line).
        let fenceContentRanges = findFencedCodeBlocks(in: string).map(\.contentRange)
        func intersectsFence(_ r: NSRange) -> Bool {
            fenceContentRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }

        // Pre-scan: collect line ranges (location + length, with trailing newline included).
        var lineRanges: [NSRange] = []
        var lineStart = 0
        while lineStart < fullLength {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            lineRanges.append(lineRange)
            let nextStart = lineRange.location + lineRange.length
            if nextStart == lineStart { break }
            lineStart = nextStart
        }

        var results: [TableMatch] = []
        var i = 0
        while i + 1 < lineRanges.count {
            let headerLineText = lineContent(in: ns, lineRange: lineRanges[i])
            let separatorLineText = lineContent(in: ns, lineRange: lineRanges[i + 1])

            if intersectsFence(lineRanges[i]) || intersectsFence(lineRanges[i + 1]) {
                i += 1
                continue
            }

            if isPipeLine(headerLineText) && isSeparatorLine(separatorLineText) {
                // Walk forward to collect contiguous body lines.
                var lastBodyIdx: Int? = nil
                var j = i + 2
                while j < lineRanges.count {
                    let bodyText = lineContent(in: ns, lineRange: lineRanges[j])
                    if isPipeLine(bodyText) {
                        lastBodyIdx = j
                        j += 1
                    } else {
                        break
                    }
                }

                let headerRange = trimTrailingNewline(lineRanges[i], in: ns)
                let separatorRange = lineRanges[i + 1]  // include newline so layout collapses the row
                let bodyRange: NSRange
                if let lastBodyIdx {
                    let bodyStart = lineRanges[i + 2].location
                    let bodyLast = lineRanges[lastBodyIdx]
                    let bodyEnd = bodyLast.location + bodyLast.length
                    bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
                } else {
                    let after = lineRanges[i + 1].location + lineRanges[i + 1].length
                    bodyRange = NSRange(location: after, length: 0)
                }

                var pipeRanges: [NSRange] = []
                collectPipeOffsets(in: headerRange, ns: ns, into: &pipeRanges)
                if bodyRange.length > 0 {
                    collectPipeOffsets(in: bodyRange, ns: ns, into: &pipeRanges)
                }

                results.append(TableMatch(
                    headerRange: headerRange,
                    separatorRange: separatorRange,
                    bodyRange: bodyRange,
                    pipeRanges: pipeRanges
                ))

                // Advance past the table.
                i = (lastBodyIdx ?? (i + 1)) + 1
            } else {
                i += 1
            }
        }

        return results
    }

    // MARK: - Table helpers

    /// Returns the line text without its trailing newline (if any).
    private static func lineContent(in ns: NSString, lineRange: NSRange) -> String {
        let trimmed = trimTrailingNewline(lineRange, in: ns)
        return ns.substring(with: trimmed)
    }

    /// Returns `lineRange` with a trailing `\n` or `\r` stripped (if present).
    private static func trimTrailingNewline(_ lineRange: NSRange, in ns: NSString) -> NSRange {
        guard lineRange.length > 0 else { return lineRange }
        let lastIdx = lineRange.location + lineRange.length - 1
        let last = ns.substring(with: NSRange(location: lastIdx, length: 1))
        if last == "\n" || last == "\r" {
            return NSRange(location: lineRange.location, length: lineRange.length - 1)
        }
        return lineRange
    }

    private static func isPipeLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A separator line uses only whitespace / `|` / `:` / `-`, contains at least
    /// one `|`, and at least one `-`. Permissive enough to allow `--- | ---`
    /// (no outer pipes) and alignment colons (`:---:`).
    private static func isSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let allowed: Set<Character> = ["|", "-", ":", " ", "\t"]
        return trimmed.allSatisfy { allowed.contains($0) }
    }

    /// Append a length-1 NSRange for every `|` inside `range` to `out`.
    private static func collectPipeOffsets(
        in range: NSRange,
        ns: NSString,
        into out: inout [NSRange]
    ) {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= ns.length else { return }
        let scanRange = range
        var searchStart = scanRange.location
        let scanEnd = scanRange.location + scanRange.length
        while searchStart < scanEnd {
            let remaining = NSRange(location: searchStart, length: scanEnd - searchStart)
            let found = ns.range(of: "|", options: [], range: remaining)
            if found.location == NSNotFound { break }
            out.append(NSRange(location: found.location, length: 1))
            searchStart = found.location + 1
        }
    }
}
