import Foundation

/// What a typed-markdown trigger turns a block into. Offsets count UTF-16 units of the block's visible text (a pill
/// counts as its address).
public struct TypedConversion: Equatable, Sendable {
    public var kind: BlockKind
    public var runs: [Run]
    /// Where the caret goes.
    public var caret: Int
    /// The number the user typed in front of a numbered item (`7. `), kept as the item's number.
    public var number: Int?
    /// A divider always gets an empty plain line below it, where the caret goes.
    public var lineBelow: Bool
}

/// The rule table of typed markdown. The caller reports the character the user just typed and the caret right after
/// it; the rules look only at the block's text, so they hold for any editor.
///
/// - Block triggers fire when the prefix is completed at a line start of a plain line: `# ` to `###### `, `- `, `* `,
///   `1. ` (any number), `> `, `- [ ] `, `- [x] `, `---` alone on the line, a code fence (three backticks alone on the line).
///   A bullet item that holds only `[ ] ` or `[x] ` becomes a checklist item (the second half of typing `- [ ] `).
/// - Inline triggers fire when the closing delimiter is typed: `**x**`, `*x*`, `_x_`, `~~x~~`, `` `x` ``, `<u>x</u>`.
/// - A bare `http(s)` URL becomes a pill when a blank or Enter completes it.
/// Nothing fires in a code block, a table, on a divider, or on text that is inline code or already a pill.
public enum TypedMarkdown {
    public static func convert(kind: BlockKind, runs: [Run], caret: Int, typed: Character) -> TypedConversion? {
        guard holdsMarks(kind), caret > 0 else { return nil }
        let line = Line(runs)
        guard caret <= line.units.last.map({ $0.end }) ?? 0 else { return nil }
        switch typed {
        case " ":
            return block(kind, line, caret) ?? completeURL(kind, line, caret, tail: caret - 1)
        case "\t":
            return completeURL(kind, line, caret, tail: caret - 1)
        case "\n":
            return completeURL(kind, line, caret, tail: caret)
        case "-", "`":
            if let c = block(kind, line, caret, typed: typed) { return c }
            return typed == "`" ? inline(kind, line, caret, typed) : nil
        case "*", "_", "~", ">":
            return inline(kind, line, caret, typed)
        default:
            return nil
        }
    }

    /// `runs` with every bare URL that overlaps `range` made a pill (paste), or nil when there is none.
    public static func pills(kind: BlockKind, runs: [Run], overlapping range: Range<Int>) -> [Run]? {
        guard holdsMarks(kind) else { return nil }
        let line = Line(runs)
        var found: [Range<Int>] = []
        var k = 0
        while k < line.units.count {
            guard let len = line.urlLength(at: k) else { k += 1; continue }
            let first = line.units[k], last = line.units[k + len - 1]
            if first.start < range.upperBound, last.end > range.lowerBound { found.append(first.start..<last.end) }
            k += len
        }
        guard !found.isEmpty else { return nil }
        var out = runs
        for r in found.reversed() {
            let lo = RunOps.boundary(&out, r.lowerBound, snapUp: false), hi = RunOps.boundary(&out, r.upperBound, snapUp: true)
            guard hi == lo + 1 else { continue }   // one run only (the marks of the URL are those of its run)
            out[lo].pill = .bare
        }
        return Block.normalize(out)
    }

    // MARK: text of the line

    static func holdsMarks(_ kind: BlockKind) -> Bool {
        switch kind {
        case .fence, .table, .divider: return false
        default: return true
        }
    }

    /// The scalars of a line with where they sit. A scalar of inline code or of a pill is `blocked`: no trigger reaches it.
    /// A link label is blocked for URLs (the reader reads none there) but not for marks.
    struct Unit {
        let scalar: Unicode.Scalar
        let start: Int, end: Int
        let run: Int
        let blocked: Bool
        let inLink: Bool
    }

    struct Line {
        let runs: [Run]
        var units: [Unit] = []
        init(_ runs: [Run]) {
            self.runs = runs
            var at = 0
            for (i, r) in runs.enumerated() {
                if r.pill != nil {
                    let len = r.text.utf16.count
                    units.append(Unit(scalar: "\u{FFFC}", start: at, end: at + len, run: i, blocked: true, inLink: false))
                    at += len
                    continue
                }
                for c in r.text.unicodeScalars {
                    let len = String(c).utf16.count
                    units.append(Unit(scalar: c, start: at, end: at + len, run: i, blocked: r.code, inLink: r.link != nil))
                    at += len
                }
            }
        }
        /// Number of units that end at or before `offset`.
        func count(upTo offset: Int) -> Int { units.prefix(while: { $0.end <= offset }).count }
        func scalars(_ range: Range<Int>) -> [Unicode.Scalar] { units[range].map(\.scalar) }

