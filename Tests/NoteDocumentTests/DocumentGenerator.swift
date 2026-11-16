import Foundation
import NoteDocument

/// Random markdown and random edits. Extend by adding a case to `LineShape` and handling it in
/// `line(_:)`; later tickets add one shape per new block kind / mark. A shape may span several lines
/// (code block, table): they are joined with `eol`, which `markdown()` sets per document.
struct DocumentGenerator {
    var rng: SeededRNG
    var eol = "\n"
    init(seed: UInt64) { rng = SeededRNG(seed: seed) }

    enum LineShape: CaseIterable {
        case blank, paragraph, heading, bullet, numbered, checklist, quote, divider, literalOther, nasty, fence, table, setext
    }

    mutating func int(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }

    static let words = ["alpha", "beta", "gamma", "x", "snake_case", "a*b", "_", "*", "\\", "#", "##", "caf\u{e9}", "e\u{301}",
                        "\u{1F600}", "\u{4E2D}", "- item", "> q", "1.", "[l](u)", "https://a.b/c_d", "__", "**", "\\*", "\\#", "\t", " ",
                        "~", "~~", "`", "<u>", "</u>", "[", "]", "](", "http://x.y", "https://", "[ ] t", "---", "\\:", "!",
                        "|", "\\|", "||", "|---|", "\n", "\u{2028}", "```", "~~~", "# c",
                        "- not a list", "# not a heading", "> not a quote", "1. not numbered", "![img](u)", "<div>", "[a][b]", "[b]: u", "[^1]", "[^1]: n", "==="]

    mutating func plainText() -> String {
        (0..<(1 + int(4))).map { _ in pick(Self.words) }.joined(separator: pick(["", " ", "  "]))
    }

    /// One inline piece in file spelling: plain text or one of the marks, sometimes nested.
    mutating func piece(depth: Int = 0) -> String {
        switch int(depth > 0 ? 6 : 14) {
        case 0: return "**" + plainText() + "**"
        case 1: return "__" + plainText() + "__"
        case 2: let d = pick(["*", "_"]); return d + plainText() + d
        case 3: return "<u>" + plainText() + "</u>"
        case 4: return "~~" + plainText() + "~~"
        case 5: return "`" + plainText() + "`"
        case 6: return "[" + plainText() + "](" + pick(["http://x.y/z", "u", "", "a_b"]) + ")"
        case 7: return pick(["https://a.b/c_d", "http://x.y", "https://e.f/g?h=1", "(https://x.y/z)"]) + pick(["", "", ".", ","])
        case 8: let u = pick(["https://a.b", "http://x.y/z"]); return "[" + u + "](" + u + ")"
        case 9, 10: // nested
            let outer = pick(["**", "__", "*", "_", "~~"])
            let close = outer
            return outer + piece(depth: 1) + plainText() + piece(depth: 1) + close
        case 11: return "<u>" + piece(depth: 1) + "</u>"
        case 12: return "[" + piece(depth: 1) + "](u)"
        default: return plainText() + pick(["", " "])
        }
    }

    mutating func inline() -> String {
        var s = ""
        for _ in 0..<(1 + int(4)) { s += piece() + pick(["", "", " "]) }
        return s
    }

    /// A line of markdown source (no terminator).
    mutating func line(_ shape: LineShape) -> String {
        switch shape {
        case .blank: return pick(["", "", "  ", "\t"])
        case .paragraph: return inline()
        case .heading:
            return String(repeating: "#", count: 1 + int(6)) + pick([" ", "  ", "\t", " "]) + inline()
        case .bullet:
            return pick(["", "", "  ", "\t"]) + pick(["-", "*"]) + pick([" ", " ", "  ", "\t"]) + inline()
        case .numbered:
            return pick(["", "", " "]) + String(1 + int(120)) + pick([".", ")"]) + pick([" ", " ", "  "]) + inline()
        case .checklist:
            return pick(["", "", "  "]) + pick(["-", "*"]) + " " + pick(["[ ]", "[x]", "[X]"]) + pick([" ", " ", "  "]) + inline()
        case .quote:
            return ">" + pick([" ", " ", "\t"]) + inline()
        case .divider:
            return pick(["", "", " "]) + pick(["---", "***", "___", "-----", "*****", "____"]) + pick(["", "", " "])
        case .fence:
            let ch = pick(["`", "~"]), n = 3 + int(2)
            let open = String(repeating: ch, count: n) + pick(["", "", "swift", " py ", "c++", "js {x}"])
            let close = String(repeating: ch, count: n + int(2)) + pick(["", "", " ", "\t"])
            let content = (0..<int(5)).map { _ in
                pick(["# comment", "**x**", "- item", "| a | b |", "", "  indent", "__y__ `z`", "> q", "---", "[l](u)", "<u>x</u>", "\\", "\\#", "~~~", "``", plainText()])
            }
            return ([open] + content + [close]).joined(separator: eol)
        case .table:
            // The shapes the old editor drew as a grid: outer pipes optional, indent, ragged rows, `:` in the delimiter row.
            let indent = pick(["", "", "", "  ", "\t"])
            let outer = pick([true, true, false])
            func row(_ cells: Int) -> String {
                let body = (0..<cells).map { _ in pick([" ", "", "  "]) + (int(6) == 0 ? "" : inline().replacingOccurrences(of: "|", with: "\\|")) + pick([" ", "", "  "]) }
                    .joined(separator: "|")
                return indent + (outer ? "|" + body + "|" : (cells == 1 ? body + "|" : body))
            }
            let n = 1 + int(3)
            let cells = (0..<n).map { _ in pick([" --- ", "---", ":--", "--:", " :-: ", "----", "-"]) }.joined(separator: "|")
            let sep = indent + (outer ? "|" + cells + "|" : (n == 1 ? cells + "|" : cells))
            return ([row(n), sep] + (0..<int(4)).map { _ in row(1 + int(4)) }).joined(separator: eol)
        case .literalOther:
            return pick(["```", "| a | b |", "![i](x)", "    indented", "  # indented", "+ plus", "-x", "1.x", ">x", "- [ ]x", "- []", "* * *", "- - -", "--", "<div>", "[^1]: n", "![img](u)", "[a][b]", "[b]: u", "===", "<div>x</div>"])
        case .setext:
            // Text over `===` / `---`: setext headings are not supported, both lines stay literal.
            return ([plainText(), pick(["===", "======", "---", "-----", "==="])]).joined(separator: eol)
        case .nasty:
            return pick(["** **", "**", "****", "___", "\\#", "\\\\#", "# ", "#", "#######", "**a **b** c**", "a\\", "**a\\**", "***a**", "***a*", "**a***b*", "*a***b**", "*a **b***", "_a_b_", "- ", "> ", "1. ", "- [ ] ", "\\- x", "\\\\- x", "~~a~b~~", "[a](b", "[a]()", "<u>a</u", "`a``b`"])
        }
    }

