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

// MARK: - MarkdownInlineParser

/// Namespace type for all markdown range-finding pure functions.
/// All returned NSRanges are UTF-16 offsets (NSRange-compatible).
enum MarkdownInlineParser {

    // MARK: Bold

    /// Returns ranges for all paired `**…**` bold markers in `string`.
    ///
    /// - Each BoldMatch contains UTF-16 NSRanges for the open marker (length 2),
    ///   the content between markers, and the close marker (length 2).
    /// - Unclosed pairs (e.g. `**foo` with no closing `**`) return nothing — D-MH-04.
    /// - Degenerate empty pairs (e.g. `** **`) are skipped (zero-length content).
    static func findBoldRanges(in string: String) -> [BoldMatch] {
        let ns = string as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "\\*\\*([^*]|\\*(?!\\*))+?\\*\\*",
            options: []
        ) else { return [] }

        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = regex.matches(in: string, range: fullRange)

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
        if let asteriskRegex = try? NSRegularExpression(
            pattern: "(?<!\\*)\\*(?!\\*)([^*\\n]+?)(?<!\\*)\\*(?!\\*)",
            options: []
        ) {
            let asteriskMatches = asteriskRegex.matches(in: string, range: fullRange)
            for match in asteriskMatches {
                let r = match.range
                let contentLength = r.length - 2
                guard contentLength > 0 else { continue }
                let markerOpen = NSRange(location: r.location, length: 1)
                let content = NSRange(location: r.location + 1, length: contentLength)
                let markerClose = NSRange(location: r.location + r.length - 1, length: 1)
                results.append(ItalicMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose))
            }
        }

        // Pass 2: _…_ — word-boundary look-arounds per CommonMark
        if let underscoreRegex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])_([^_\\n]+?)_(?![A-Za-z0-9_])",
            options: []
        ) {
            let underscoreMatches = underscoreRegex.matches(in: string, range: fullRange)
            for match in underscoreMatches {
                let r = match.range
                let contentLength = r.length - 2
                guard contentLength > 0 else { continue }
                let markerOpen = NSRange(location: r.location, length: 1)
                let content = NSRange(location: r.location + 1, length: contentLength)
                let markerClose = NSRange(location: r.location + r.length - 1, length: 1)
                results.append(ItalicMatch(markerOpenRange: markerOpen, contentRange: content, markerCloseRange: markerClose))
            }
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
        guard let regex = try? NSRegularExpression(
            pattern: "`([^`\\n]+?)`",
            options: []
        ) else { return [] }

        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = regex.matches(in: string, range: fullRange)

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

        guard let headingRegex = try? NSRegularExpression(
            pattern: "^(#{1,6}) (.*)$",
            options: []
        ) else { return [] }

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
            let headingMatches = headingRegex.matches(in: lineText, range: lineFullRange)

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

        guard let bulletRegex = try? NSRegularExpression(
            pattern: "^(- |\\* )",
            options: []
        ) else { return [] }

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

            let bulletMatches = bulletRegex.matches(in: lineText, range: lineFullRange)
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

    // MARK: Links

    /// Finds fully-closed markdown link patterns `[label](url)` per D-LR-01 (pair-only-hide).
    /// Returns empty when no closed pair exists. Regex pattern per D-LR-06:
    /// `\[([^\]\n]+)\]\(([^)\n]*)\)` — capture group 1 = label, group 2 = url.
    /// UTF-16-safe — all NSRanges are in UTF-16 code units relative to `string`.
    static func findLinkRanges(in string: String) -> [LinkMatch] {
        let ns = string as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]*)\\)",
            options: []
        ) else { return [] }
        let fullRange = NSRange(location: 0, length: ns.length)
        let rawMatches = regex.matches(in: string, range: fullRange)
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

        guard let fenceRegex = try? NSRegularExpression(
            pattern: "^```[a-zA-Z0-9]*$",
            options: []
        ) else { return [] }

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

            let isFenceLine = fenceRegex.firstMatch(in: lineText, range: lineFullRange) != nil

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
}
