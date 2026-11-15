/// Pure-function markdown range finder for the hybrid live-preview editor.
///
/// Locates marker-vs-content NSRanges for every supported construct (bold,
/// italic, inline code, strikethrough, underline, headings, bullets,
/// numbered lists, blockquotes, thematic breaks, checklists, links, fenced
/// code, tables). All offsets are UTF-16 code units (NSRange-compatible) so
/// output drops straight into NSTextStorage.setAttributes(_:range:). No
/// AppKit imports — keeps the layer trivially unit-testable and
/// main-actor-free.
import Foundation

// MARK: - Result types

/// Shared shape for every "marker regex whose match is open+content+close"
/// construct: bold, italic, inline code, strikethrough, underline.
struct MarkerPairMatch {
    let markerOpenRange: NSRange
    let contentRange: NSRange
    let markerCloseRange: NSRange
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

/// GFM task-list prefix `- [ ] ` / `- [x] ` (6 UTF-16 units). Trailing space
/// stays visible so the rendered result reads `○ item`, not `○item`.
struct ChecklistMatch {
    /// The `-` at line start; glyph-substituted to ○/●.
    let markerRange: NSRange
    /// ` [ ]` / ` [x]` — hidden via `.sidekickHiddenMarker`.
    let hiddenRange: NSRange
    /// Line content after the prefix, excluding any trailing newline.
    let contentRange: NSRange
    let isChecked: Bool
}

/// Numbered-list prefix `N. `; `markerRange` covers just `N.` (excluding the
/// trailing space) so `.secondaryLabelColor` applies to the marker only.
struct NumberedMatch {
    let markerRange: NSRange
}

struct TableMatch {
    /// Header line content, excluding trailing newline.
    let headerRange: NSRange
    /// Separator line INCLUDING its trailing newline — hiding it collapses
    /// the `| --- | --- |` row entirely.
    let separatorRange: NSRange
    /// Combined body lines (contiguous); length 0 when there are no body rows.
    let bodyRange: NSRange
    /// Every `|` in header + body, for fading pipes to a subtle color.
    let pipeRanges: [NSRange]
}

// MARK: - MarkdownInlineParser

/// Namespace type for all markdown range-finding pure functions.
/// All returned NSRanges are UTF-16 offsets (NSRange-compatible).
enum MarkdownInlineParser {

