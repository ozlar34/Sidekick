import AppKit
import NoteDocument

/// The new editor's text view: a native rich-text `NSTextView` whose buffer holds only visible
/// characters. It owns the note document and keeps it in step with the buffer after every edit.
///
/// Key handling is native except the structural rules: Enter (continue or end a list, a heading or quote
/// ends in a paragraph), Backspace at the start of a marked block (clears the kind, then joins the line above),
/// and a click on a drawn checkbox. Arrow keys, selection, word and line jumps and other clicks are not overridden.
final class NoteTextView: NSTextView, NSTextStorageDelegate, NSViewToolTipOwner {
    /// The note shown now: its storage, undo history and document. `attach` switches it.
    private(set) var content = NoteContent()
    var tailKind: BlockKind {
        get { content.tailKind }
        set { content.tailKind = newValue; NoteTextEngine.setTailKind(newValue, in: self) }
    }

    /// Called with the document's markdown after every edit made through the view.
    var onMarkdownChange: ((String) -> Void)?
    /// Called with what the toolbar shows (active styles, block kind) whenever the caret, the selection or the text changes.
    var onFormatStateChange: ((NoteFormatState) -> Void)?
    /// True while `attach` switches notes: SwiftUI is updating then, so the state is published right after.
    var formatStateSuspended = false
    /// The style chosen for the next typed text (an armed Cmd+B/I/U/..., or the plain text right after a typed-markdown
    /// conversion). It wins over the style of the characters before the caret, and lasts while the caret stays at `location`
    /// (any other selection drops it) and until one character is typed.
    var armedTyping: (location: Int, attributes: [NSAttributedString.Key: Any])?
    /// Called on Shift-Tab at offset 0.
    var onShiftTabAtStart: (() -> Void)?
    /// Opens the address of a link or pill on Cmd+click. Tests replace it; the app hands it to the system
    /// (every scheme passes, as in the old editor).
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

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
    func refreshNumberGutters(in range: NSRange?) {
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
        formatStateSuspended = true
        defer {
            formatStateSuspended = false
            DispatchQueue.main.async { [weak self] in self?.publishFormatState() }
        }
        content.savedSelection = selectedRange()
        armedTyping = nil
        content.storage.delegate = nil
        content = new
        pendingStyleRange = nil
        NoteTextEngine.show(new.storage, in: self)
        new.storage.delegate = self
        isEditable = new.isEditable
        refreshTableFit()
        NoteTextEngine.setTailKind(new.tailKind, in: self)
        refreshNumberGutters(in: nil)
        let length = new.storage.length
        let sel = new.savedSelection
        setSelectedRange(NSRange(location: min(sel.location, length), length: min(sel.length, max(0, length - sel.location))))
        refreshTailTypingAttributes()
        refreshHover()
    }

    /// Replaces the whole note from markdown (reload). Not an undo step: history is cleared.
    func load(markdown: String) {
        content.reload(markdown: markdown)
        NoteTextEngine.setTailKind(content.tailKind, in: self)
        refreshNumberGutters(in: nil)
        refreshTableFit()
        pendingStyleRange = nil
        setSelectedRange(NSRange(location: 0, length: 0))
        refreshTailTypingAttributes()
        refreshHover()
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
        refreshTableFit()
    }

    /// Fits the tables to the panel (attributes only, not an undo step).
    private func refreshTableFit() {
        guard let storage = textStorage, let tc = textContainer, storage.length > 0, tc.size.width > 0, tc.size.width < 100_000 else { return }
        storage.beginEditing()
        NoteBuffer.fitTables(storage, available: tc.size.width - 2 * tc.lineFragmentPadding)
        storage.endEditing()
    }

    /// Tab is the column separator of a table row, so it is not a character a cell can hold: it does nothing there.
    override func insertTab(_ sender: Any?) {
        if let (_, para) = paragraph(at: selectedRange().location), kind(of: para) == .table { return }
        super.insertTab(sender)
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
        refreshHover()
        onMarkdownChange?(content.markdown)
        publishFormatState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.width
        super.setFrameSize(newSize)
        if newSize.width != old { refreshTableFit() }
        refreshHover()
    }


    // MARK: Tail paragraph

    /// An empty tail paragraph has no character, so AppKit would hand it the previous paragraph's
    /// attributes (a heading's). Typing attributes there come from `tailKind` instead.
    func refreshTailTypingAttributes() {
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
        if let armed = armedTyping, selectedRange().length > 0 || selectedRange().location != armed.location { armedTyping = nil }
        refreshTailTypingAttributes()
        publishFormatState()
    }

    // MARK: Structural key rules

    func paragraph(at location: Int) -> (index: Int, range: NSRange)? {
        let ranges = NoteBuffer.paragraphRanges(in: string as NSString)
        guard let i = ranges.firstIndex(where: { $0.location <= location && location <= NSMaxRange($0) }) else { return nil }
        return (i, ranges[i])
    }

