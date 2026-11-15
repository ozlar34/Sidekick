import Foundation
import NoteDocument

/// Random markdown and random edits. Extend by adding a case to `LineShape` and handling it in
/// `line(_:)`; later tickets add one shape per new block kind / mark.
struct DocumentGenerator {
    var rng: SeededRNG
    init(seed: UInt64) { rng = SeededRNG(seed: seed) }

    enum LineShape: CaseIterable {
        case blank, paragraph, heading, literalOther, nasty
    }

    mutating func int(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }

    static let words = ["alpha", "beta", "gamma", "x", "snake_case", "a*b", "_", "*", "\\", "#", "##", "caf\u{e9}", "e\u{301}",
                        "\u{1F600}", "\u{4E2D}", "- item", "> q", "1.", "[l](u)", "https://a.b/c_d", "__", "**", "\\*", "\\#", "\t", " "]

    mutating func plainText() -> String {
        (0..<(1 + int(4))).map { _ in pick(Self.words) }.joined(separator: pick(["", " ", "  "]))
    }

    /// A line of markdown source (no terminator).
    mutating func line(_ shape: LineShape) -> String {
        switch shape {
        case .blank: return pick(["", "", "  ", "\t"])
        case .paragraph:
            var s = ""
            for _ in 0..<(1 + int(4)) {
                switch int(4) {
                case 0: s += "**" + plainText() + "**"
                case 1: s += "__" + plainText() + "__"
                default: s += plainText() + pick(["", " "])
                }
            }
            return s
        case .heading:
            return String(repeating: "#", count: 1 + int(6)) + pick([" ", "  ", "\t", " "]) + line(.paragraph)
        case .literalOther:
            return pick(["- [ ] todo", "* a", "1. one", "> quote", "---", "```", "| a | b |", "![i](x)", "<u>x</u>", "    indented", "  # indented"])
        case .nasty:
            return pick(["** **", "**", "****", "___", "\\#", "\\\\#", "# ", "#", "#######", "**a **b** c**", "a\\", "**a\\**"])
        }
    }

    /// A whole markdown file with random line endings (all LF, all CRLF, or mixed) and optional final newline.
    mutating func markdown() -> String {
        let count = int(12)
        let style = int(3)   // 0 LF, 1 CRLF, 2 mixed
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

    mutating func runs() -> [Run] {
        (0..<int(5)).map { _ in
            Run(plainText(), bold: pick([nil, nil, BoldDelimiter.asterisks, BoldDelimiter.underscores]))
        }
    }

    mutating func kind() -> BlockKind {
        int(3) == 0 ? .heading(level: 1 + int(6)) : .paragraph
    }

    /// A random edit valid for a document with `count` blocks.
    mutating func edit(blockCount count: Int) -> Edit {
        let roll = int(10)
        if count == 0 || roll < 2 { return .insert(at: int(count + 1), kind: kind(), runs: runs()) }
        if roll < 3 { return .remove(at: int(count)) }
        return .replace(at: int(count), kind: kind(), runs: runs())
    }
}
