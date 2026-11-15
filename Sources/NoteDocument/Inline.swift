import Foundation

/// Reads and writes the inline marks of one line. Scope of this slice: bold with `**` or `__`;
/// backslash escapes for `*`, `_`, `\`. Everything else is literal text.
enum InlineReader {
    private static func isEscapable(_ c: Unicode.Scalar) -> Bool { c == "*" || c == "_" || c == "\\" }

    static func read(_ s: [Unicode.Scalar]) -> [Run] {
        var runs: [Run] = []
        var plain = String.UnicodeScalarView()
        func flush() { if !plain.isEmpty { runs.append(Run(String(plain))); plain = .init() } }
        var i = 0
        let n = s.count
        while i < n {
            let c = s[i]
            if c == "\\", i + 1 < n, isEscapable(s[i + 1]) {
                plain.append(s[i + 1]); i += 2; continue
            }
            if (c == "*" || c == "_"), i + 1 < n, s[i + 1] == c, let (content, end) = boldSpan(s, open: i) {
                flush()
                runs.append(Run(content, bold: c == "*" ? .asterisks : .underscores))
                i = end
                continue
            }
            plain.append(c); i += 1
        }
        flush()
        return Block.normalize(runs)
    }

    /// `open` points at the first delimiter scalar. Returns the unescaped content and the index after the closing delimiter.
    private static func boldSpan(_ s: [Unicode.Scalar], open: Int) -> (String, Int)? {
        let d = s[open], n = s.count
        let j = open + 2
        guard j < n, !s[j].properties.isWhitespace else { return nil }
        var k = j
        while k < n {
            if s[k] == "\\", k + 1 < n, isEscapable(s[k + 1]) { k += 2; continue }
            if s[k] == d, k + 1 < n, s[k + 1] == d, k > j, !s[k - 1].properties.isWhitespace {
                return (unescape(s[j..<k]), k + 2)
            }
            k += 1
        }
        return nil
    }

    private static func unescape(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var out = String.UnicodeScalarView()
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", i + 1 < s.endIndex, isEscapable(s[i + 1]) { out.append(s[i + 1]); i += 2 }
            else { out.append(s[i]); i += 1 }
        }
        return String(out)
    }

    /// True when `s` would read as an ATX heading: 1 to 6 hashes, then end of line, space or tab.
    static func looksLikeHeading(_ s: [Unicode.Scalar]) -> Bool {
        var h = 0
        while h < s.count, s[h] == "#" { h += 1 }
        guard (1...6).contains(h) else { return false }
        return h == s.count || s[h] == " " || s[h] == "\t"
    }
}

enum InlineWriter {
    /// Generates inline text such that `InlineReader.read` gives the same runs back (fidelity rule 3).
    /// `atLineStart`: the text starts a paragraph, so a leading heading-like `#` run needs an escape.
    static func write(_ runs: [Run], atLineStart: Bool) -> String {
        var out = String.UnicodeScalarView()
        for (idx, run) in runs.enumerated() {
            let s = Array(run.text.unicodeScalars)
            let hasPrev = idx > 0, hasNext = idx + 1 < runs.count
            let isStart = atLineStart && idx == 0
            if let d = run.bold { out.append(contentsOf: d.rawValue.unicodeScalars) }
            for (p, c) in s.enumerated() {
                let next: Unicode.Scalar? = p + 1 < s.count ? s[p + 1] : nil
                switch c {
                case "*":
                    out.append("\\"); out.append(c)
                case "_":
                    let underscoreAdjacent = (p > 0 && s[p - 1] == "_") || next == "_"
                    let atEdge = (p == 0 && (hasPrev || run.bold != nil)) || (p == s.count - 1 && (hasNext || run.bold != nil))
                    if run.bold == .underscores || underscoreAdjacent || atEdge { out.append("\\") }
                    out.append(c)
                case "\\":
                    var escape = false
                    if let nx = next { escape = nx == "*" || nx == "_" || nx == "\\" }
                    else { escape = hasNext || run.bold != nil }
                    if !escape, isStart, p == 0, run.bold == nil,
                       headingLikeRun(Array(s.dropFirst()), isLast: !hasNext) { escape = true }
                    if escape { out.append("\\") }
                    out.append(c)
                case "#":
                    if isStart, p == 0, run.bold == nil, headingLikeRun(s, isLast: !hasNext) { out.append("\\") }
                    out.append(c)
                default:
                    out.append(c)
                }
            }
            if let d = run.bold { out.append(contentsOf: d.rawValue.unicodeScalars) }
        }
        return String(out)
    }

    /// Heading-like check on the first run when more runs may follow (a following run starts with a delimiter, never whitespace).
    private static func headingLikeRun(_ s: [Unicode.Scalar], isLast: Bool) -> Bool {
        var h = 0
        while h < s.count, s[h] == "#" { h += 1 }
        guard (1...6).contains(h) else { return false }
        if h == s.count { return isLast }
        return s[h] == " " || s[h] == "\t"
    }
}
