import Foundation

/// An edit to a note document. Run text must not contain line breaks (they are removed).
public enum Edit: Equatable, Sendable {
    case replace(at: Int, kind: BlockKind, runs: [Run])
    case insert(at: Int, kind: BlockKind, runs: [Run])
    case remove(at: Int)
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
            let old = blocks[i]
            let candidate = Block(id: old.id, kind: kind, runs: NoteDocument.sanitize(runs),
                                  prefix: NoteDocument.prefix(for: kind, replacing: old),
                                  terminator: old.terminator, origin: old.origin)
            if candidate == old { return }          // back at its load-state content: keeps its bytes
            var changed = candidate
            changed.id = nextID; nextID += 1
            blocks[i] = changed
        case .insert(let i, let kind, let runs):
            precondition((0...blocks.count).contains(i), "insert index out of range")
            var terminator = lineEnding
            if i == blocks.count, let last = blocks.last, last.terminator.isEmpty {
                blocks[blocks.count - 1].terminator = terminator   // keeps "no final newline" on the new last line
                terminator = ""
            }
            let defaultPrefix: String
            if case .heading(let level) = kind { defaultPrefix = String(repeating: "#", count: min(6, max(1, level))) + " " }
            else { defaultPrefix = "" }
            blocks.insert(Block(id: nextID, kind: kind, runs: NoteDocument.sanitize(runs), prefix: defaultPrefix,
                                terminator: terminator, origin: nil), at: i)
            nextID += 1
        case .remove(let i):
            precondition(blocks.indices.contains(i), "remove index out of range")
            blocks.remove(at: i)
        }
        // A last block that writes no bytes and no terminator would vanish on reload.
        if let last = blocks.last, last.terminator.isEmpty, last.body.isEmpty {
            blocks[blocks.count - 1].terminator = lineEnding
        }
    }

    // MARK: reading

    private static func parseLine(_ line: String, id: Int, terminator: String) -> Block {
        let s = Array(line.unicodeScalars)
        func make(_ kind: BlockKind, _ runs: [Run], _ prefix: String) -> Block {
            // `normalize` is idempotent on reader output, so the stored model equals the block's model.
            let block = Block(id: id, kind: kind, runs: runs, prefix: prefix, terminator: terminator, origin: nil)
            var withOrigin = block
            withOrigin.origin = Block.Origin(source: line, kind: block.kind, runs: block.runs, prefix: block.prefix)
            return withOrigin
        }
        var h = 0
        while h < s.count, s[h] == "#" { h += 1 }
        if (1...6).contains(h), h == s.count || s[h] == " " || s[h] == "\t" {
            var p = h
            while p < s.count, s[p] == " " || s[p] == "\t" { p += 1 }
            return make(.heading(level: h), InlineReader.read(Array(s[p...])), scalarsToString(s[0..<p]))
        }
        var body = s[...]
        if s.first == "\\", InlineReader.looksLikeHeading(Array(s.dropFirst())) { body = s.dropFirst() }
        return make(.paragraph, InlineReader.read(Array(body)), "")
    }

    // MARK: edit helpers

    private static func sanitize(_ runs: [Run]) -> [Run] {
        runs.map { Run(String(String.UnicodeScalarView($0.text.unicodeScalars.filter { $0 != "\n" && $0 != "\r" })), bold: $0.bold) }
    }

    /// Keeps the file's hash/space spelling when a heading stays a heading.
    private static func prefix(for kind: BlockKind, replacing old: Block) -> String {
        guard case .heading(let level) = kind else { return "" }
        let hashes = String(repeating: "#", count: min(6, max(1, level)))
        if case .heading(let oldLevel) = old.kind {
            if oldLevel == min(6, max(1, level)) { return old.prefix }
            let spacing = String(old.prefix.unicodeScalars.drop(while: { $0 == "#" }))
            return hashes + (spacing.isEmpty ? " " : spacing)
        }
        return hashes + " "
    }
}
