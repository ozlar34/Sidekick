import Foundation

/// Delimiter spelling of a bold run, remembered so an edited block keeps the file's style.
public enum BoldDelimiter: String, Sendable {
    case asterisks = "**"
    case underscores = "__"
}

/// Delimiter spelling of an italic run.
public enum ItalicDelimiter: String, Sendable {
    case asterisk = "*"
    case underscore = "_"
}

/// How a URL pill is spelled in the file: the bare address, or a link whose label equals its address.
public enum PillForm: Sendable {
    case bare
    case link
}

/// A run of visible text with one style. A run with no marks is plain text.
/// A pill run is one inline object: its `text` is the address.
public struct Run: Equatable, Sendable {
    public var text: String
    public var bold: BoldDelimiter?
    public var italic: ItalicDelimiter?
    public var underline: Bool
    public var strikethrough: Bool
    public var code: Bool
    /// Link address; the run text is the label.
    public var link: String?
    public var pill: PillForm?
    public init(_ text: String, bold: BoldDelimiter? = nil, italic: ItalicDelimiter? = nil, underline: Bool = false,
                strikethrough: Bool = false, code: Bool = false, link: String? = nil, pill: PillForm? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.code = code
        self.link = link
        self.pill = pill
    }
    /// Byte-exact comparison (String `==` is canonical equivalence, which would hide a changed byte form).
    public static func == (a: Run, b: Run) -> Bool {
        a.sameStyle(b) && a.text.utf8.elementsEqual(b.text.utf8)
    }
    /// Equal marks, ignoring text.
    func sameStyle(_ b: Run) -> Bool {
        bold == b.bold && italic == b.italic && underline == b.underline && strikethrough == b.strikethrough
            && code == b.code && pill == b.pill
            && (link == nil) == (b.link == nil)
            && (link == nil || link!.utf8.elementsEqual(b.link!.utf8))
    }
    var hasNoMarks: Bool {
        bold == nil && italic == nil && !underline && !strikethrough && !code && link == nil && pill == nil
    }
}

/// An inline mark that can be set or cleared on a range. `link` carries the address (ignored when clearing).
public enum Mark: Equatable, Sendable {
    case bold, italic, underline, strikethrough, code
    case link(String)
}

/// What a block is. A fence (code block) and a table span several file lines.
public enum BlockKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case bullet
    case numbered
    case checklist(checked: Bool)
    case quote
    case divider
    /// Fenced code block. `runs` is one plain run: the content lines joined by "\n" (none for an empty block).
    /// `prefix` is the opening fence line (with its info string), `trailer` the closing line.
    case fence
    /// Table. `runs` is the flattened grid: cells of a row joined by "\t", rows by U+2028, header row first.
    /// `trailer` is the delimiter row.
    case table
}

/// One line of the note, or one code block / table (several lines). Blank lines are paragraphs with no runs.
public struct Block: Equatable, Sendable {
    /// Identity inside one document. An edited block gets a new id.
    public internal(set) var id: Int
    public let kind: BlockKind
    public let runs: [Run]
    /// Literal file prefix: heading hashes, list marker with indent, checkbox, quote bar (each with the whitespace
    /// after it), or the whole spelling of a divider; empty for paragraphs.
    public let prefix: String
    /// Literal line ending: "\n", "\r\n", or "" for a final line without one.
    public internal(set) var terminator: String
    /// Fence: the literal closing fence line. Table: the literal delimiter row. Empty for other kinds.
    public let trailer: String
    /// Line ending between the lines inside a fence or table; empty for other kinds.
    public let inner: String
    /// Load-time snapshot of a block that came from a file: its original bytes (without terminator) and
    /// the model they read as. While the block equals that model it is written from those bytes (rule 1).
    struct Origin {
        let source: String
        let kind: BlockKind
        let runs: [Run]
        let prefix: String
        /// The prefix as the reader cut it from `source`. `prefix` can be longer: blanks that the reader found
        /// inside a mark at the start of the text are moved into it.
        let rawPrefix: String
        let trailer: String
    }
    var origin: Origin?

    /// Visible text of the block: the run texts joined (a pill counts as its address).
    public var text: String { runs.map(\.text).joined() }

    /// The info string of a code block (its language word), not part of the visible content.
    public var fenceInfo: String {
        guard kind == .fence else { return "" }
        let s = prefix.unicodeScalars
        let c = s.first
        return String(s.drop(while: { $0 == c })).trimmingCharacters(in: .whitespaces)
    }

    /// Equality of content and literal forms. Ignores `id` and `origin`.
    public static func == (a: Block, b: Block) -> Bool {
        a.kind == b.kind && a.runs == b.runs
            && a.prefix.utf8.elementsEqual(b.prefix.utf8)
            && a.terminator == b.terminator
            && a.trailer.utf8.elementsEqual(b.trailer.utf8) && a.inner == b.inner
    }

