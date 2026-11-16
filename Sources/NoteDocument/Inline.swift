import Foundation

/// Reads the inline marks of one line: bold, italic (`*` or `_`), underline (`<u>`), strikethrough (`~~`),
/// inline code, links, and URL pills (a bare URL, or a link whose label equals its address).
/// Backslash escapes `* _ \ ` ~ < [ ] : ! |`. Inside a link label there are no links and no bare URLs. Everything else is literal text.
enum InlineReader {
    static func isEscapable(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "*", "_", "\\", "`", "~", "<", "[", "]", ":", "!", "|": return true
        default: return false
        }
    }
    static func isBlank(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    static func isWord(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || c.properties.numericType != nil }

    /// Marks that wrap the span being read.
    struct Context {
        var bold: BoldDelimiter?
        var italic: ItalicDelimiter?
        var underline = false
        var strikethrough = false
        var link: String?
        func run(_ text: String, code: Bool = false, pill: PillForm? = nil) -> Run {
            Run(text, bold: bold, italic: italic, underline: underline, strikethrough: strikethrough, code: code, link: link, pill: pill)
        }
    }

    static func read(_ s: [Unicode.Scalar]) -> [Run] {
        Block.normalize(Parser(s: s).parse(0, s.count, Context()))
    }

    /// Length of the bare URL starting at `i` (must be inside `hi`), or nil. Needs `http://` or `https://`, at least
    /// one more scalar, and ends at a blank or one of `< > ` * ~ [ ] \ |`; trailing punctuation is not part of it.
    static func urlLength(_ s: [Unicode.Scalar], at i: Int, upTo hi: Int) -> Int? {
        let scheme = "https://".unicodeScalars.map { $0 }
        var head = 0
        if s[i...].starts(with: scheme) { head = scheme.count }
        else if s[i...].starts(with: "http://".unicodeScalars) { head = 7 }
        else { return nil }
        var end = i + head
        while end < hi, !isBlank(s[end]), !"<>`*~[]\\|".unicodeScalars.contains(s[end]) { end += 1 }
        while end > i + head {
            let last = s[end - 1]
            if ".,;:!?'\"".unicodeScalars.contains(last) { end -= 1; continue }
            if last == ")" {
                let opens = s[i..<end].filter { $0 == "(" }.count, closes = s[i..<end].filter { $0 == ")" }.count
                if closes > opens { end -= 1; continue }
            }
            break
        }
        return end > i + head ? end - i : nil
    }

    struct Parser {
        let s: [Unicode.Scalar]

        func parse(_ lo: Int, _ hi: Int, _ ctx: Context) -> [Run] {
            var runs: [Run] = []
            var plain = String.UnicodeScalarView()
            func flush() { if !plain.isEmpty { runs.append(ctx.run(String(plain))); plain = .init() } }
            var i = lo
            var bangEnd = -1      // index after an unescaped `!`
            while i < hi {
                let c = s[i]
                if c == "!" { bangEnd = i + 1 }
                if c == "\\", i + 1 < hi, isEscapable(s[i + 1]) { plain.append(s[i + 1]); i += 2; continue }
                switch c {
                case "`":
                    if let k = (i + 1..<hi).first(where: { s[$0] == "`" }), k > i + 1 {
                        flush(); runs.append(ctx.run(scalarsToString(s[i + 1..<k]), code: true)); i = k + 1; continue
                    }
                case "[":
                    // `![alt](src)` is an image, which stays literal text.
                    if ctx.link == nil, bangEnd != i, let (next, linkRuns) = link(i, hi, ctx) { flush(); runs += linkRuns; i = next; continue }
                case "h":
                    if ctx.link == nil, i == 0 || !isWord(s[i - 1]), let len = urlLength(s, at: i, upTo: hi) {
                        flush(); runs.append(ctx.run(scalarsToString(s[i..<i + len]), pill: .bare)); i += len; continue
                    }
                case "<":
                    if i + 3 < hi, s[i + 1] == "u", s[i + 2] == ">", let k = find("</u>", from: i + 3, hi),
                       k > i + 3 {
                        flush(); var inner = ctx; inner.underline = true
                        runs += parse(i + 3, k, inner); i = k + 4; continue
                    }
                case "~":
                    if i + 2 < hi, s[i + 1] == "~", let k = strikeClose(from: i + 2, hi),
                       !s[i + 2..<k].allSatisfy(isBlank) {
                        flush(); var inner = ctx; inner.strikethrough = true
                        runs += parse(i + 2, k, inner); i = k + 2; continue
                    }
                case "*", "_":
                    if let (next, inner, apply) = emphasis(i, hi, c) {
                        flush(); var innerCtx = ctx; apply(&innerCtx)
                        runs += parse(inner.lowerBound, inner.upperBound, innerCtx); i = next; continue
                    }
                default: break
                }
                plain.append(c); i += 1
            }
            flush()
            return runs
        }

        /// Index after the code span that opens at `k` (a backtick with another one after at least one scalar), or nil.
        /// Span closers skip code spans, so that code content never closes an outer mark.
        func codeEnd(_ k: Int, _ hi: Int) -> Int? {
            guard s[k] == "`", k + 2 < hi, let j = (k + 1..<hi).first(where: { s[$0] == "`" }), j > k + 1 else { return nil }
            return j + 1
        }

        /// First index of `needle` at or after `from` that is not escaped.
        func find(_ needle: String, from: Int, _ hi: Int) -> Int? {
            let n = Array(needle.unicodeScalars)
            var k = from
            while k + n.count <= hi {
                if s[k] == "\\", k + 1 < hi, isEscapable(s[k + 1]) { k += 2; continue }
                if let e = codeEnd(k, hi) { k = e; continue }
                if s[k..<k + n.count].elementsEqual(n) { return k }
                k += 1
            }
            return nil
        }

        func strikeClose(from j: Int, _ hi: Int) -> Int? {
            var k = j
            while k < hi {
                if s[k] == "\\", k + 1 < hi, isEscapable(s[k + 1]) { k += 2; continue }
                if let e = codeEnd(k, hi) { k = e; continue }
                if s[k] == "~" { return (k + 1 < hi && s[k + 1] == "~" && k > j) ? k : nil }
                k += 1
            }
            return nil
        }

        /// `[label](url)` at `i`. A label equal to its address makes a pill; otherwise the label is read with the link mark.
        func link(_ i: Int, _ hi: Int, _ ctx: Context) -> (Int, [Run])? {
            var k = i + 1
            while k < hi {
                if s[k] == "\\", k + 1 < hi, isEscapable(s[k + 1]) { k += 2; continue }
                if let e = codeEnd(k, hi) { k = e; continue }
                if s[k] == "]" { break }
                k += 1
            }
            guard k < hi, k > i + 1, k + 1 < hi, s[k + 1] == "(",
                  let m = (k + 2..<hi).first(where: { s[$0] == ")" }) else { return nil }
            let label = s[i + 1..<k], url = s[k + 2..<m]
            if label.elementsEqual(url) { return (m + 1, [ctx.run(scalarsToString(url), pill: .link)]) }
            var inner = ctx; inner.link = scalarsToString(url)
            return (m + 1, parse(i + 1, k, inner))
        }

        /// Bold (a run of 2 or more delimiters) or italic (a single one) at `i`. Returns the index after the closing
        /// delimiter, the content range, and the mark to apply to the content.
        func emphasis(_ i: Int, _ hi: Int, _ c: Unicode.Scalar) -> (Int, Range<Int>, (inout Context) -> Void)? {
            var r = 1
            while i + r < hi, s[i + r] == c { r += 1 }
            if r >= 2 {
                let j = i + 2
                guard j < hi, !isBlank(s[j]), let k = boldClose(c, from: j, hi) else { return nil }
                let delimiter: BoldDelimiter = c == "*" ? .asterisks : .underscores
                return (k + 2, j..<k, { $0.bold = delimiter })
            }
            let j = i + 1
            guard j < hi, !isBlank(s[j]) else { return nil }
            if c == "_", i > 0, isWord(s[i - 1]) || s[i - 1] == "_" { return nil }
            guard let k = italicClose(c, from: j, hi) else { return nil }
            let delimiter: ItalicDelimiter = c == "*" ? .asterisk : .underscore
            return (k + 1, j..<k, { $0.italic = delimiter })
        }

        func runLength(_ k: Int, _ hi: Int, _ c: Unicode.Scalar) -> Int {
            var m = 1
            while k + m < hi, s[k + m] == c { m += 1 }
            return m
        }

        /// Start index of the closing `cc`. A run of three or more closes the bold at its first two delimiters,
        /// unless an italic opened inside the content, which then takes the first one.
        func boldClose(_ c: Unicode.Scalar, from j: Int, _ hi: Int) -> Int? {
            var italicOpen = false
            var k = j
            while k < hi {
                if s[k] == "\\", k + 1 < hi, isEscapable(s[k + 1]) { k += 2; continue }
                if let e = codeEnd(k, hi) { k = e; continue }
                guard s[k] == c else { k += 1; continue }
                let m = runLength(k, hi, c)
                let prevOK = k > j && !isBlank(s[k - 1])
                if m == 1 {
                    if italicOpen { italicOpen = false } else if k + 1 < hi, !isBlank(s[k + 1]) { italicOpen = true }
                } else if m == 2 {
                    if prevOK { return k }
                } else if prevOK {
                    return italicOpen ? k + 1 : k
                }
                k += m
            }
            return nil
        }

        /// Index of the closing single delimiter. A run of three or more after a bold opened inside the content
        /// closes that bold first.
        func italicClose(_ c: Unicode.Scalar, from j: Int, _ hi: Int) -> Int? {
            var boldOpen = false
            var k = j
            while k < hi {
                if s[k] == "\\", k + 1 < hi, isEscapable(s[k + 1]) { k += 2; continue }
                if let e = codeEnd(k, hi) { k = e; continue }
                guard s[k] == c else { k += 1; continue }
                let m = runLength(k, hi, c)
                let prevOK = k > j && !isBlank(s[k - 1])
                if m == 2 {
                    boldOpen.toggle()
                } else if prevOK {
                    let closeAt = (m >= 3 && boldOpen) ? k + 2 : k
                    let next = closeAt + 1 < hi ? s[closeAt + 1] : nil
                    if c == "*" || next == nil || !(isWord(next!) || next! == "_") { return closeAt }
                }
                k += m
            }
            return nil
        }
    }
}

