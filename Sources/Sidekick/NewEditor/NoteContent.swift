import AppKit
import NoteDocument

/// The text of one open note as the editor shows it: its own text storage, its own undo history and
/// the note document kept in step with the storage. One per open note. The single text view switches
/// to another note's content with `NoteTextView.attach`, so storage and undo history never mix.
@MainActor
final class NoteContent {
    let storage = NSTextStorage()
    let undoManager = UndoManager()
    private(set) var document = NoteDocument(markdown: "")
    /// False for a note that must not be typed into (unreadable file).
    var isEditable = true
    /// Selection to restore when the view comes back to this note.
    var savedSelection = NSRange(location: 0, length: 0)
    /// Kind of the tail paragraph while it has no characters (it has nothing to carry a kind).
    var tailKind: BlockKind = .paragraph
    private var synced: [NoteBuffer.Paragraph] = []
    /// Index of the last line at the previous sync (see `syncDocument`).
    private var tailLine = 0
    /// Every (buffer content, document) pair this note has been in, so that when the buffer comes back to a content it
    /// had before (undo at any depth, redo, or typing and deleting) the document of that time is used again and the file's
    /// exact bytes come back: the paragraph diff alone cannot know which line breaks or spellings an earlier state had.
    /// Documents share their unedited blocks between states (copy on write), so a state costs one array of block
    /// references. The memory is bounded by a budget of block references: past it the oldest states are dropped (the
    /// loaded state never is), so only a very long session on a big note loses the oldest steps' spellings.
    private struct Snapshot {
        var paragraphs: [NoteBuffer.Paragraph]
        var document: NoteDocument
        let order: Int
    }
    /// Snapshots by a fingerprint of the paragraphs (kinds, text and run count; marks are compared on a hit).
    private var history: [Int: [Snapshot]] = [:]
    private var historyOrder: [(key: Int, order: Int)] = []
    private var historyHead = 0
    private var historyCost = 0
    private var nextOrder = 0
    private static let historyBudget = 1_000_000

    /// Blocks that a paste has just read, with their file bytes. A block of the buffer that equals one of them is written
    /// with its literal spellings (rule 1 of the note document), so that paste keeps `*` bullets, numbers and fences.
    /// Set around one paste only.
    var pastedSources: [(kind: BlockKind, runs: [Run], source: String)] = []

    /// Called with the document's markdown after every edit made through the view.
    var onEdit: ((String) -> Void)?

    init(markdown: String = "") { reload(markdown: markdown) }

    var markdown: String { document.markdown() }

    /// Replaces the whole note from markdown (first open, reload from disk). Not an undo step:
    /// the undo history is dropped, because it describes text that is gone.
    func reload(markdown: String) {
        document = NoteDocument(markdown: markdown)
        let (text, tail) = NoteBuffer.attributed(for: document)
        tailKind = tail
        tailLine = text.string.components(separatedBy: "\n").count - 1
        synced = NoteBuffer.paragraphs(of: document)
        history = [:]; historyOrder = []; historyHead = 0; historyCost = 0
        remember(textKey: Self.fingerprint(synced), synced, pinned: true)
        storage.beginEditing()
        storage.setAttributedString(text)
        NoteBuffer.restyle(storage, edited: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        savedSelection = NSRange(location: 0, length: 0)
        undoManager.removeAllActions()
    }

    /// Brings the document in line with the storage after an edit (paragraph diff: unedited blocks
    /// keep their original bytes), then reports the new markdown.
    func storageDidChange() {
        syncDocument()
        onEdit?(document.markdown())
    }

    private func syncDocument() {
        let ns = storage.string as NSString
        // `tailKind` belongs to the last LINE while it is the tail: an empty list item typed into and erased again keeps
        // its kind. When the last line is a different one than before (the line break after the old last line was
        // removed, so that line became the tail), its kind must not stay behind: it would come back on the empty line
        // after the line break returns (undo of its removal), and the file would gain an empty `### ` line.
        let lastLine = ns.components(separatedBy: "\n").count - 1
        if let tail = NoteBuffer.paragraphRanges(in: ns).last, tail.length > 0 {
            tailKind = lastLine == tailLine
                ? NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: NSMaxRange(tail) - 1, effectiveRange: nil))
                : .paragraph
        }
        tailLine = lastLine
        let wanted = NoteBuffer.paragraphs(in: storage, tailKind: tailKind)
        if wanted == synced { return }
        let key = Self.fingerprint(wanted)
        if let earlier = history[key]?.last(where: { $0.paragraphs == wanted }) {
            document = earlier.document
            synced = wanted
            return
        }
        var prefix = 0
        while prefix < wanted.count, prefix < synced.count, wanted[prefix] == synced[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < wanted.count - prefix, suffix < synced.count - prefix,
              wanted[wanted.count - 1 - suffix] == synced[synced.count - 1 - suffix] { suffix += 1 }
        let newMid = Array(wanted[prefix..<(wanted.count - suffix)])
        let oldCount = synced.count - suffix - prefix
        for (j, p) in newMid.enumerated() where j < oldCount {
            // Only the checkbox changed: toggling keeps the file's bytes except the bracket character.
            if case .checklist(let was) = synced[prefix + j].kind, case .checklist(let now) = p.kind, was != now,
               synced[prefix + j].runs == p.runs {
                document.apply(.toggleCheckbox(block: prefix + j))
            } else if let source = pastedSource(of: p, fromEnd: false) {
                document.apply(.replaceSource(at: prefix + j, source: source, kind: p.kind, runs: p.runs))
            } else {
                document.apply(.replace(at: prefix + j, kind: p.kind, runs: p.runs))
            }
        }
        // New blocks go in last to first at one place, so that a new table never stands next to an old one for a moment
        // (the document reads two tables in a row as one).
        for j in stride(from: newMid.count - 1, through: oldCount, by: -1) {
            let p = newMid[j]
            if let source = pastedSource(of: p, fromEnd: true) { document.apply(.insertSource(at: prefix + oldCount, source: source, kind: p.kind, runs: p.runs)) }
            else { document.apply(.insert(at: prefix + oldCount, kind: p.kind, runs: p.runs)) }
        }
        if oldCount > newMid.count {
            for _ in 0..<(oldCount - newMid.count) { document.apply(.remove(at: prefix + newMid.count)) }
        }
        synced = wanted
        remember(textKey: key, wanted)
    }