    init(id: Int, kind: BlockKind, runs input: [Run], prefix: String, terminator: String,
         trailer: String = "", inner: String = "", origin: Origin?) {
        var kind = kind
        var prefix = prefix
        var trailer = trailer
        var inner = inner
        var runs: [Run]
        switch kind {
        case .fence: runs = Block.normalizeFence(input)
        case .table: runs = Table.normalize(input)
        default: runs = Block.normalize(input)
        }
        switch kind {
        case .fence:
            inner = inner.isEmpty ? "\n" : inner
            var open = BlockSyntax.fenceOpen(Array(prefix.unicodeScalars))
            if open == nil { prefix = "```"; open = BlockSyntax.Fence(char: "`", count: 3) }
            var fence = open!
            // Content that would close the fence makes the fence longer.
            let lines = Block.codeLines(runs.first?.text ?? "").map { Array($0.unicodeScalars) }
            while !runs.isEmpty, lines.contains(where: { BlockSyntax.isFenceClose($0, fence) }) {
                fence = BlockSyntax.Fence(char: fence.char, count: fence.count + 1)
                prefix = String(repeating: String(fence.char), count: fence.count) + String(prefix.unicodeScalars.drop(while: { $0 == fence.char }))
                trailer = ""
            }
            let t = Array(trailer.unicodeScalars)
            if !BlockSyntax.isFenceClose(t, fence) || t.first != fence.char { trailer = String(repeating: String(fence.char), count: fence.count) }
        case .table:
            inner = inner.isEmpty ? "\n" : inner
            prefix = ""
            let columns = Table.rows(from: runs).first?.count ?? 1
            if BlockSyntax.separatorCount(Array(trailer.unicodeScalars)) != columns { trailer = BlockSyntax.defaultSeparator(columns: columns) }
        default:
            trailer = ""; inner = ""
        }
        switch kind {
        case .fence, .table: break
        case .paragraph:
            prefix = ""
        case .divider:
            runs = []
            if !BlockSyntax.isDivider(Array(prefix.unicodeScalars)) { prefix = "---" }
        case .heading(let level):
            kind = .heading(level: min(6, max(1, level)))
            Block.moveLeadingBlanks(&runs, into: &prefix)
            if !runs.isEmpty, let last = prefix.unicodeScalars.last, !BlockSyntax.isBlank(last) { prefix += " " }
        case .bullet, .numbered, .checklist, .quote:
            Block.moveLeadingBlanks(&runs, into: &prefix)
            if let last = prefix.unicodeScalars.last, !BlockSyntax.isBlank(last) { prefix += " " }
            if case .checklist(let checked) = kind { prefix = Block.settingCheckbox(prefix, checked: checked) }
        }
        self.id = id
        self.kind = kind
        self.runs = runs
        self.prefix = prefix
        self.terminator = terminator
        self.trailer = trailer
        self.inner = inner
        self.origin = origin
    }

    /// Leading space/tab of the content belongs to the prefix (the reader puts it there).
    private static func moveLeadingBlanks(_ runs: inout [Run], into prefix: inout String) {
        guard let first = runs.first, first.hasNoMarks else { return }
        let scalars = first.text.unicodeScalars
        let trimmed = String(scalars.drop(while: BlockSyntax.isBlank))
        guard trimmed.utf8.count != first.text.utf8.count else { return }
        prefix += String(scalars.prefix(scalars.count - trimmed.unicodeScalars.count))
        if trimmed.isEmpty { runs.removeFirst() } else { runs[0].text = trimmed }
    }

    /// The checkbox character between `[` and `]` of a checklist prefix.
    static func checkboxCharacter(_ prefix: String) -> Unicode.Scalar? {
        let s = Array(prefix.unicodeScalars)
        guard let open = s.firstIndex(of: "["), open + 2 < s.count else { return nil }
        return s[open + 1]
    }

    /// `prefix` with its checkbox character made to agree with `checked` (an existing `x` or `X` stays).
    static func settingCheckbox(_ prefix: String, checked: Bool, character: Unicode.Scalar? = nil) -> String {
        var s = Array(prefix.unicodeScalars)
        guard let open = s.firstIndex(of: "["), open + 2 < s.count else { return prefix }
        let current = s[open + 1]
        if checked { if current == " " || character != nil { s[open + 1] = character ?? "x" } }
        else { s[open + 1] = " " }
        return scalarsToString(s)
    }

    /// Line bytes without terminator.
    var body: String {
        if let o = origin, o.runs == runs {
            if o.kind == kind, o.prefix.utf8.elementsEqual(prefix.utf8), o.trailer.utf8.elementsEqual(trailer.utf8) { return o.source }
            // Only the prefix changed inside one family (heading level, checkbox): the inline bytes stay.
            let extra = o.prefix.utf8.count - o.rawPrefix.utf8.count
            if o.kind.family == kind.family, kind != .paragraph, !kind.isMultiline, extra >= 0, prefix.utf8.count >= extra,
               o.source.utf8.starts(with: o.rawPrefix.utf8) {
                return String(decoding: prefix.utf8.dropLast(extra), as: UTF8.self)
                    + String(decoding: o.source.utf8.dropFirst(o.rawPrefix.utf8.count), as: UTF8.self)
            }
        }
        return generated
    }

