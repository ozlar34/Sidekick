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
    private static let bulletRegex = try! NSRegularExpression(
        pattern: "^(- |\\* )",
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
