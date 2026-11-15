import AppKit
import NoteDocument

/// The new editor's text view: a native rich-text `NSTextView` whose buffer holds only visible
/// characters. It owns the note document and keeps it in step with the buffer after every edit.
///
/// Key handling is native except one structural rule: Enter at the end of a heading starts a
/// normal paragraph. Arrow keys, selection and clicks are not overridden.
final class NoteTextView: NSTextView, NSTextStorageDelegate {
    private(set) var document = NoteDocument(markdown: "")
    private var synced: [NoteBuffer.Paragraph] = []
    /// Kind of the tail paragraph while it has no characters (it has nothing to carry a kind).
    private var tailKind: BlockKind = .paragraph

    /// Called with the document's markdown after every edit made through the view.
    var onMarkdownChange: ((String) -> Void)?
    /// Called on Shift-Tab at offset 0.
    var onShiftTabAtStart: (() -> Void)?

    var markdown: String { document.markdown() }

    /// Block kinds in document order, e.g. ["h1", "p"].
    var blockKinds: [String] {
        document.blocks.map { b in
            switch b.kind {
            case .paragraph: return "p"
            case .heading(let level): return "h\(level)"
            case .bullet: return "bullet"
            case .numbered: return "numbered"
            case .checklist(let checked): return checked ? "checked" : "todo"
            case .quote: return "quote"
            case .divider: return "divider"
            }
        }
    }

    static func make() -> NoteTextView {
        let stack = NoteTextEngine.makeStack()
        let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 0), textContainer: stack.container)
        tv.configure()
        stack.storage.delegate = tv
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

    /// Replaces the whole note from markdown (note switch, reload). Not an undo step: history is cleared.
    func load(markdown: String) {
        document = NoteDocument(markdown: markdown)
        let (text, tail) = NoteBuffer.attributed(for: document)
        tailKind = tail
        synced = NoteBuffer.paragraphs(of: document)
        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.setAttributedString(text)
        storage.endEditing()
        normalizeStyle()
        setSelectedRange(NSRange(location: 0, length: 0))
        refreshTailTypingAttributes()
        undoManager?.removeAllActions()
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
        syncDocument()
        refreshTailTypingAttributes()
        onMarkdownChange?(document.markdown())
    }

    private func syncDocument() {
        guard let storage = textStorage else { return }
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
