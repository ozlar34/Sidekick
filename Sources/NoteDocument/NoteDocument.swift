import Foundation

/// An edit to a note document. Run text must not contain line breaks (they are removed).
/// Offsets and ranges count UTF-16 units of the block's visible text (`Block.text`: the run texts joined). A URL pill
/// is one object: an offset inside it snaps to its edge, and a range that touches it covers all of it.
public enum Edit: Equatable, Sendable {
    case replace(at: Int, kind: BlockKind, runs: [Run])
    case insert(at: Int, kind: BlockKind, runs: [Run])
    case remove(at: Int)
    /// Insert text at an offset; it takes the marks of the character before it (none of a pill).
    case insertText(block: Int, offset: Int, text: String)
    case deleteText(block: Int, range: Range<Int>)
    /// Set a mark on a range. Code replaces the other marks of the range; other marks skip code.
    case setMark(block: Int, range: Range<Int>, mark: Mark)
    /// Clear a mark on a range (a link's address is ignored). Clearing the link of a pill makes it plain text.
    case clearMark(block: Int, range: Range<Int>, mark: Mark)
    /// Change the block kind, keeping the text and, inside one kind family, the literal prefix.
    case setKind(block: Int, kind: BlockKind)
    /// Flip a checklist item; only the character between the brackets changes. No-op on other kinds.
    case toggleCheckbox(block: Int)
    /// Break a block in two at an offset (Enter). The second block continues a list item or quote, is an unchecked
    /// item for a checklist, and is a paragraph after a heading.
    case split(block: Int, offset: Int)
    /// Append the next block's text to this one (Backspace at a line start). A divider on either side is dropped.
    case join(block: Int)
}

/// The in-memory form of one note: markdown text in, edit, markdown text out.
///
/// Fidelity rule 1: a block equal to its state at load is written from its original bytes.
/// Fidelity rule 2: an edited block is written as its remembered literal prefix plus generated inline text.
/// Fidelity rule 3: generated text is escaped so that loading it gives an equal document.
public struct NoteDocument: Equatable, Sendable {
    public private(set) var blocks: [Block]
    private var nextID: Int

    /// Documents are equal when their blocks are (content and literal forms; not identities).
    public static func == (a: NoteDocument, b: NoteDocument) -> Bool { a.blocks == b.blocks }

