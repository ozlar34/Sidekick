import AppKit
import NoteDocument

/// The new editor's text view: a native rich-text `NSTextView` whose buffer holds only visible
/// characters. It owns the note document and keeps it in step with the buffer after every edit.
///
/// Key handling is native except the structural rules: Enter (continue or end a list, a heading or quote
/// ends in a paragraph), Backspace at the start of a marked block (clears the kind, then joins the line above),
/// and a click on a drawn checkbox. Arrow keys, selection, word and line jumps and other clicks are not overridden.
final class NoteTextView: NSTextView, NSTextStorageDelegate {
    /// The note shown now: its storage, undo history and document. `attach` switches it.
    private(set) var content = NoteContent()
    private var tailKind: BlockKind {
        get { content.tailKind }
        set { content.tailKind = newValue; NoteTextEngine.setTailKind(newValue, in: self) }
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
            case .bullet: return "bullet"
            case .numbered: return "numbered"
            case .checklist(let checked): return checked ? "checked" : "todo"
            case .quote: return "quote"
            case .divider: return "divider"
            case .fence: return "code"
            case .table: return "table"
            }
        }
    }

    /// The number of the numbered block at a document index as the file spells it (`7.`, `3)`), for drawing the marker.
    fileprivate func literalMarker(ofBlock index: Int) -> String? {
        let blocks = document.blocks
        guard blocks.indices.contains(index) else { return nil }
        let rest = blocks[index].prefix.drop(while: { $0 == " " || $0 == "\t" })
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let delimiter = rest.dropFirst(digits.count).first else { return nil }
        return String(digits) + String(delimiter)
    }

    /// Gives every numbered paragraph in `range` (all when nil) the text indent its own number needs, so that `10.` and
    /// `100.` keep the gap of `9.`. Attributes only; derived from the document, so it is not an undo step.
    private func refreshNumberGutters(in range: NSRange?) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        var changes: [(NSRange, NSParagraphStyle)] = []
        for (i, para) in NoteBuffer.paragraphRanges(in: ns).enumerated() where para.location < ns.length {
            if let r = range, NSMaxRange(para) + 1 < r.location - 1 || para.location > NSMaxRange(r) + 1 { continue }
            guard NoteBuffer.kind(fromAttribute: storage.attribute(.noteBlockKind, at: para.location, effectiveRange: nil)) == .numbered,
                  let text = literalMarker(ofBlock: i) else { continue }
            let wanted = NoteBuffer.paragraphStyle(for: .numbered, numberText: text)
            let current = storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            if current?.firstLineHeadIndent != wanted.firstLineHeadIndent {
                changes.append((NSRange(location: para.location, length: min(para.length + 1, ns.length - para.location)), wanted))
            }
        }
        guard !changes.isEmpty else { return }
        storage.beginEditing()
        for (r, style) in changes { storage.addAttribute(.paragraphStyle, value: style, range: r) }
        storage.endEditing()
    }

    static func make() -> NoteTextView {
        let stack = NoteTextEngine.makeStack()
        let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 0), textContainer: stack.container)
        tv.configure()
        NoteTextEngine.configure(tv, tailKind: .paragraph) { [weak tv] index in tv?.literalMarker(ofBlock: index) }
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
        NoteTextEngine.show(new.storage, in: self)
        new.storage.delegate = self
        isEditable = new.isEditable
        NoteTextEngine.setTailKind(new.tailKind, in: self)
        refreshNumberGutters(in: nil)
        let length = new.storage.length
        let sel = new.savedSelection
        setSelectedRange(NSRange(location: min(sel.location, length), length: min(sel.length, max(0, length - sel.location))))
        refreshTailTypingAttributes()
    }

    /// Replaces the whole note from markdown (reload). Not an undo step: history is cleared.
    func load(markdown: String) {
        content.reload(markdown: markdown)
        NoteTextEngine.setTailKind(content.tailKind, in: self)
        refreshNumberGutters(in: nil)
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
        let edited = pendingStyleRange
        normalizeStyle()
        content.storageDidChange()
        refreshNumberGutters(in: edited)
        NoteTextEngine.setTailKind(content.tailKind, in: self)
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
        var attrs = NoteBuffer.typingAttributes(for: tailKind)
        if tailKind == .numbered {
            attrs[.paragraphStyle] = NoteBuffer.paragraphStyle(for: .numbered, numberText: literalMarker(ofBlock: NoteBuffer.paragraphRanges(in: ns).count - 1))
        }
        typingAttributes = attrs
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        refreshTailTypingAttributes()
    }

    // MARK: Structural key rules

    private func paragraph(at location: Int) -> (index: Int, range: NSRange)? {
        let ranges = NoteBuffer.paragraphRanges(in: string as NSString)
        guard let i = ranges.firstIndex(where: { $0.location <= location && location <= NSMaxRange($0) }) else { return nil }
        return (i, ranges[i])
    }

    /// Kind of a paragraph; the empty last one has no character to carry it.
    private func kind(of para: NSRange) -> BlockKind {
        if para.length == 0 && para.location == (string as NSString).length { return tailKind }
        return NoteBuffer.kind(fromAttribute: textStorage?.attribute(.noteBlockKind, at: para.location, effectiveRange: nil))
    }

    private func hasTerminator(_ para: NSRange) -> Bool { NSMaxRange(para) < (string as NSString).length }

    /// `range` of the buffer as text of block kind `kind` (marks stay; the line breaks carry the kind too).
    private func slice(_ range: NSRange, as kind: BlockKind) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(attributedString: textStorage?.attributedSubstring(from: range) ?? NSAttributedString())
        out.addAttribute(.noteBlockKind, value: NoteBuffer.attributeValue(kind), range: NSRange(location: 0, length: out.length))
        return out
    }

    private func lineBreak(_ kind: BlockKind) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.noteBlockKind: NoteBuffer.attributeValue(kind)])
    }

    /// One user-style edit: replaces `range` with `text` (one undo step) and puts the caret at `caret`.
    private func replace(_ range: NSRange, with text: NSAttributedString, caret: Int) {
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Changes the kind of the empty last paragraph. It has no character, so its undo is registered by hand.
    private func changeTailKind(_ new: BlockKind) {
        let old = tailKind
        guard old != new else { return }
        undoManager?.registerUndo(withTarget: self) { $0.changeTailKind(old) }
        tailKind = new
        content.storageDidChange()
        refreshTailTypingAttributes()
        onMarkdownChange?(content.markdown)
    }

    /// Kind of the item that follows an item of `kind` when Enter is pressed.
    private func continuation(of kind: BlockKind) -> BlockKind? {
        switch kind {
        case .bullet, .numbered: return kind
        case .checklist: return .checklist(checked: false)
        default: return nil
        }
    }

    /// Kinds whose Backspace-at-start rule is "clear the kind" (not paragraph, divider, code block or table).
    private func isMarked(_ kind: BlockKind) -> Bool {
        switch kind {
        case .heading, .bullet, .numbered, .checklist, .quote: return true
        default: return false
        }
    }

    private func isOneLineKind(_ kind: BlockKind) -> Bool { kind == .paragraph || isMarked(kind) }

    /// Enter in a list continues it (numbered: next number, checklist: unchecked) and on an empty item ends it.
    /// Enter at the end of a heading or quote starts a normal paragraph. Everywhere else Enter is native.
    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, let (_, para) = paragraph(at: sel.location) {
            let k = kind(of: para)
            if let next = continuation(of: k) {
                if para.length == 0 {   // empty item: end the list
                    if hasTerminator(para) {
                        replace(NSRange(location: para.location, length: 1), with: lineBreak(.paragraph), caret: para.location)
                    } else {
                        changeTailKind(.paragraph)
                    }
                    return
                }
                let whole = NSRange(location: para.location, length: para.length + (hasTerminator(para) ? 1 : 0))
                let left = slice(NSRange(location: para.location, length: sel.location - para.location), as: k)
                let right = slice(NSRange(location: sel.location, length: NSMaxRange(para) - sel.location), as: next)
                let out = NSMutableAttributedString()
                out.append(left); out.append(lineBreak(k)); out.append(right)
                if hasTerminator(para) { out.append(lineBreak(next)) }
                else if right.length == 0 { tailKind = next }
                replace(whole, with: out, caret: sel.location + 1)
                return
            }
            if k == .quote, para.length > 0, sel.location == NSMaxRange(para) {
                let whole = NSRange(location: para.location, length: para.length + (hasTerminator(para) ? 1 : 0))
                let out = NSMutableAttributedString()
                out.append(slice(para, as: k)); out.append(lineBreak(k))
                if hasTerminator(para) { out.append(lineBreak(.paragraph)) } else { tailKind = .paragraph }
                replace(whole, with: out, caret: sel.location + 1)
                return
            }
        }
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

    /// Backspace at the start of a marked block removes the kind and keeps the text; at the start of a
    /// plain line under a marked one it joins the line, which keeps the kind of the line above.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, let (index, para) = paragraph(at: sel.location), sel.location == para.location else {
            return super.deleteBackward(sender)
        }
        let k = kind(of: para)
        if isMarked(k) {
            if hasTerminator(para) {
                let whole = NSRange(location: para.location, length: para.length + 1)
                replace(whole, with: slice(whole, as: .paragraph), caret: sel.location)
            } else if para.length > 0 {
                replace(para, with: slice(para, as: .paragraph), caret: sel.location)
            } else {
                changeTailKind(.paragraph)
            }
            return
        }
        guard index > 0, join(paragraphsEndingAt: index - 1) else { return super.deleteBackward(sender) }
    }

    /// Delete at the end of a line joins the next one into it, keeping the kind of this line.
    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, let (index, para) = paragraph(at: sel.location), sel.location == NSMaxRange(para), hasTerminator(para),
              join(paragraphsEndingAt: index) else { return super.deleteForward(sender) }
    }

    /// Joins paragraph `left` with the one below it; the result keeps the kind of `left` (as `NoteDocument` does).
    /// False when the native join already gives that (same kind) or a divider is involved.
    private func join(paragraphsEndingAt left: Int) -> Bool {
        let ranges = NoteBuffer.paragraphRanges(in: string as NSString)
        guard ranges.indices.contains(left + 1) else { return false }
        let a = ranges[left], b = ranges[left + 1]
        let ka = kind(of: a), kb = kind(of: b)
        guard ka != kb, isOneLineKind(ka), isOneLineKind(kb) else { return false }
        let end = NSMaxRange(b) + (hasTerminator(b) ? 1 : 0)
        let out = NSMutableAttributedString()
        out.append(slice(a, as: ka)); out.append(slice(b, as: ka))
        if hasTerminator(b) { out.append(lineBreak(ka)) } else { tailKind = ka }
        replace(NSRange(location: a.location, length: end - a.location), with: out, caret: NSMaxRange(a))
        return true
    }

    // MARK: Checkbox

    /// A click on a drawn checkbox toggles it (and does nothing else). Every other click is native.
    override func mouseDown(with event: NSEvent) {
        if isEditable, let hit = NoteTextEngine.checkbox(in: self, at: convert(event.locationInWindow, from: nil)) {
            toggleCheckbox(at: hit.start, checked: hit.checked)
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at start: Int, checked: Bool) {
        let new = BlockKind.checklist(checked: !checked)
        guard let (_, para) = paragraph(at: start) else { return }
        if para.length == 0 && !hasTerminator(para) { return changeTailKind(new) }
        let sel = selectedRange()
        let whole = NSRange(location: para.location, length: para.length + (hasTerminator(para) ? 1 : 0))
        replace(whole, with: slice(whole, as: new), caret: sel.location)
        setSelectedRange(sel)
    }

    override func insertBacktab(_ sender: Any?) {
        if selectedRange() == NSRange(location: 0, length: 0), let cb = onShiftTabAtStart { cb(); return }
        super.insertBacktab(sender)
    }

    // MARK: Paste

    /// Pasted rich text is reduced to plain text, as in the old editor.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}