        /// Length in units of the bare URL that starts at unit `k`, by the reader's rule, or nil. All its scalars sit in one
        /// plain run (no code, no link label, no pill).
        func urlLength(at k: Int) -> Int? {
            guard units[k].scalar == "h", !units[k].blocked, !units[k].inLink else { return nil }
            if k > 0, InlineReader.isWord(units[k - 1].scalar) { return nil }
            let run = units[k].run
            var end = k
            while end < units.count, units[end].run == run { end += 1 }
            let s = units[k..<end].map(\.scalar)
            guard let len = InlineReader.urlLength(s, at: 0, upTo: s.count) else { return nil }
            return len
        }
    }

    // MARK: rebuilding runs

    /// `runs` with the utf16 ranges `cut` removed and `body` applied to the runs of `mark`.
    private static func edit(_ runs: [Run], removing cut: [Range<Int>], marking mark: Range<Int>?, _ apply: (inout Run) -> Void) -> [Run] {
        var out = runs
        if let m = mark {
            let (lo, hi) = RunOps.span(&out, m)
            for k in lo..<hi { apply(&out[k]) }
        }
        for r in cut.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let (lo, hi) = RunOps.span(&out, r)
            out.removeSubrange(lo..<hi)
        }
        return Block.normalize(out)
    }

    // MARK: block triggers

    private static func block(_ kind: BlockKind, _ line: Line, _ caret: Int, typed: Character = " ") -> TypedConversion? {
        let n = line.count(upTo: caret)
        guard n > 0, line.units[0..<n].allSatisfy({ !$0.blocked && !$0.inLink }) else { return nil }
        let before = String(String.UnicodeScalarView(line.scalars(0..<n)))
        func make(_ kind: BlockKind, number: Int? = nil) -> TypedConversion {
            // The prefix is cut off; whatever follows the caret stays as the item's text.
            let rest = edit(line.runs, removing: [0..<caret], marking: nil) { _ in }
            return TypedConversion(kind: kind, runs: rest, caret: 0, number: number, lineBelow: false)
        }
        let whole = line.units.last?.end == caret   // nothing after the caret
        if typed == "-" {
            guard kind == .paragraph, before == "---", whole else { return nil }
            return TypedConversion(kind: .divider, runs: [], caret: 0, number: nil, lineBelow: true)
        }
        if typed == "`" {
            guard kind == .paragraph, before == "```", whole else { return nil }
            return TypedConversion(kind: .fence, runs: [], caret: 0, number: nil, lineBelow: false)
        }
        // typed == " "
        if kind == .bullet {
            switch before {
            case "[ ] ": return make(.checklist(checked: false))
            case "[x] ", "[X] ": return make(.checklist(checked: true))
            default: return nil
            }
        }
        guard kind == .paragraph else { return nil }
        switch before {
        case "- ", "* ": return make(.bullet)
        case "> ": return make(.quote)
        case "- [ ] ": return make(.checklist(checked: false))
        case "- [x] ", "- [X] ": return make(.checklist(checked: true))
        default: break
        }
        let s = Array(before.unicodeScalars)
        let hashes = s.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), s.count == hashes + 1 { return make(.heading(level: hashes)) }
        let digits = s.prefix(while: { $0.isASCII && $0.properties.numericType == .decimal }).count
        if (1...9).contains(digits), s.count == digits + 2, s[digits] == "." {
            return make(.numbered, number: Int(scalarsToString(s[0..<digits])))
        }
        return nil
    }

    // MARK: inline triggers

    private static func inline(_ kind: BlockKind, _ line: Line, _ caret: Int, _ typed: Character) -> TypedConversion? {
        let u = line.units
        let end = line.count(upTo: caret)   // units before the caret
        guard end >= 3, let c = typed.unicodeScalars.first else { return nil }
        let next: Unicode.Scalar? = end < u.count ? u[end].scalar : nil
        let s = u[0..<end].map(\.scalar)
        func isBlank(_ x: Unicode.Scalar) -> Bool { InlineReader.isBlank(x) }
        /// Range in units [open, close) of delimiters and the content between; `apply` sets the mark.
        var delimiter: (open: Range<Int>, close: Range<Int>)?
        var apply: (inout Run) -> Void = { _ in }
        let k = end - 1
        switch c {
        case ">":
            guard end >= 8, Array(s[(end - 4)...]) == Array("</u>".unicodeScalars) else { return nil }
            let open = Array("<u>".unicodeScalars)
            guard let j = (0...(end - 8)).last(where: { Array(s[$0..<$0 + 3]) == open }), j + 3 < end - 4 else { return nil }
            delimiter = (j..<j + 3, end - 4..<end)
            apply = { $0 = $0.applying(.underline, setting: true, bold: .asterisks, italic: .asterisk) }
        case "~":
            guard s[k - 1] == "~", k - 2 < 0 || s[k - 2] != "~", next != "~" else { return nil }
            var j = k - 3
            while j >= 0, !(s[j] == "~" && s[j + 1] == "~") { j -= 1 }
            guard j >= 0, j + 2 < k - 1, j == 0 || s[j - 1] != "~", s[j + 2] != "~", !s[(j + 2)..<(k - 1)].contains("~"),
                  !s[(j + 2)..<(k - 1)].allSatisfy(isBlank) else { return nil }
            delimiter = (j..<j + 2, k - 1..<k + 1)
            apply = { $0 = $0.applying(.strikethrough, setting: true, bold: .asterisks, italic: .asterisk) }
        case "`":
            guard let j = (0..<k).last(where: { s[$0] == "`" }), j + 1 < k else { return nil }
            delimiter = (j..<j + 1, k..<k + 1)
            apply = { $0 = $0.applying(.code, setting: true, bold: .asterisks, italic: .asterisk) }
        case "*", "_":
            let double = k >= 1 && s[k - 1] == c
            if double {
                // Bold needs a closing pair of exactly two delimiters, and `*` only (`__x__` is left alone).
                guard c == "*", k < 2 || s[k - 2] != c, next != c, k - 2 >= 0, !isBlank(s[k - 2]) else { return nil }
                var j = k - 3
                while j >= 0, !(s[j] == c && s[j + 1] == c) { j -= 1 }
                guard j >= 0, j + 2 < k - 1, j == 0 || s[j - 1] != c, s[j + 2] != c, !isBlank(s[j + 2]) else { return nil }
                delimiter = (j..<j + 2, k - 1..<k + 1)
                apply = { $0 = $0.applying(.bold, setting: true, bold: .asterisks, italic: .asterisk) }
            } else {
                guard next != c, k >= 2, !isBlank(s[k - 1]), let j = (0..<k).last(where: { s[$0] == c }), j + 1 < k,
                      j == 0 || s[j - 1] != c, !isBlank(s[j + 1]) else { return nil }
                if c == "_" {
                    if j > 0, InlineReader.isWord(s[j - 1]) { return nil }
                    if let n = next, InlineReader.isWord(n) { return nil }
                }
                let italic: ItalicDelimiter = c == "*" ? .asterisk : .underscore
                delimiter = (j..<j + 1, k..<k + 1)
                apply = { $0 = $0.applying(.italic, setting: true, bold: .asterisks, italic: italic) }
            }
        default: return nil
        }
        guard let d = delimiter else { return nil }
        // Every delimiter and every character between them must be text the rule may touch.
        guard u[d.open.lowerBound..<d.close.upperBound].allSatisfy({ !$0.blocked }) else { return nil }
        let a = u[d.open.lowerBound].start, ao = u[d.open.upperBound - 1].end
        let b = u[d.close.lowerBound].start, bo = u[d.close.upperBound - 1].end
        let runs = edit(line.runs, removing: [a..<ao, b..<bo], marking: ao..<b, apply)
        // The caret sits after the content (the closing delimiter was just typed), with both delimiters cut out.
        return TypedConversion(kind: kind, runs: runs, caret: caret - (ao - a) - (bo - b), number: nil, lineBelow: false)
    }

    // MARK: bare URL

    private static func completeURL(_ kind: BlockKind, _ line: Line, _ caret: Int, tail: Int) -> TypedConversion? {
        let t = line.count(upTo: tail)
        guard t > 0 else { return nil }
        var start = t
        while start > 0, !InlineReader.isBlank(line.units[start - 1].scalar) { start -= 1 }
        guard start < t else { return nil }
        var k = start
        while k < t {
            if let len = line.urlLength(at: k) {
                let first = line.units[k], last = line.units[k + len - 1]
                var out = line.runs
                let lo = RunOps.boundary(&out, first.start, snapUp: false), hi = RunOps.boundary(&out, last.end, snapUp: true)
                guard hi == lo + 1 else { return nil }
                out[lo].pill = .bare
                return TypedConversion(kind: kind, runs: Block.normalize(out), caret: caret, number: nil, lineBelow: false)
            }
            k += 1
        }
        return nil
    }
}

extension NoteDocument {
    /// Applies the trigger that the just typed character `typed` completes in block `i` (caret after it), if any.
    @discardableResult
    public mutating func applyTyped(block i: Int, caret: Int, typed: Character) -> TypedConversion? {
        precondition(blocks.indices.contains(i), "block index out of range")
        let b = blocks[i]
        guard let c = TypedMarkdown.convert(kind: b.kind, runs: b.runs, caret: caret, typed: typed) else { return nil }
        apply(.replace(at: i, kind: c.kind, runs: c.runs))
        if let n = c.number { apply(.setNumber(block: i, number: n)) }
        if c.lineBelow { apply(.insert(at: i + 1, kind: .paragraph, runs: [])) }
        return c
    }
}