enum InlineWriter {
    /// Set by `write` for the duration of one call: plain `|` is written escaped.
    nonisolated(unsafe) private static var pipesEscaped = false
    /// Generates inline text such that `InlineReader.read` gives the same runs back (fidelity rule 3), as far as the
    /// forms allow; `NoteDocument.settle` repairs the model where they do not.
    /// Marks nest in a fixed order: link, underline, strikethrough, bold, italic, then the leaf (code, pill, text).
    static func write(_ runs: [Run], kind: BlockKind, escapePipes: Bool = false) -> String {
        pipesEscaped = escapePipes
        defer { pipesEscaped = false }
        var w = emit(runs, 0..<runs.count, layer: 0)
        let s = Array(w.unicodeScalars)
        switch kind {
        case .paragraph:
            if let first = s.first, first == "\\", s.count > 1, !InlineReader.isEscapable(s[1]),
               BlockSyntax.looksLikeBlock(Array(s.dropFirst())) {
                w = "\\" + w
            } else if BlockSyntax.looksLikeBlock(s) {
                w = "\\" + w
            }
        case .bullet:
            // `- [ ] x` would read as a checklist.
            if s.count >= 4, s[0] == "[", s[1] == " " || s[1] == "x" || s[1] == "X", s[2] == "]", BlockSyntax.isBlank(s[3]) {
                w = "\\" + w
            }
        default: break
        }
        return w
    }

