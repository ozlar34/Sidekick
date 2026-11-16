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
    /// The last few (buffer content, document) pairs. When the buffer comes back to a content it had before (undo, or
    /// typing and deleting), the document of that time is used again, so the file's exact bytes come back too: the
    /// paragraph diff alone cannot know which line breaks an earlier state had.
    private var history: [(paragraphs: [NoteBuffer.Paragraph], document: NoteDocument)] = []
    private static let historyLimit = 16

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
        history = [(synced, document)]
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
        if let earlier = history.last(where: { $0.paragraphs.count == wanted.count && $0.paragraphs == wanted }) {
            document = earlier.document
            synced = wanted
            remember(wanted)
            return
        }
        var prefix = 0
        while prefix < wanted.count, prefix < synced.count, wanted[prefix] == synced[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < wanted.count - prefix, suffix < synced.count - prefix,
              wanted[wanted.count - 1 - suffix] == synced[synced.count - 1 - suffix] { suffix += 1 }
        let newMid = Array(wanted[prefix..<(wanted.count - suffix)])
        let oldCount = synced.count - suffix - prefix
        for (j, p) in newMid.enumerated() {
            if j < oldCount {
                // Only the checkbox changed: toggling keeps the file's bytes except the bracket character.
                if case .checklist(let was) = synced[prefix + j].kind, case .checklist(let now) = p.kind, was != now,
                   synced[prefix + j].runs == p.runs {
                    document.apply(.toggleCheckbox(block: prefix + j))
                } else {
                    document.apply(.replace(at: prefix + j, kind: p.kind, runs: p.runs))
                }
            }
            else { document.apply(.insert(at: prefix + j, kind: p.kind, runs: p.runs)) }
        }
        if oldCount > newMid.count {
            for _ in 0..<(oldCount - newMid.count) { document.apply(.remove(at: prefix + newMid.count)) }
        }
        synced = wanted
        remember(wanted)
    }

    /// Numbers the numbered items at these block indices 1, 2, 3 ... (the "numbered list" command over lines of which some
    /// were numbered already: the buffer cannot show a number, so the document is edited directly, after the buffer change).
    func renumber(blocks indices: [Int]) {
        for (n, i) in indices.enumerated() where document.blocks.indices.contains(i) { document.apply(.setNumber(block: i, number: n + 1)) }
        remember(synced)
        onEdit?(document.markdown())
    }

    private func remember(_ paragraphs: [NoteBuffer.Paragraph]) {
        history.append((paragraphs, document))
        if history.count > Self.historyLimit { history.removeFirst() }
    }
}
