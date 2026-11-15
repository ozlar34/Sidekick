import Foundation

/// Delimiter spelling of a bold run, remembered so an edited block keeps the file's style.
public enum BoldDelimiter: String, Sendable {
    case asterisks = "**"
    case underscores = "__"
}

/// A run of visible text with one style. `bold == nil` is plain text.
public struct Run: Equatable, Sendable {
    public var text: String
    public var bold: BoldDelimiter?
    public init(_ text: String, bold: BoldDelimiter? = nil) {
        self.text = text
        self.bold = bold
    }
    /// Byte-exact comparison (String `==` is canonical equivalence, which would hide a changed byte form).
    public static func == (a: Run, b: Run) -> Bool {
        a.bold == b.bold && a.text.utf8.elementsEqual(b.text.utf8)
    }
}

/// What a block is. Later tickets add bullet, numbered, checklist, quote, divider, fence, table.
public enum BlockKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
}

/// One line of the note. Blank lines are paragraphs with no runs.
public struct Block: Equatable, Sendable {
    /// Identity inside one document. An edited block gets a new id.
    public internal(set) var id: Int
    public let kind: BlockKind
    public let runs: [Run]
    /// Literal file prefix (heading hashes plus the whitespace after them); empty for paragraphs.
    public let prefix: String
    /// Literal line ending: "\n", "\r\n", or "" for a final line without one.
    public internal(set) var terminator: String
    /// Load-time snapshot of a block that came from a file: its original bytes (without terminator) and
    /// the model they read as. While the block equals that model it is written from those bytes (rule 1).
    struct Origin {
        let source: String
        let kind: BlockKind
        let runs: [Run]
        let prefix: String
    }
    var origin: Origin?

    /// Equality of content and literal forms. Ignores `id` and `origin`.
    public static func == (a: Block, b: Block) -> Bool {
        a.kind == b.kind && a.runs == b.runs
            && a.prefix.utf8.elementsEqual(b.prefix.utf8)
            && a.terminator == b.terminator
    }

    init(id: Int, kind: BlockKind, runs: [Run], prefix: String, terminator: String, origin: Origin?) {
        var kind = kind
        var prefix = prefix
        var runs = Block.normalize(runs)
        switch kind {
        case .paragraph:
            prefix = ""
        case .heading(let level):
            kind = .heading(level: min(6, max(1, level)))
            // Leading space/tab of the content belongs to the prefix (the reader puts it there).
            if case .heading = kind, let first = runs.first, first.bold == nil {
                let trimmed = String(first.text.unicodeScalars.drop(while: { $0 == " " || $0 == "\t" }))
                if trimmed.utf8.count != first.text.utf8.count {
                    let moved = String(first.text.unicodeScalars.prefix(first.text.unicodeScalars.count - trimmed.unicodeScalars.count))
                    prefix += moved
                    if trimmed.isEmpty { runs.removeFirst() } else { runs[0].text = trimmed }
                }
            }
            if !runs.isEmpty, let last = prefix.unicodeScalars.last, last != " " && last != "\t" { prefix += " " }
        }
        self.id = id
        self.kind = kind
        self.runs = runs
        self.prefix = prefix
        self.terminator = terminator
        self.origin = origin
    }

    /// Line bytes without terminator.
    var body: String {
        if let o = origin, o.kind == kind, o.runs == runs, o.prefix.utf8.elementsEqual(prefix.utf8) { return o.source }
        return prefix + InlineWriter.write(runs, atLineStart: kind == .paragraph)
    }

    /// Merge, trim and drop runs so that equal content has one representation.
    static func normalize(_ input: [Run]) -> [Run] {
        var split: [Run] = []
        for r in input where !r.text.isEmpty {
            guard r.bold != nil else { split.append(r); continue }
            let s = Array(r.text.unicodeScalars)
            var lo = 0, hi = s.count
            while lo < hi, s[lo].properties.isWhitespace { lo += 1 }
            while hi > lo, s[hi - 1].properties.isWhitespace { hi -= 1 }
            if lo == hi { split.append(Run(r.text)); continue }
            if lo > 0 { split.append(Run(scalarsToString(s[0..<lo]))) }
            split.append(Run(scalarsToString(s[lo..<hi]), bold: r.bold))
            if hi < s.count { split.append(Run(scalarsToString(s[hi...]))) }
        }
        var merged: [Run] = []
        for r in split {
            if var last = merged.last, last.bold == r.bold {
                last.text += r.text
                merged[merged.count - 1] = last
            } else { merged.append(r) }
        }
        return merged
    }
}

func scalarsToString<S: Sequence>(_ s: S) -> String where S.Element == Unicode.Scalar {
    var out = String.UnicodeScalarView()
    out.append(contentsOf: s)
    return String(out)
}
