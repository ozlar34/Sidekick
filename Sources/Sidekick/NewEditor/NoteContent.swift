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
        synced = NoteBuffer.paragraphs(of: document)
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
        if let tail = NoteBuffer.paragraphRanges(in: ns).last, tail.length > 0 {
            tailKind = NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: NSMaxRange(tail) - 1, effectiveRange: nil))
        }
        let wanted = NoteBuffer.paragraphs(in: storage, tailKind: tailKind)
        var prefix = 0
        while prefix < wanted.count, prefix < synced.count, wanted[prefix] == synced[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < wanted.count - prefix, suffix < synced.count - prefix,
              wanted[wanted.count - 1 - suffix] == synced[synced.count - 1 - suffix] { suffix += 1 }
        let newMid = Array(wanted[prefix..<(wanted.count - suffix)])
        let oldCount = synced.count - suffix - prefix
        for (j, p) in newMid.enumerated() {
            if j < oldCount { document.apply(.replace(at: prefix + j, kind: p.kind, runs: p.runs)) }
            else { document.apply(.insert(at: prefix + j, kind: p.kind, runs: p.runs)) }
        }
        if oldCount > newMid.count {
            for _ in 0..<(oldCount - newMid.count) { document.apply(.remove(at: prefix + newMid.count)) }
        }
        synced = wanted
    }
}