    public init(markdown: String) {
        var blocks: [Block] = []
        var id = 0
        let text = markdown.utf8
        var start = text.startIndex
        func add(_ range: Range<String.UTF8View.Index>, terminator hasNewline: Bool) {
            var lineBytes = text[range]
            var terminator = ""
            if hasNewline {
                terminator = "\n"
                if lineBytes.last == 13 { lineBytes = lineBytes.dropLast(); terminator = "\r\n" }
            }
            let line = String(decoding: lineBytes, as: UTF8.self)
            blocks.append(NoteDocument.parseLine(line, id: id, terminator: terminator))
            id += 1
        }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == 10 {
                add(start..<i, terminator: true)
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        if start < text.endIndex { add(start..<text.endIndex, terminator: false) }
        self.blocks = blocks
        self.nextID = id
    }

    /// Markdown text of the document.
    public func markdown() -> String {
        var out = ""
        for b in blocks { out += b.body; out += b.terminator }
        return out
    }

    /// Line ending for new lines: the first one in the document, else LF.
    public var lineEnding: String { blocks.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n" }

    public mutating func apply(_ edit: Edit) {
        switch edit {
        case .replace(let i, let kind, let runs):
            precondition(blocks.indices.contains(i), "replace index out of range")
            commit(i, kind: kind, prefix: NoteDocument.prefix(for: kind, replacing: blocks[i]), runs: NoteDocument.sanitize(runs))
        case .insert(let i, let kind, let runs):
            precondition((0...blocks.count).contains(i), "insert index out of range")
            insertBlock(at: i, kind: kind, prefix: NoteDocument.insertPrefix(kind, after: i > 0 ? blocks[i - 1] : nil), runs: NoteDocument.sanitize(runs))
        case .remove(let i):
            precondition(blocks.indices.contains(i), "remove index out of range")
            blocks.remove(at: i)
        case .insertText(let i, let offset, let text):
            precondition(blocks.indices.contains(i), "block index out of range")
            let b = blocks[i]
            guard b.kind != .divider else { break }
            var runs = b.runs
            let at = RunOps.boundary(&runs, offset, snapUp: false)
            runs.insert(RunOps.typed(Run.stripLineBreaks(text), between: at > 0 ? runs[at - 1] : nil, and: at < runs.count ? runs[at] : nil), at: at)
            commit(i, kind: b.kind, prefix: b.prefix, runs: runs)
        case .deleteText(let i, let range):
            precondition(blocks.indices.contains(i), "block index out of range")
            let b = blocks[i]
            var runs = b.runs
            let (lo, hi) = RunOps.span(&runs, range)
            runs.removeSubrange(lo..<hi)
            commit(i, kind: b.kind, prefix: b.prefix, runs: runs)
        case .setMark(let i, let range, let mark), .clearMark(let i, let range, let mark):
            precondition(blocks.indices.contains(i), "block index out of range")
            let b = blocks[i]
            var runs = b.runs
            var setting = true
            if case .clearMark = edit { setting = false }
            let (lo, hi) = RunOps.span(&runs, range)
            let boldStyle = runs.lazy.compactMap(\.bold).first ?? .asterisks
            let italicStyle = runs.lazy.compactMap(\.italic).first ?? .asterisk
            for k in lo..<hi { RunOps.apply(mark, setting: setting, to: &runs[k], bold: boldStyle, italic: italicStyle) }
            commit(i, kind: b.kind, prefix: b.prefix, runs: runs)
        case .setKind(let i, let kind):
            precondition(blocks.indices.contains(i), "block index out of range")
            commit(i, kind: kind, prefix: NoteDocument.prefix(for: kind, replacing: blocks[i]), runs: blocks[i].runs)
        case .toggleCheckbox(let i):
            precondition(blocks.indices.contains(i), "block index out of range")
            let b = blocks[i]
            guard case .checklist(let checked) = b.kind else { break }
            // Checking again restores the spelling the file had (`X` stays `X`).
            let remembered = b.origin.flatMap { o -> Unicode.Scalar? in
                if case .checklist(true) = o.kind { return Block.checkboxCharacter(o.prefix) } else { return nil }
            }
            commit(i, kind: .checklist(checked: !checked),
                   prefix: Block.settingCheckbox(b.prefix, checked: !checked, character: remembered), runs: b.runs)
        case .split(let i, let offset):
            precondition(blocks.indices.contains(i), "block index out of range")
            let b = blocks[i]
            if b.kind == .divider { insertBlock(at: i + 1, kind: .paragraph, prefix: "", runs: []); break }
            var runs = b.runs
            let at = RunOps.boundary(&runs, offset, snapUp: false)
            commit(i, kind: b.kind, prefix: b.prefix, runs: Array(runs[..<at]))
            let rightKind: BlockKind
            switch b.kind {
            case .heading: rightKind = .paragraph
            case .checklist: rightKind = .checklist(checked: false)
            default: rightKind = b.kind
            }
            insertBlock(at: i + 1, kind: rightKind, prefix: rightKind == .paragraph ? "" : b.prefix, runs: Array(runs[at...]))
        case .join(let i):
            precondition(blocks.indices.contains(i) && i + 1 < blocks.count, "join needs a next block")
            let a = blocks[i], next = blocks[i + 1]
            if a.kind == .divider {
                blocks.remove(at: i)
            } else if next.kind == .divider {
                blocks[i].terminator = next.terminator
                blocks.remove(at: i + 1)
            } else {
                commit(i, kind: a.kind, prefix: a.prefix, runs: a.runs + next.runs)
                blocks[i].terminator = next.terminator
                blocks.remove(at: i + 1)
            }
        }
        // A last block that writes no bytes and no terminator would vanish on reload.
        if let last = blocks.last, last.terminator.isEmpty, last.body.isEmpty {
            blocks[blocks.count - 1].terminator = lineEnding
        }
    }

    /// Replaces block `i` with the edited form; a result equal to the old block changes nothing.
    private mutating func commit(_ i: Int, kind: BlockKind, prefix: String, runs: [Run]) {
        let old = blocks[i]
        let candidate = Block(id: old.id, kind: kind, runs: runs, prefix: prefix, terminator: old.terminator, origin: old.origin)
        if candidate == old { return }          // back at its load-state content: keeps its bytes
        var changed = NoteDocument.settle(candidate)
        changed.id = nextID; nextID += 1
        blocks[i] = changed
    }

    private mutating func insertBlock(at i: Int, kind: BlockKind, prefix: String, runs: [Run]) {
        var terminator = lineEnding
        if i == blocks.count, let last = blocks.last, last.terminator.isEmpty {
            blocks[blocks.count - 1].terminator = terminator   // keeps "no final newline" on the new last line
            terminator = ""
        }
        let block = Block(id: nextID, kind: kind, runs: runs, prefix: prefix, terminator: terminator, origin: nil)
        var settled = NoteDocument.settle(block)
        settled.id = nextID; nextID += 1
        blocks.insert(settled, at: i)
    }

    // MARK: reading

    static func parseLine(_ line: String, id: Int, terminator: String) -> Block {
        let s = Array(line.unicodeScalars)
        func make(_ kind: BlockKind, _ runs: [Run], _ prefix: String) -> Block {
            let raw = prefix
            // `normalize` is idempotent on reader output, so the stored model equals the block's model.
            let block = Block(id: id, kind: kind, runs: runs, prefix: prefix, terminator: terminator, origin: nil)
            var withOrigin = block
            withOrigin.origin = Block.Origin(source: line, kind: block.kind, runs: block.runs, prefix: block.prefix, rawPrefix: raw)
            return withOrigin
        }
        if let hit = BlockSyntax.parse(s) {
            let prefix = scalarsToString(s[0..<hit.prefixLength])
            let runs = hit.kind == .divider ? [] : InlineReader.read(Array(s[hit.prefixLength...]))
            return make(hit.kind, runs, prefix)
        }
        var body = s[...]
        if s.count > 1, s[0] == "\\", !InlineReader.isEscapable(s[1]), BlockSyntax.looksLikeBlock(Array(s.dropFirst())) { body = s.dropFirst() }
        return make(.paragraph, InlineReader.read(Array(body)), "")
    }

    // MARK: edit helpers

    private static func sanitize(_ runs: [Run]) -> [Run] {
        runs.map { var r = $0; r.text = Run.stripLineBreaks(r.text); return r }
    }

    /// Prefix of an inserted block: a numbered item after a numbered item takes the next number, with the same indent and
    /// delimiter (`3)` -> `4)`), as a list continues when the user presses Enter. Every other new block gets the default
    /// prefix (fidelity rule 2).
    private static func insertPrefix(_ kind: BlockKind, after previous: Block?) -> String {
        guard kind == .numbered, let p = previous, p.kind == .numbered else { return BlockSyntax.defaultPrefix(kind) }
        let s = Array(p.prefix.unicodeScalars)
        let start = BlockSyntax.skipBlanks(s, 0)
        var end = start
        while end < s.count, s[end].isASCII, s[end].properties.numericType == .decimal { end += 1 }
        guard end > start, let number = Int(scalarsToString(s[start..<end])), number < 999_999_999 else { return BlockSyntax.defaultPrefix(kind) }
        return scalarsToString(s[0..<start]) + String(number + 1) + scalarsToString(s[end...])
    }

    /// Keeps the file's spelling when a block stays in its kind family; otherwise the default prefix, carrying the
    /// indent and bullet character of a list item that becomes another list item.
    private static func prefix(for kind: BlockKind, replacing old: Block) -> String {
        switch kind {
        case .paragraph: return ""
        case .heading(let level):
            let hashes = String(repeating: "#", count: min(6, max(1, level)))
            if case .heading(let oldLevel) = old.kind {
                if oldLevel == min(6, max(1, level)) { return old.prefix }
                let spacing = String(old.prefix.unicodeScalars.drop(while: { $0 == "#" }))
                return hashes + (spacing.isEmpty ? " " : spacing)
            }
            return hashes + " "
        default:
            if old.kind.family == kind.family { return old.prefix }
            var indent = "", bullet: Character = "-"
            if old.kind.isListItem, kind.isListItem {
                indent = String(old.prefix.unicodeScalars.prefix(while: BlockSyntax.isBlank))
                if let c = old.prefix.unicodeScalars.first(where: { !BlockSyntax.isBlank($0) }), c == "-" || c == "*" { bullet = Character(c) }
            }
            return BlockSyntax.defaultPrefix(kind, indent: indent, bullet: bullet)
        }
    }

    /// Makes an edited block a fixed point of write-then-read, so that load(save(document)) equals the document
    /// (fidelity rule 3). Most text is escaped on write. Forms that cannot be told apart whatever the escapes
    /// (a bare URL followed by text, an `_` italic against a word, `*` against `**`) are respelled: bare URL to link
    /// form, then the other delimiter, before anything else changes. The visible text never changes.
    private static func markCount(_ r: Run) -> Int {
        (r.bold != nil ? 1 : 0) + (r.italic != nil ? 1 : 0) + (r.underline ? 1 : 0) + (r.strikethrough ? 1 : 0)
            + (r.code ? 1 : 0) + (r.link != nil ? 1 : 0) + (r.pill != nil ? 1 : 0)
    }

    static func settle(_ block: Block) -> Block {
        func fixed(_ b: Block) -> Bool {
            let p = parseLine(b.body, id: b.id, terminator: b.terminator)
            return p.kind == b.kind && p.runs == b.runs && p.prefix.utf8.elementsEqual(b.prefix.utf8)
        }
        if fixed(block) { return block }
        enum Pills { case keep, link, plain }
        func respelled(_ runs: [Run], pills: Pills, italic: ItalicDelimiter?, bold: BoldDelimiter?, flip: (Bool, Bool)) -> [Run] {
            runs.map { r in
                var r = r
                switch pills {
                case .keep: break
                case .link: if r.pill == .bare { r.pill = .link }
                case .plain: r.pill = nil
                }
                if let d = r.italic { r.italic = italic ?? (flip.0 ? (d == .asterisk ? .underscore : .asterisk) : d) }
                if let d = r.bold { r.bold = bold ?? (flip.1 ? (d == .asterisks ? .underscores : .asterisks) : d) }
                return r
            }
        }
        func attempt(_ runs: [Run]) -> Block? {
            let candidate = Block(id: block.id, kind: block.kind, runs: runs, prefix: block.prefix,
                                  terminator: block.terminator, origin: nil)
            return fixed(candidate) ? candidate : nil
        }
        // Smallest respelling first: bare URL to link form (or plain text), then the other italic / bold delimiter.
        let flips: [(Bool, Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        for pills in [Pills.keep, .link, .plain] {
            for flip in flips {
                if pills == .keep, flip == (false, false) { continue }
                if let b = attempt(respelled(block.runs, pills: pills, italic: nil, bold: nil, flip: flip)) { return b }
            }
        }
        // One delimiter spelling for every mark of the block.
        for pills in [Pills.link, .plain] {
            for bold in [BoldDelimiter.asterisks, .underscores] {
                for italic in [ItalicDelimiter.asterisk, .underscore] {
                    if let b = attempt(respelled(block.runs, pills: pills, italic: italic, bold: bold, flip: (false, false))) { return b }
                }
            }
        }
        // Last resort: the runs that carry the most marks lose their marks (their text stays), one at a time, until
        // the block is stable. Visible text is never changed; the formatting lost is only what cannot be written.
        var runs = block.runs
        let order = runs.indices.sorted { markCount(runs[$0]) > markCount(runs[$1]) }
        for k in order where markCount(runs[k]) > 0 {
            runs[k] = Run(runs[k].text)
            if let b = attempt(runs) { return b }
        }
        return Block(id: block.id, kind: block.kind, runs: [Run(block.text)], prefix: block.prefix,
                     terminator: block.terminator, origin: nil)
    }
}
