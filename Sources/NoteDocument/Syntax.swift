import Foundation

/// Line-start syntax of the single-line block kinds. Shared by the reader (`NoteDocument.parseLine`)
/// and the writer (which escapes paragraph text that would read back as one of these).
enum BlockSyntax {
    struct Hit { let kind: BlockKind; let prefixLength: Int }

    static func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }

    /// The block kind of a line and the length of its literal prefix, or nil for a paragraph.
    /// Heading: 1 to 6 hashes then end, space or tab. Divider: 3 or more of one of `-` `*` `_`, nothing else
    /// but surrounding blanks (the whole line is its spelling). Quote: `>` then a blank. Bullet: optional
    /// indent, `-` or `*`, a blank. Checklist: a bullet then `[ ]`, `[x]` or `[X]` then a blank.
    /// Numbered: optional indent, 1 to 9 digits, `.` or `)`, a blank.
    static func parse(_ s: [Unicode.Scalar]) -> Hit? {
        let n = s.count
        var h = 0
        while h < n, s[h] == "#" { h += 1 }
        if (1...6).contains(h), h == n || isBlank(s[h]) {
            return Hit(kind: .heading(level: h), prefixLength: skipBlanks(s, h))
        }
        if isDivider(s) { return Hit(kind: .divider, prefixLength: n) }
        if n >= 2, s[0] == ">", isBlank(s[1]) { return Hit(kind: .quote, prefixLength: skipBlanks(s, 1)) }
        let i = skipBlanks(s, 0)
        guard i < n else { return nil }
        if s[i] == "-" || s[i] == "*" {
            guard i + 1 < n, isBlank(s[i + 1]) else { return nil }
            let p = skipBlanks(s, i + 1)
            if p + 3 < n, s[p] == "[", s[p + 1] == " " || s[p + 1] == "x" || s[p + 1] == "X", s[p + 2] == "]", isBlank(s[p + 3]) {
                return Hit(kind: .checklist(checked: s[p + 1] != " "), prefixLength: skipBlanks(s, p + 3))
            }
            return Hit(kind: .bullet, prefixLength: p)
        }
        var d = i
        while d < n, d - i < 9, s[d].properties.numericType == .decimal, s[d].isASCII { d += 1 }
        if d > i, d + 1 < n, s[d] == "." || s[d] == ")", isBlank(s[d + 1]) {
            return Hit(kind: .numbered, prefixLength: skipBlanks(s, d + 1))
        }
        return nil
    }

    static func skipBlanks(_ s: [Unicode.Scalar], _ from: Int) -> Int {
        var p = from
        while p < s.count, isBlank(s[p]) { p += 1 }
        return p
    }

    static func isDivider(_ s: [Unicode.Scalar]) -> Bool {
        var lo = 0, hi = s.count
        while lo < hi, isBlank(s[lo]) { lo += 1 }
        while hi > lo, isBlank(s[hi - 1]) { hi -= 1 }
        guard hi - lo >= 3, s[lo] == "-" || s[lo] == "*" || s[lo] == "_" else { return false }
        return s[lo..<hi].allSatisfy { $0 == s[lo] }
    }

    static func looksLikeBlock(_ s: [Unicode.Scalar]) -> Bool { parse(s) != nil }

    /// Prefix of a new block of `kind`. `indent` and `bullet` carry the spelling of a block it replaces.
    static func defaultPrefix(_ kind: BlockKind, indent: String = "", bullet: Character = "-") -> String {
        switch kind {
        case .paragraph: return ""
        case .heading(let level): return String(repeating: "#", count: min(6, max(1, level))) + " "
        case .bullet: return indent + String(bullet) + " "
        case .numbered: return indent + "1. "
        case .checklist(let checked): return indent + String(bullet) + (checked ? " [x] " : " [ ] ")
        case .quote: return "> "
        case .divider: return "---"
        }
    }
}

extension BlockKind {
    /// Kinds that share a literal prefix grammar; a kind change inside a family keeps the prefix spelling.
    var family: Int {
        switch self {
        case .paragraph: return 0
        case .heading: return 1
        case .bullet: return 2
        case .numbered: return 3
        case .checklist: return 4
        case .quote: return 5
        case .divider: return 6
        }
    }
    var isListItem: Bool { family >= 2 && family <= 4 }
}