    /// A whole markdown file with random line endings (all LF, all CRLF, or mixed) and optional final newline.
    mutating func markdown() -> String {
        let count = int(12)
        let style = int(3)   // 0 LF, 1 CRLF, 2 mixed
        eol = style == 1 ? "\r\n" : "\n"
        let finalNewline = int(4) != 0
        var out = ""
        for i in 0..<count {
            out += line(pick(LineShape.allCases))
            let isLast = i == count - 1
            if isLast && !finalNewline { break }
            out += (style == 1 || (style == 2 && int(2) == 0)) ? "\r\n" : "\n"
        }
        return out
    }

    mutating func run() -> Run {
        var r = Run(plainText())
        if int(3) == 0 { r.bold = pick([BoldDelimiter.asterisks, .underscores]) }
        if int(4) == 0 { r.italic = pick([ItalicDelimiter.asterisk, .underscore]) }
        if int(6) == 0 { r.underline = true }
        if int(6) == 0 { r.strikethrough = true }
        if int(8) == 0 { r.link = pick(["http://x.y", "u", ""]) }
        if int(10) == 0 { r.code = true }
        if int(8) == 0 { r.text = pick(["https://a.b/c", "http://x.y"]); r.pill = pick([PillForm.bare, .link]) }
        return r
    }

    mutating func runs() -> [Run] { (0..<int(5)).map { _ in run() } }

    mutating func kind() -> BlockKind {
        switch int(12) {
        case 10: return .fence
        case 11: return .table
        case 0: return .heading(level: 1 + int(6))
        case 1: return .bullet
        case 2: return .numbered
        case 3: return .checklist(checked: int(2) == 0)
        case 4: return .quote
        case 5: return .divider
        default: return .paragraph
        }
    }

    mutating func mark() -> Mark {
        pick([Mark.bold, .italic, .underline, .strikethrough, .code, .link("http://l.k")])
    }

    /// A random edit valid for `doc`.
    mutating func edit(in doc: NoteDocument) -> Edit {
        let count = doc.blocks.count
        if count == 0 { return .insert(at: 0, kind: kind(), runs: runs()) }
        let i = int(count)
        let length = doc.blocks[i].text.utf16.count
        func offset(_ g: inout DocumentGenerator) -> Int { g.int(length + 2) }
        func range(_ g: inout DocumentGenerator) -> Range<Int> {
            let a = g.int(length + 2), b = g.int(length + 2); return min(a, b)..<max(a, b)
        }
        switch int(16) {
        case 0: return .insert(at: int(count + 1), kind: kind(), runs: runs())
        case 1: return .remove(at: i)
        case 2, 3: return .replace(at: i, kind: kind(), runs: runs())
        case 4, 5: return .insertText(block: i, offset: offset(&self), text: plainText())
        case 6: return .deleteText(block: i, range: range(&self))
        case 7, 8: return .setMark(block: i, range: range(&self), mark: mark())
        case 9: return .clearMark(block: i, range: range(&self), mark: mark())
        case 10: return .setKind(block: i, kind: kind())
        case 11: return .toggleCheckbox(block: i)
        case 12, 13: return .split(block: i, offset: offset(&self))
        default:
            return i + 1 < count ? .join(block: i) : .toggleCheckbox(block: i)
        }
    }
}