    private static func layerKey(_ r: Run, _ layer: Int) -> String? {
        switch layer {
        case 0: return r.link.map { "l" + $0 }
        case 1: return r.underline ? "u" : nil
        case 2: return r.strikethrough ? "s" : nil
        case 3: return r.bold?.rawValue
        default: return r.italic?.rawValue
        }
    }

    private static func emit(_ runs: [Run], _ range: Range<Int>, layer: Int) -> String {
        if layer == 5 { return range.map { leaf(runs, $0) }.joined() }
        var out = ""
        var i = range.lowerBound
        while i < range.upperBound {
            let key = layerKey(runs[i], layer)
            var j = i + 1
            while j < range.upperBound, layerKey(runs[j], layer) == key { j += 1 }
            let inner = emit(runs, i..<j, layer: layer + 1)
            if key == nil { out += inner } else {
                switch layer {
                case 0: out += "[" + inner + "](" + (runs[i].link ?? "") + ")"
                case 1: out += "<u>" + inner + "</u>"
                case 2: out += "~~" + inner + "~~"
                case 3: let d = runs[i].bold!.rawValue; out += d + inner + d
                default: let d = runs[i].italic!.rawValue; out += d + inner + d
                }
            }
            i = j
        }
        return out
    }

    private static func leaf(_ runs: [Run], _ idx: Int) -> String {
        let run = runs[idx]
        if let form = run.pill { return form == .bare ? run.text : "[" + run.text + "](" + run.text + ")" }
        if run.code { return "`" + run.text + "`" }
        return escaped(runs, idx)
    }