    /// Line bytes written from the model alone, ignoring the load snapshot.
    var generated: String {
        switch kind {
        case .divider: return prefix
        case .fence:
            let text = runs.first?.text ?? ""
            let lines = text.isEmpty ? [] : Block.codeLines(text)
            return prefix + inner + lines.map { $0 + inner }.joined() + trailer
        case .table:
            let rows = Table.rows(from: runs)
            func line(_ cells: [[Run]]) -> String {
                "|" + cells.map { " " + Table.cellText($0) + " |" }.joined()
            }
            var lines = [line(rows[0]), trailer]
            lines += rows.dropFirst().map(line)
            return lines.joined(separator: inner)
        default: return prefix + InlineWriter.write(runs, kind: kind)
        }
    }

    /// Lines of code content, split by scalar (a "\n" before a combining mark is still a line break).
    static func codeLines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }

    /// Code content: one plain run, no CR (a line ending is not content), U+2028 (the buffer's line separator) as a blank.
    static func normalizeFence(_ input: [Run]) -> [Run] {
        let text = input.map(\.text).joined().unicodeScalars.filter { $0 != "\r" }.map { $0 == "\u{2028}" ? " " : String($0) }.joined()
        return text.isEmpty ? [] : [Run(text)]
    }

    /// Merge, trim and drop runs so that equal content has one representation.
    static func normalize(_ input: [Run]) -> [Run] {
        var pieces: [Run] = []
        for var r in input where !r.text.isEmpty {
            if let url = r.link { r.link = sanitizeURL(url) }
            if r.pill != nil, r.link != nil { r.pill = nil }    // a link label holds no pill
            if r.code {
                r.pill = nil
                // A backtick cannot be written inside a code span: it becomes plain text between two code runs.
                var current = String.UnicodeScalarView()
                for c in r.text.unicodeScalars {
                    if c == "`" {
                        if !current.isEmpty { var part = r; part.text = String(current); pieces.append(part); current = .init() }
                        var tick = r; tick.code = false; tick.text = "`"; pieces.append(tick)
                    } else { current.append(c) }
                }
                if !current.isEmpty { r.text = String(current); pieces.append(r) }
                continue
            }
            if r.pill != nil { pieces.append(r); continue }
            if r.bold != nil || r.italic != nil {
                // Bold and italic cannot start or end with whitespace: it moves to a run without them.
                let s = Array(r.text.unicodeScalars)
                var lo = 0, hi = s.count
                while lo < hi, s[lo].properties.isWhitespace { lo += 1 }
                while hi > lo, s[hi - 1].properties.isWhitespace { hi -= 1 }
                var bare = r; bare.bold = nil; bare.italic = nil
                if lo == hi { bare.text = r.text; pieces.append(bare); continue }
                if lo > 0 { var lead = bare; lead.text = scalarsToString(s[0..<lo]); pieces.append(lead) }
                var core = r; core.text = scalarsToString(s[lo..<hi]); pieces.append(core)
                if hi < s.count { var tail = bare; tail.text = scalarsToString(s[hi...]); pieces.append(tail) }
                continue
            }
            pieces.append(r)
        }
        func merge(_ runs: [Run]) -> [Run] {
            var merged: [Run] = []
            for r in runs {
                if var last = merged.last, last.pill == nil, r.pill == nil, last.sameStyle(r) {
                    last.text += r.text
                    merged[merged.count - 1] = last
                } else { merged.append(r) }
            }
            return merged
        }
        // A struck-through run of only blanks is not struck (the reader needs some text inside `~~`).
        let blankFixed = merge(pieces).map { r -> Run in
            var r = r
            if r.strikethrough, r.text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) { r.strikethrough = false }
            return r
        }
        // A link whose label is its address and nothing else is a pill (the reader reads `[u](u)` that way).
        let pilled = blankFixed.map { r -> Run in
            var r = r
            if let url = r.link, r.pill == nil, !r.code, r.bold == nil, r.italic == nil, !r.underline, !r.strikethrough,
               url.utf8.elementsEqual(r.text.utf8) { r.link = nil; r.pill = .link }
            return r
        }
        return merge(pilled)
    }

    /// A link address cannot hold a line break or `)` (the reader ends the address there).
    static func sanitizeURL(_ url: String) -> String {
        String(url.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }.map { $0 == ")" ? "%29" : String($0) }.joined())
    }
}

func scalarsToString<S: Sequence>(_ s: S) -> String where S.Element == Unicode.Scalar {
    var out = String.UnicodeScalarView()
    out.append(contentsOf: s)
    return String(out)
}

extension Run {
    static func stripLineBreaks(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
    }
}