    // MARK: - Cached regexes
    // Compiled once per process. `try!` is safe: these are compile-time-
    // constant patterns; a compile failure indicates a code defect, not a
    // runtime condition.
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]|\\*(?!\\*))+?\\*\\*")
    private static let italicAsteriskRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)([^*\\n]+?)(?<!\\*)\\*(?!\\*)")
    private static let italicUnderscoreRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])_([^_\\n]+?)_(?![A-Za-z0-9_])")
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`([^`\\n]+?)`")
    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6}) (.*)$")
    // Bullet pattern excludes task-list lines via negative lookahead: a line
    // starting with `- [ ] ` or `- [x] ` / `- [X] ` is a checklist, not a
    // plain bullet, so the dash must NOT be tagged with `.sidekickBulletMarker`
    // (would clash with `.sidekickChecklistMarker`).
    private static let bulletRegex = try! NSRegularExpression(pattern: "^(- (?!\\[[ xX]\\] )|\\* )")
    private static let numberedListRegex = try! NSRegularExpression(pattern: #"^\d+\."#)
    private static let checklistRegex = try! NSRegularExpression(pattern: "^- \\[([ xX])\\] ")
    private static let blockQuoteRegex = try! NSRegularExpression(pattern: "^> ")
    // Thematic break: a line of only `-`, `*`, or `_` (3+, single marker
    // class, optional surrounding whitespace). Whole-line anchoring is what
    // disambiguates this from inline emphasis: `**bold**` has content
    // characters between the markers and so can never match `^…$`.
    private static let thematicBreakRegex = try! NSRegularExpression(pattern: "^[ \\t]*(?:-{3,}|\\*{3,}|_{3,})[ \\t]*$")
    private static let fenceRegex = try! NSRegularExpression(pattern: "^```[a-zA-Z0-9]*$")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]*)\\)")
    private static let strikethroughRegex = try! NSRegularExpression(pattern: "~~([^~\\n]+?)~~")
    // Underline is HTML, not markdown (`<u>foo</u>`); unclosed tags are
    // dropped (pair-only-hide).
    private static let underlineRegex = try! NSRegularExpression(pattern: "<u>([^\\n]+?)</u>")

    // MARK: - Line-walking helper

    /// Walks `string` line-by-line (`NSString.lineRange`), invoking `body`
    /// with the line's full range (including its terminator), that range
    /// with any trailing `\n`/`\r` stripped, and the trimmed range's text.
    /// Centralizes the one infinite-loop guard needed when `lineRange` fails
    /// to advance.
    private static func forEachLine(in string: String, _ body: (NSRange, NSRange, String) -> Void) {
        let ns = string as NSString
        var lineStart = 0
        while lineStart < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentRange = trimTrailingNewline(lineRange, in: ns)
            body(lineRange, contentRange, ns.substring(with: contentRange))

            let nextStart = lineRange.location + lineRange.length
            if nextStart == lineStart { break }
            lineStart = nextStart
        }
    }

    // MARK: - Paired-marker helper

    /// Shared implementation for bold / italic / inline-code / strikethrough
    /// / underline: every one of these is "regex match → subtract marker
    /// widths → emit (open, content, close)". `openLength`/`closeLength` are
    /// the marker widths on each side (asymmetric for underline: `<u>`/`</u>`
    /// are 3/4). `skipBlank` drops degenerate whitespace-only content (e.g.
    /// `** **`) — only bold/strikethrough opt into this.
    private static func pairedRanges(
        _ regex: NSRegularExpression,
        in string: String,
        openLength: Int,
        closeLength: Int,
        skipBlank: Bool
    ) -> [MarkerPairMatch] {
        let ns = string as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = regex.matches(in: string, range: fullRange)

        return rawMatches.compactMap { match -> MarkerPairMatch? in
            let r = match.range
            let contentLength = r.length - openLength - closeLength
            guard contentLength > 0 else { return nil }

            if skipBlank {
                let content = ns.substring(with: NSRange(location: r.location + openLength, length: contentLength))
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            }

            return MarkerPairMatch(
                markerOpenRange: NSRange(location: r.location, length: openLength),
                contentRange: NSRange(location: r.location + openLength, length: contentLength),
                markerCloseRange: NSRange(location: r.location + r.length - closeLength, length: closeLength)
            )
        }
    }

    // MARK: Bold

    /// Returns ranges for every paired `**…**` bold marker. Unclosed pairs
    /// and degenerate whitespace-only pairs (e.g. `** **`) return nothing.
    static func findBoldRanges(in string: String) -> [MarkerPairMatch] {
        pairedRanges(boldRegex, in: string, openLength: 2, closeLength: 2, skipBlank: true)
    }

    // MARK: Italic

    /// Returns ranges for every paired `*…*` or `_…_` italic marker: one
    /// pass per delimiter. Look-arounds keep `*…*` from claiming `**bold**`;
    /// `_…_` uses CommonMark's word-boundary look-arounds.
    static func findItalicRanges(in string: String) -> [MarkerPairMatch] {
        pairedRanges(italicAsteriskRegex, in: string, openLength: 1, closeLength: 1, skipBlank: false)
            + pairedRanges(italicUnderscoreRegex, in: string, openLength: 1, closeLength: 1, skipBlank: false)
    }

    // MARK: Inline Code

    /// Returns ranges for every paired `` `…` `` inline code marker.
    /// Unclosed backticks return nothing.
    static func findInlineCodeRanges(in string: String) -> [MarkerPairMatch] {
        pairedRanges(inlineCodeRegex, in: string, openLength: 1, closeLength: 1, skipBlank: false)
    }

    // MARK: Strikethrough

    /// Returns ranges for every paired `~~…~~` strikethrough marker. Mirrors
    /// `findBoldRanges`: degenerate empty/whitespace pairs are skipped.
    static func findStrikethroughRanges(in string: String) -> [MarkerPairMatch] {
        pairedRanges(strikethroughRegex, in: string, openLength: 2, closeLength: 2, skipBlank: true)
    }

    // MARK: Underline

    /// Returns ranges for every paired `<u>…</u>` underline marker. Markers
    /// are asymmetric: open is 3 chars, close is 4.
    static func findUnderlineRanges(in string: String) -> [MarkerPairMatch] {
        pairedRanges(underlineRegex, in: string, openLength: 3, closeLength: 4, skipBlank: false)
    }

    // MARK: Headings

    /// Returns ranges for every `# ` – `###### ` heading prefix (levels 1–6
    /// only; `#foo` with no trailing space does not match). `prefixRange`
    /// covers the hashes + space; `contentRange` excludes the trailing
    /// newline.
    static func findHeadingPrefixes(in string: String) -> [HeadingMatch] {
        var results: [HeadingMatch] = []
        forEachLine(in: string) { lineRange, _, lineText in
            let lineNS = lineText as NSString
            guard let m = headingRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)) else { return }
            // Both capture groups are mandatory in a successful match — no
            // NSNotFound guard needed.
            let level = m.range(at: 1).length
            let contentLocal = m.range(at: 2)
            results.append(HeadingMatch(
                level: level,
                prefixRange: NSRange(location: lineRange.location, length: level + 1),
                contentRange: NSRange(location: lineRange.location + contentLocal.location, length: contentLocal.length)
            ))
        }
        return results
    }

    // MARK: Bullets

    /// Returns the `- `/`* ` prefix range (2 UTF-16 units) for every bullet
    /// list line (line start only; `-foo` with no trailing space does not
    /// match).
    static func findBulletPrefixes(in string: String) -> [NSRange] {
        var results: [NSRange] = []
        forEachLine(in: string) { lineRange, _, lineText in
            guard bulletRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) != nil else { return }
            results.append(NSRange(location: lineRange.location, length: 2))
        }
        return results
    }

    // MARK: Numbered lists

    /// Returns a `NumberedMatch` for every `N. ` numbered-list prefix at
    /// line start. DO NOT "fix": the guard only requires one more char after
    /// the dot, not specifically a space, so `1.foo` currently matches too.
    static func findNumberedPrefixes(in string: String) -> [NumberedMatch] {
        var results: [NumberedMatch] = []
        forEachLine(in: string) { lineRange, _, lineText in
            let lineNS = lineText as NSString
            guard let match = numberedListRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)) else { return }
            let dotEnd = match.range.location + match.range.length
            guard dotEnd < lineNS.length else { return }
            results.append(NumberedMatch(markerRange: NSRange(location: lineRange.location, length: match.range.length)))
        }
        return results
    }

    // MARK: Blockquotes

    /// Returns the `> ` prefix range (2 UTF-16 units) for every blockquote
    /// line (line start only; `>foo` with no trailing space does not match).
    static func findBlockQuotePrefixes(in string: String) -> [NSRange] {
        var results: [NSRange] = []
        forEachLine(in: string) { lineRange, _, lineText in
            guard blockQuoteRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) != nil else { return }
            results.append(NSRange(location: lineRange.location, length: 2))
        }
        return results
    }

    // MARK: Thematic breaks (`---` / `***` / `___`)

    /// Returns the line-content NSRange (no trailing newline) for every
    /// thematic-break line. Lines inside a fenced code block are excluded —
    /// `---` inside a fence is source text, not an HR.
    ///
    /// No previous-line-empty guard: Sidekick doesn't render setext
    /// headings, so a `---` line is always an HR regardless of what's above
    /// it (a prior empty-line guard caused paragraph-scoped vs full-doc
    /// reparses to disagree, producing an HR-appears-then-vanishes bug).
    static func findThematicBreaks(in string: String) -> [NSRange] {
        let fenceContentRanges = findFencedCodeBlocks(in: string).map(\.contentRange)
        func intersectsFence(_ r: NSRange) -> Bool {
            fenceContentRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }

        var results: [NSRange] = []
        forEachLine(in: string) { _, contentRange, lineText in
            guard thematicBreakRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) != nil else { return }
            if !intersectsFence(contentRange) {
                results.append(contentRange)
            }
        }
        return results
    }

    // MARK: Checklists (GFM task lists)

    /// Returns a `ChecklistMatch` for every `- [ ] ` / `- [x] ` task-list
    /// prefix at line start (no indentation handling). `isChecked` is true
    /// for `x` or `X`.
    static func findChecklistPrefixes(in string: String) -> [ChecklistMatch] {
        var results: [ChecklistMatch] = []
        forEachLine(in: string) { lineRange, contentRange, lineText in
            let lineNS = lineText as NSString
            guard let m = checklistRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)) else { return }
            // Group 1 (the state char) is a mandatory capture in a
            // successful match, so it's always present — no NSNotFound guard
            // needed.
            let isChecked = lineNS.substring(with: m.range(at: 1)).lowercased() == "x"

            let base = lineRange.location
            let contentStart = base + 6
            let contentEnd = contentRange.location + contentRange.length
            results.append(ChecklistMatch(
                markerRange: NSRange(location: base, length: 1),
                hiddenRange: NSRange(location: base + 1, length: 4),
                contentRange: NSRange(location: contentStart, length: max(0, contentEnd - contentStart)),
                isChecked: isChecked
            ))
        }
        return results
    }

    // MARK: Links

    /// Finds fully-closed markdown link patterns `[label](url)`; returns
    /// nothing for an unclosed pair. Group 1 = label, group 2 = url.
    /// UTF-16-safe — all NSRanges are in UTF-16 code units relative to `string`.
    static func findLinkRanges(in string: String) -> [LinkMatch] {
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let rawMatches = linkRegex.matches(in: string, range: fullRange)
        return rawMatches.compactMap { match -> LinkMatch? in
            let labelRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            guard labelRange.location != NSNotFound,
                  urlRange.location != NSNotFound else { return nil }
            let full = match.range
            // Bracket/paren ranges are reconstructed positionally around the
            // two capture groups.
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

    /// Bare-URL detector for the link-chip render path, using
    /// `NSDataDetector(.link)` because a manual http(s) regex chokes on URL
    /// edge cases (parens, trailing punctuation) DataDetector already
    /// handles. Excludes ranges inside any `[label](url)` span from
    /// `findLinkRanges` — those already get styled-label treatment.
    static func findAutoLinkRanges(in string: String) -> [NSRange] {
        let ns = string as NSString
        guard ns.length > 0,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }

        let claimedSpans = findLinkRanges(in: string).map { NSUnionRange($0.openBracketRange, $0.closeParenRange) }

        let candidates = detector.matches(in: string, range: NSRange(location: 0, length: ns.length))
        return candidates.compactMap { r -> NSRange? in
            let range = r.range
            guard range.length > 0,
                  range.location + range.length <= ns.length,
                  !claimedSpans.contains(where: { NSIntersectionRange(range, $0).length > 0 }) else { return nil }
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

    /// Returns every paired ` ``` `…` ``` ` fenced code block. A line
    /// matching `^```[a-zA-Z0-9]*$` opens/closes a fence; an unterminated
    /// fence (no closing line) yields nothing. Open/close ranges include
    /// their trailing newline; contentRange spans the lines between them.
    static func findFencedCodeBlocks(in string: String) -> [FencedCodeMatch] {
        var results: [FencedCodeMatch] = []
        var openFenceRange: NSRange?
        forEachLine(in: string) { lineRange, _, lineText in
            guard fenceRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) != nil else { return }
            if let fenceOpenRange = openFenceRange {
                let contentStart = fenceOpenRange.location + fenceOpenRange.length
                results.append(FencedCodeMatch(
                    fenceOpenRange: fenceOpenRange,
                    contentRange: NSRange(location: contentStart, length: max(0, lineRange.location - contentStart)),
                    fenceCloseRange: lineRange
                ))
                openFenceRange = nil
            } else {
                openFenceRange = lineRange
            }
        }
        return results
    }

    // MARK: Tables

    /// Returns every GFM-style markdown table (deliberately permissive
    /// detection):
    ///   - Header line: at least one `|` and at least one non-pipe char.
    ///   - Separator line (immediately below): only whitespace/`|`/`:`/`-`,
    ///     with at least one `|` and one `-`.
    ///   - Body lines: subsequent `|`-containing lines, until the first
    ///     non-pipe line or end of string.
    /// A header without a matching separator yields nothing.
    static func findTableBlocks(in string: String) -> [TableMatch] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }

        // Lines inside a fenced code block are claimed by the fence and must not
        // be re-interpreted as table syntax (CommonMark: code spans win, and
        // visually `\`\`\`` blocks must preserve the literal source line-for-line).
        let fenceContentRanges = findFencedCodeBlocks(in: string).map(\.contentRange)
        func intersectsFence(_ r: NSRange) -> Bool {
            fenceContentRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }

        var lineRanges: [NSRange] = []
        forEachLine(in: string) { lineRange, _, _ in
            lineRanges.append(lineRange)
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

                let pipeRanges = collectPipeOffsets(in: headerRange, ns: ns) + collectPipeOffsets(in: bodyRange, ns: ns)

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
        ns.substring(with: trimTrailingNewline(lineRange, in: ns))
    }

    /// Returns `lineRange` with its trailing `\r\n`, `\n` or `\r` stripped (if present).
    private static func trimTrailingNewline(_ lineRange: NSRange, in ns: NSString) -> NSRange {
        var length = lineRange.length
        if length > 0, ns.character(at: lineRange.location + length - 1) == 0x0A /* \n */ { length -= 1 }
        if length > 0, ns.character(at: lineRange.location + length - 1) == 0x0D /* \r */ { length -= 1 }
        return NSRange(location: lineRange.location, length: length)
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

    /// Every `|` (U+007C) inside `range`, as length-1 NSRanges, in ascending order.
    private static func collectPipeOffsets(in range: NSRange, ns: NSString) -> [NSRange] {
        guard range.length > 0,
              range.location + range.length <= ns.length else { return [] }
        var out: [NSRange] = []
        for i in range.location..<(range.location + range.length) where ns.character(at: i) == 0x7C {
            out.append(NSRange(location: i, length: 1))
        }
        return out
    }
}