    private static func escaped(_ runs: [Run], _ idx: Int) -> String {
        let run = runs[idx]
        let s = Array(run.text.unicodeScalars)
        let hasPrev = idx > 0, hasNext = idx + 1 < runs.count
        let marked = run.bold != nil || run.italic != nil || run.underline || run.strikethrough || run.link != nil
        let linkLater = runs[(idx + 1)...].contains { $0.link != nil || $0.pill != nil }
        let textAfter: (Int) -> String = { p in
            scalarsToString(s[(p + 1)...]) + runs[(idx + 1)...].map(\.text).joined()
        }
        // Colons that would start a bare URL.
        var urlColons = Set<Int>()
        for p in s.indices where run.link == nil && s[p] == "h" && (p == 0 || !InlineReader.isWord(s[p - 1])) {
            if InlineReader.urlLength(s, at: p, upTo: s.count) != nil { urlColons.insert(p + (s[(p + 4)...].first == "s" ? 5 : 4)) }
        }
        var out = String.UnicodeScalarView()
        for (p, c) in s.enumerated() {
            let prev: Unicode.Scalar? = p > 0 ? s[p - 1] : nil
            let next: Unicode.Scalar? = p + 1 < s.count ? s[p + 1] : nil
            var escape = false
            switch c {
            case "*": escape = true
            case "_":
                escape = run.bold == .underscores || run.italic == .underscore || underscoreAtRisk(prev, next)
            case "\\":
                if let nx = next { escape = InlineReader.isEscapable(nx) } else { escape = hasNext || marked }
            case "`": escape = true
            case "|": escape = pipesEscaped
            case "~":
                escape = run.strikethrough || prev == "~" || next == "~" || ((prev == nil || next == nil) && (hasPrev || hasNext || marked))
            case "<":
                let rest = scalarsToString(s[(p + 1)...])
                escape = rest.hasPrefix("u>") || rest.hasPrefix("/u>") || (next == nil && hasNext)
            case "[":
                escape = run.link != nil || linkLater || textAfter(p).contains("](")
            case "]": escape = run.link != nil
            case ":": escape = urlColons.contains(p)
            case "!": escape = next == nil && startsLink(runs, idx + 1)
            default: break
            }
            if escape { out.append("\\") }
            out.append(c)
        }
        return String(out)
    }

    /// True when the text written for `runs[idx]` begins with `[`.
    private static func startsLink(_ runs: [Run], _ idx: Int) -> Bool {
        guard idx < runs.count else { return false }
        let r = runs[idx]
        return r.pill == .link || (r.link != nil && !(idx > 0 && runs[idx - 1].link == r.link))
    }

    /// A lone `_` is left alone only where it can neither open nor close an italic.
    private static func underscoreAtRisk(_ prev: Unicode.Scalar?, _ next: Unicode.Scalar?) -> Bool {
        guard let p = prev, let n = next, p != "_", n != "_" else { return true }
        let canOpen = !(InlineReader.isWord(p)) && !InlineReader.isBlank(n)
        let canClose = !InlineReader.isBlank(p) && !(InlineReader.isWord(n))
        return canOpen || canClose
    }
}