    /// Kind of a paragraph; the empty last one has no character to carry it.
    func kind(of para: NSRange) -> BlockKind {
        if para.length == 0 && para.location == (string as NSString).length { return tailKind }
        return NoteBuffer.kind(fromAttribute: textStorage?.attribute(.noteBlockKind, at: para.location, effectiveRange: nil))
    }

    func hasTerminator(_ para: NSRange) -> Bool { NSMaxRange(para) < (string as NSString).length }

    /// `range` of the buffer as text of block kind `kind` (marks stay; the line breaks carry the kind too).
    func slice(_ range: NSRange, as kind: BlockKind) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(attributedString: textStorage?.attributedSubstring(from: range) ?? NSAttributedString())
        out.addAttribute(.noteBlockKind, value: NoteBuffer.attributeValue(kind), range: NSRange(location: 0, length: out.length))
        return out
    }

    func lineBreak(_ kind: BlockKind) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.noteBlockKind: NoteBuffer.attributeValue(kind)])
    }

    /// One user-style edit: replaces `range` with `text` (one undo step) and puts the caret at `caret`.
    func replace(_ range: NSRange, with text: NSAttributedString, caret: Int) {
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Changes the kind of the empty last paragraph. It has no character, so its undo is registered by hand.
    func changeTailKind(_ new: BlockKind) {
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
    /// Enter at the end of a heading or quote starts a normal paragraph. Enter inside a code block adds a code line
    /// (a line break inside its paragraph, so it stays one block); inside a table it does nothing (rows are not
    /// edited here). Everywhere else Enter is native.
    override func insertNewline(_ sender: Any?) {
        completeURLBeforeEnter()
        let sel = selectedRange()
        if let (_, para) = paragraph(at: sel.location) {
            switch kind(of: para) {
            case .fence:
                insertText(NSAttributedString(string: "\u{2028}", attributes: NoteBuffer.typingAttributes(for: .fence)), replacementRange: sel)
                return
            case .table:
                return
            default: break
            }
        }
        if sel.length == 0, let (_, para) = paragraph(at: sel.location) {
            let k = kind(of: para)
            if k == .divider, hasTerminator(para) {   // on the rule's own line: a new plain line above it
                replace(NSRange(location: para.location, length: 0), with: lineBreak(.paragraph), caret: para.location + 1)
                return
            }
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
        if k == .divider, hasTerminator(para) { return removeDivider(para, caret: para.location) }   // caret on the rule's line
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
        if sel.length == 0, let (index, para) = paragraph(at: sel.location) {
            // Before a divider (end of the line above it, or on its own line) Delete removes the whole rule.
            if kind(of: para) == .divider, sel.location == para.location, hasTerminator(para) { return removeDivider(para, caret: para.location) }
            let ranges = NoteBuffer.paragraphRanges(in: string as NSString)
            if sel.location == NSMaxRange(para), hasTerminator(para), ranges.indices.contains(index + 1),
               kind(of: ranges[index + 1]) == .divider, hasTerminator(ranges[index + 1]) { return removeDivider(ranges[index + 1], caret: sel.location) }
        }
        guard sel.length == 0, let (index, para) = paragraph(at: sel.location), sel.location == NSMaxRange(para), hasTerminator(para),
              join(paragraphsEndingAt: index) else { return super.deleteForward(sender) }
    }

    /// A divider is one object: its line (an empty paragraph with its line break) goes as a unit, one undo step.
    private func removeDivider(_ para: NSRange, caret: Int) {
        replace(NSRange(location: para.location, length: 1), with: NSAttributedString(), caret: caret)
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

    // MARK: Links and pills: hover

    typealias HoverTarget = NoteTextEngine.HoverTarget

    /// Every link and pill with the rects it is drawn in. The cursor rects and tooltips come from this.
    var hoverTargets: [HoverTarget] { NoteTextEngine.hoverTargets(in: self) }

    /// The full address shown when the pointer rests on a link or pill at `point` (view coordinates).
    func toolTip(at point: NSPoint) -> String? { NoteTextEngine.address(in: self, at: point) }

    /// Pointing hand over a link or pill, the text cursor's default everywhere else (nil).
    func cursor(at point: NSPoint) -> NSCursor? { toolTip(at: point) == nil ? nil : .pointingHand }

    override func resetCursorRects() {
        super.resetCursorRects()
        removeAllToolTips()
        for target in NoteTextEngine.hoverTargets(in: self, visibleOnly: true) {
            for rect in target.rects {
                addCursorRect(rect, cursor: .pointingHand)
                addToolTip(rect, owner: self, userData: nil)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTip(at: point) ?? ""
    }

    private func refreshHover() { window?.invalidateCursorRects(for: self) }

    // MARK: Checkbox

    /// A click on a drawn checkbox toggles it (and does nothing else). Every other click is native.
    override func mouseDown(with event: NSEvent) {
        // Cmd+click opens a link or pill and leaves the caret alone; a plain click is native (it places the caret).
        if event.modifierFlags.contains(.command), let address = NoteTextEngine.address(in: self, at: convert(event.locationInWindow, from: nil)) {
            if let url = URL(string: address) { openURL(url) }
            return
        }
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

    // MARK: Typing next to objects, `/hr`

    /// Text typed on a divider's line replaces the rule: the line becomes a plain paragraph holding the text (undo brings the rule back).
    /// Text typed at the edge of a pill or a link is plain text: it never joins the address or the link.
    /// `/hr` or `/divider` alone on a plain line becomes a divider with a new line below.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // A table cell holds no tab and no row break: typed or pasted ones become blanks.
        let at = replacementRange.location == NSNotFound ? selectedRange().location : replacementRange.location
        if let (_, para) = paragraph(at: at), kind(of: para) == .table {
            func clean(_ s: String) -> String {
                String(s.unicodeScalars.map { $0 == "\t" || $0 == "\u{2028}" || $0 == "\n" || $0 == "\r" ? " " : Character($0) })
            }
            if let a = string as? NSAttributedString {
                let m = NSMutableAttributedString(attributedString: a)
                m.mutableString.setString(clean(a.string))
                return super.insertText(m, replacementRange: replacementRange)
            }
            if let t = string as? String { return super.insertText(clean(t), replacementRange: replacementRange) }
        }
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let isPlainText = string is String
        let sel = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if !typed.contains("\n"), sel.length == 0, let (_, para) = paragraph(at: sel.location), para.length == 0, kind(of: para) == .divider {
            replace(NSRange(location: para.location, length: 1), with: lineBreak(.paragraph), caret: para.location)
        }
        if isPlainText, sel.length == 0 {
            // An armed style (09, or the plain text right after a typed-markdown conversion) wins over what the characters
            // before the caret would give; pill and link still stay out of what is typed at their edge (08).
            if let armed = armedTyping, armed.location == sel.location { typingAttributes = typingAttributesAtEdge(of: sel.location, armed: armed.attributes) }
            else { typingAttributes = typingAttributesAtEdge(of: sel.location) }
        }
        armedTyping = nil
        let typedAttributes = typingAttributes
        super.insertText(string, replacementRange: replacementRange)
        guard !hasMarkedText() else { return }
        if convertSlashDividerIfTyped() { return }
        // One typed character can complete a typed-markdown trigger (`- `, `**x**`, a bare URL, ...).
        if isPlainText, sel.length == 0, typed.count == 1, let ch = typed.first { applyTypedMarkdown(typed: ch, typedAttributes: typedAttributes) }
    }

    /// The typing attributes at `location` without the pill or the link of the style they come from, unless the caret is
    /// inside that link (the characters on both sides carry it). They come from the characters before the caret, or from
    /// `armed` (the style chosen for the next text) when there is one.
    private func typingAttributesAtEdge(of location: Int, armed: [NSAttributedString.Key: Any]? = nil) -> [NSAttributedString.Key: Any] {
        var attrs = armed ?? typingAttributes
        guard location <= (string as NSString).length, let storage = textStorage else { return attrs }
        let before = location > 0 ? storage.attribute(.noteStyle, at: location - 1, effectiveRange: nil) as? NoteRunStyle : nil
        let after = location < storage.length ? storage.attribute(.noteStyle, at: location, effectiveRange: nil) as? NoteRunStyle : nil
        let source = armed == nil ? before : attrs[.noteStyle] as? NoteRunStyle
        guard let style = source else { return attrs }
        let insideLink = style.link != nil && before?.link == style.link && after?.link == style.link
        let rest = style.removing(pill: style.pill != nil, link: style.link != nil && !insideLink)
        if style.pill != nil { attrs.removeValue(forKey: .attachment) }
        if let rest { attrs[.noteStyle] = rest } else { attrs.removeValue(forKey: .noteStyle) }
        return attrs
    }

    /// The typed characters are their own undo step, so that Cmd+Z brings the literal text back.
    func splitUndoGroup() {
        if let um = undoManager, um.groupingLevel > 0 { um.endUndoGrouping(); um.beginUndoGrouping() }
    }

    /// True when it converted.
    private func convertSlashDividerIfTyped() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let (_, para) = paragraph(at: sel.location), sel.location == NSMaxRange(para), para.length > 0, kind(of: para) == .paragraph
        else { return false }
        let text = (string as NSString).substring(with: para)
        guard text == "/hr" || text == "/divider" else { return false }
        splitUndoGroup()
        registerCaretForUndo(at: sel.location)
        makeDivider(of: para)
        return true
    }

    /// The line becomes a divider with an empty plain line below it, where the caret goes.
    func makeDivider(of para: NSRange) {
        let whole = NSRange(location: para.location, length: para.length + (hasTerminator(para) ? 1 : 0))
        let out = NSMutableAttributedString()
        out.append(lineBreak(.divider))
        if hasTerminator(para) { out.append(lineBreak(.paragraph)) }
        replace(whole, with: out, caret: para.location + 1)
    }

    // MARK: Paste

    /// Pasted rich text is reduced to plain text, as in the old editor. A bare URL in the pasted text becomes a pill.
    override func paste(_ sender: Any?) {
        let start = selectedRange().location
        pasteAsPlainText(sender)
        convertPastedURLs(from: start, to: selectedRange().location)
    }
}
