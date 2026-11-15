import AppKit
import NoteDocument

/// The new editor's text view: a native rich-text `NSTextView` whose buffer holds only visible
/// characters. It owns the note document and keeps it in step with the buffer after every edit.
///
/// Key handling is native except one structural rule: Enter at the end of a heading starts a
/// normal paragraph. Arrow keys, selection and clicks are not overridden.
final class NoteTextView: NSTextView, NSTextStorageDelegate {
    /// The note shown now: its storage, undo history and document. `attach` switches it.
    private(set) var content = NoteContent()
    private var tailKind: BlockKind {
        get { content.tailKind }
        set { content.tailKind = newValue }
    }

    /// Called with the document's markdown after every edit made through the view.
    var onMarkdownChange: ((String) -> Void)?
    /// Called on Shift-Tab at offset 0.
    var onShiftTabAtStart: (() -> Void)?

    var markdown: String { content.markdown }
    var document: NoteDocument { content.document }

    /// The undo history belongs to the note shown, never to the window.
    override var undoManager: UndoManager? { content.undoManager }

    /// Block kinds in document order, e.g. ["h1", "p"].
    var blockKinds: [String] {
        document.blocks.map { b in
            switch b.kind {
            case .paragraph: return "p"
            case .heading(let level): return "h\(level)"
            }
        }
    }

    static func make() -> NoteTextView {
        let stack = NoteTextEngine.makeStack()
        let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 0), textContainer: stack.container)
        tv.configure()
        tv.attach(NoteContent())
        return tv
    }

    private func configure() {
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = .width
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        // Same as the old editor (F-07): no automatic text mutation.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        textContainerInset = NSSize(width: 14, height: 14)
        insertionPointColor = NSColor.textColor
        backgroundColor = NSColor.textBackgroundColor
        drawsBackground = true
        typingAttributes = NoteBuffer.typingAttributes(for: .paragraph)
    }

    // MARK: Loading

    /// Shows another open note's content in this view: its storage, undo history and selection.
    func attach(_ new: NoteContent) {
        guard new !== content || textStorage !== new.storage else { return }
        content.savedSelection = selectedRange()
        content.storage.delegate = nil
        content = new
        pendingStyleRange = nil
        layoutManager?.replaceTextStorage(new.storage)
        new.storage.delegate = self
        isEditable = new.isEditable
        let length = new.storage.length
        let sel = new.savedSelection
        setSelectedRange(NSRange(location: min(sel.location, length), length: min(sel.length, max(0, length - sel.location))))
        refreshTailTypingAttributes()
    }

    /// Replaces the whole note from markdown (reload). Not an undo step: history is cleared.
    func load(markdown: String) {
        content.reload(markdown: markdown)
        pendingStyleRange = nil
        setSelectedRange(NSRange(location: 0, length: 0))
        refreshTailTypingAttributes()
    }

    /// Replaces the whole note from markdown through the user edit path (one undo step).
    func replaceAllWithMarkdown(_ markdown: String) {
        let (text, _) = NoteBuffer.attributed(for: NoteDocument(markdown: markdown))
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: full, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: Styling (NSTextStorageDelegate)
    // Widening the edited range inside processEditing would move the caret to the end of the widened
    // range, so the delegate only records what changed. The paragraphs it touched are made uniform
    // right after the edit (`normalizeStyle`) as an attributes-only edit, which leaves the caret alone.

    private var pendingStyleRange: NSRange?

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        pendingStyleRange = pendingStyleRange.map { NSUnionRange($0, editedRange) } ?? editedRange
    }

    private func normalizeStyle() {
        guard let range = pendingStyleRange, let storage = textStorage else { return }
        pendingStyleRange = nil
        storage.beginEditing()
        NoteBuffer.restyle(storage, edited: range)
        storage.endEditing()
    }

    // MARK: Buffer -> document

    override func didChangeText() {
        super.didChangeText()
        normalizeStyle()
        content.storageDidChange()
        refreshTailTypingAttributes()
        onMarkdownChange?(content.markdown)
    }

    // MARK: Tail paragraph

    /// An empty tail paragraph has no character, so AppKit would hand it the previous paragraph's
    /// attributes (a heading's). Typing attributes there come from `tailKind` instead.
    private func refreshTailTypingAttributes() {
        let sel = selectedRange()
        let ns = string as NSString
        guard sel.length == 0, sel.location == ns.length, sel.location == 0 || ns.character(at: sel.location - 1) == 0x0A else { return }
        typingAttributes = NoteBuffer.typingAttributes(for: tailKind)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        refreshTailTypingAttributes()
    }

    // MARK: Structural key rules

    /// Enter at the end of a heading starts a normal paragraph. Everywhere else Enter is native.
    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        guard sel.length == 0, let storage = textStorage, ns.length > 0 else { return super.insertNewline(sender) }
        let ranges = NoteBuffer.paragraphRanges(in: ns)
        guard let para = ranges.first(where: { $0.location <= sel.location && sel.location <= NSMaxRange($0) }),
              sel.location == NSMaxRange(para), para.length > 0,
              case .heading = NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: para.location, effectiveRange: nil))
        else { return super.insertNewline(sender) }
        if NSMaxRange(para) < ns.length {
            // Break after the heading's own "\n": the new empty paragraph gets its own plain "\n".
            let at = NSMaxRange(para) + 1
            insertText(NSAttributedString(string: "\n", attributes: NoteBuffer.typingAttributes(for: .paragraph)),
                       replacementRange: NSRange(location: at, length: 0))
            setSelectedRange(NSRange(location: at, length: 0))
        } else {
            tailKind = .paragraph
            let kindAttrs = NoteBuffer.typingAttributes(for: NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: para.location, effectiveRange: nil)))
            insertText(NSAttributedString(string: "\n", attributes: kindAttrs), replacementRange: sel)
        }
        refreshTailTypingAttributes()
    }

    override func insertBacktab(_ sender: Any?) {
        if selectedRange() == NSRange(location: 0, length: 0), let cb = onShiftTabAtStart { cb(); return }
        super.insertBacktab(sender)
    }

    // MARK: Paste

    /// Pasted rich text is reduced to plain text, as in the old editor.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}