    /// The file bytes of the pasted block that `p` equals, each used once (two equal blocks, such as dividers, may be
    /// spelled differently): in document order, or from the last one when the blocks are visited last to first.
    private func pastedSource(of p: NoteBuffer.Paragraph, fromEnd: Bool) -> String? {
        let match: (Int) -> Bool = { self.pastedSources[$0].kind == p.kind && self.pastedSources[$0].runs == p.runs }
        guard let i = fromEnd ? pastedSources.indices.last(where: match) : pastedSources.indices.first(where: match) else { return nil }
        return pastedSources.remove(at: i).source
    }

    /// Numbers the numbered items at these block indices 1, 2, 3 ... (the "numbered list" command over lines of which some
    /// were numbered already: the buffer cannot show a number, so the document is edited directly, after the buffer change).
    func renumber(blocks indices: [Int]) {
        for (n, i) in indices.enumerated() where document.blocks.indices.contains(i) { document.apply(.setNumber(block: i, number: n + 1)) }
        remember(textKey: Self.fingerprint(synced), synced)
        onEdit?(document.markdown())
    }

    /// Gives the numbered item at block `index` the number the user typed (`7. `): the buffer cannot show a number, so the
    /// document is edited directly, after the buffer change.
    func setNumber(_ number: Int, ofBlock index: Int) {
        guard document.blocks.indices.contains(index) else { return }
        document.apply(.setNumber(block: index, number: number))
        remember(textKey: Self.fingerprint(synced), synced)
        onEdit?(document.markdown())
    }

    /// Records the current document for the buffer content `paragraphs` (fingerprint `textKey`). A content seen
    /// before gets its document replaced (renumbering changes the file but not the buffer).
    private static func fingerprint(_ paragraphs: [NoteBuffer.Paragraph]) -> Int {
        var hasher = Hasher()
        hasher.combine(paragraphs.count)
        for p in paragraphs {
            hasher.combine(String(describing: p.kind))
            hasher.combine(p.runs.count)
            for r in p.runs { hasher.combine(r.text) }
        }
        return hasher.finalize()
    }

    private func remember(textKey: Int, _ paragraphs: [NoteBuffer.Paragraph], pinned: Bool = false) {
        if let i = history[textKey]?.firstIndex(where: { $0.paragraphs == paragraphs }) {
            history[textKey]![i].document = document
            return
        }
        history[textKey, default: []].append(Snapshot(paragraphs: paragraphs, document: document, order: nextOrder))
        if !pinned { historyOrder.append((textKey, nextOrder)) }
        nextOrder += 1
        historyCost += paragraphs.count + 1
        // Drop the oldest unpinned states while over budget (always keep the newest).
        while historyCost > Self.historyBudget, historyHead < historyOrder.count - 1 {
            let old = historyOrder[historyHead]
            historyHead += 1
            if let i = history[old.key]?.firstIndex(where: { $0.order == old.order }) {
                historyCost -= history[old.key]![i].paragraphs.count + 1
                history[old.key]!.remove(at: i)
                if history[old.key]!.isEmpty { history[old.key] = nil }
            }
        }
        if historyHead > 4096 { historyOrder.removeFirst(historyHead); historyHead = 0 }
    }
}
