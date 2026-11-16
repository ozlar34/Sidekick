import AppKit
import NoteDocument

/// Copy, cut, paste and drag and drop. The clipboard holds plain markdown text only, as the old editor's did: copy
/// writes the markdown of the selection, paste reads markdown (through the note document's reader) and turns it into
/// formatted content at the caret. Rich text from other apps is reduced to its plain text first.
extension NoteTextView {

    // MARK: Copy and cut

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0, types.contains(.string) else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(markdown(of: range), forType: .string)
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        writeSelection(to: pboard, types: [type])
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        clipboard.clearContents()
        clipboard.setString(markdown(of: range), forType: .string)
    }

    /// Copy, then delete the selection as one undo step.
    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange().length > 0 else { return }
        copy(sender)
        delete(sender)
    }

    /// The markdown text of buffer range `range`. Blocks that the selection holds whole are written exactly as the
    /// document writes them (their literal spellings). A block that it holds in part gives its selected text with its
    /// marks: a selection that starts inside a block drops the block's kind (a heading's `#`), one that starts at its
    /// start keeps it. Inside a code block or a table the text is as written.
    func markdown(of range: NSRange) -> String {
        guard range.length > 0, let storage = textStorage else { return "" }
        let ns = storage.string as NSString
        let end = NSMaxRange(range)
        let blocks = document.blocks
        var out = ""
        var whole: Range<Int>?
        func flush() { if let r = whole { out += document.markdown(blocks: r); whole = nil } }
        var lastHadTerminator = false
        for (i, para) in NoteBuffer.paragraphRanges(in: ns).enumerated() {
            let textEnd = NSMaxRange(para)
            guard para.location < end, textEnd >= range.location else { continue }
            let terminated = textEnd < ns.length && end > textEnd
            lastHadTerminator = terminated
            let kind = self.kind(of: para)
            if range.location <= para.location, end >= textEnd, blocks.indices.contains(i), blocks[i].kind == kind {
                whole = whole.map { $0.lowerBound..<(i + 1) } ?? i..<(i + 1)
                continue
            }
            flush()
            let part = NSRange(location: max(range.location, para.location), length: min(end, textEnd) - max(range.location, para.location))
            switch kind {
            case .fence, .table:
                out += ns.substring(with: part).replacingOccurrences(of: "\u{2028}", with: "\n")
            default:
                let kept = range.location <= para.location ? kind : .paragraph
                out += NoteDocument.markdown(kind: kept, runs: markRuns(in: part))
            }
            if terminated { out += "\n" }
        }
        flush()
        // A block held whole always brings its own line ending: keep it only when the selection took the line break.
        let hasLineEnding = out.hasSuffix("\n")
        if hasLineEnding, !lastHadTerminator { out.removeLast(); if out.hasSuffix("\r") { out.removeLast() } }
        else if !hasLineEnding, lastHadTerminator { out += "\n" }
        return out
    }

    /// The runs (text with marks) of a buffer range inside one paragraph.
    private func markRuns(in range: NSRange) -> [Run] {
        guard range.length > 0, let storage = textStorage else { return [] }
        return NoteBuffer.paragraphs(in: storage.attributedSubstring(from: range), tailKind: .paragraph).first?.runs ?? []
    }

    // MARK: Paste

    override func paste(_ sender: Any?) { pasteFromClipboard() }
    override func pasteAsPlainText(_ sender: Any?) { pasteFromClipboard() }
    override func pasteAsRichText(_ sender: Any?) { pasteFromClipboard() }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { read(pboard) }
    override func readSelection(from pboard: NSPasteboard) -> Bool { read(pboard) }

    private func pasteFromClipboard() { _ = read(clipboard) }

    private func read(_ pboard: NSPasteboard) -> Bool {
        guard isEditable, let text = Self.plainText(from: pboard) else { return false }
        return insertMarkdown(text, replacing: selectedRange()) != nil
    }

    /// The plain text on a pasteboard: its text, else the text of its rich text. The object character is the buffer's
    /// pill, so a text attachment of rich text must not bring one.
    static func plainText(from pboard: NSPasteboard) -> String? {
        var text = pboard.string(forType: .string)
        if text == nil {
            for (type, documentType) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
                                         (.rtfd, .rtfd), (.html, .html)] {
                guard let data = pboard.data(forType: type),
                      let rich = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil) else { continue }
                text = rich.string
                break
            }
        }
        return text?.replacingOccurrences(of: String(NotePillAttachment.objectCharacter), with: "")
    }

    private func mergeable(_ kind: BlockKind) -> Bool {
        switch kind {
        case .paragraph, .heading, .bullet, .numbered, .checklist, .quote: return true
        case .divider, .fence, .table: return false
        }
    }

    private func bufferLength(ofRuns runs: [Run]) -> Int { runs.reduce(0) { $0 + ($1.pill != nil ? 1 : $1.text.utf16.count) } }

    /// Replaces `range` with markdown `raw` read as blocks, as one undo step; the caret goes after it. Returns the range
    /// the pasted content takes, or nil when nothing was pasted.
    ///
    /// Inside a code block the text goes in literally; inside a table cell it goes through the cell's own cleaning.
    /// Elsewhere plain lines join the line they touch (inline marks stay), and a block that is not a plain line
    /// (heading, list item, quote, divider, code block, table) is a line of its own; what follows the pasted text
    /// stays after it, joining its last line.
    @discardableResult
    func insertMarkdown(_ raw: String, replacing range: NSRange) -> NSRange? {
        guard isEditable, !raw.isEmpty, let (_, startPara) = paragraph(at: range.location), let (_, endPara) = paragraph(at: NSMaxRange(range))
        else { return nil }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let startKind = kind(of: startPara)
        if startKind == .fence || startKind == .table {
            // A cell takes the lines as one text: a line break at the end (copied whole lines) would leave a blank in it.
            var cell = text
            while cell.hasSuffix("\n") { cell.removeLast() }
            let literal = startKind == .fence ? text.replacingOccurrences(of: "\n", with: "\u{2028}") : cell
            insertText(NSAttributedString(string: literal, attributes: NoteBuffer.typingAttributes(for: startKind)), replacementRange: range)
            return NSRange(location: range.location, length: max(0, selectedRange().location - range.location))
        }

        struct Piece { var kind: BlockKind; var runs: [Run] }
        let read = NoteDocument(markdown: text)
        var pieces = read.blocks.map { Piece(kind: $0.kind, runs: $0.runs) }
        content.pastedSources = read.blocks.indices.map { i in
            var source = read.markdown(blocks: i..<(i + 1))
            if source.hasSuffix("\n") { source.removeLast() }
            return (read.blocks[i].kind, read.blocks[i].runs, source)
        }
        defer { content.pastedSources = [] }
        if text.hasSuffix("\n") { pieces.append(Piece(kind: .paragraph, runs: [])) }
        guard !pieces.isEmpty else { return nil }

        let left = markRuns(in: NSRange(location: startPara.location, length: range.location - startPara.location))
        let right = markRuns(in: NSRange(location: NSMaxRange(range), length: NSMaxRange(endPara) - NSMaxRange(range)))
        let endKind = kind(of: endPara)
        var done: [Piece] = []
        var pending = Piece(kind: startKind == .divider ? .paragraph : startKind, runs: left)   // a divider's line holds no text
        for (n, piece) in pieces.enumerated() {
            if n == 0 {
                if piece.kind == .paragraph { pending.runs += piece.runs }
                else if left.isEmpty { pending = piece }
                else { done.append(pending); pending = piece }
            } else {
                done.append(pending); pending = piece
            }
        }
        let caretOffset = done.reduce(0) { $0 + bufferLength(ofRuns: $1.runs) + 1 } + bufferLength(ofRuns: pending.runs)
        if !right.isEmpty {
            if mergeable(pending.kind) { pending.runs += right }
            else { done.append(pending); pending = Piece(kind: endKind, runs: right) }
        }
        let terminated = hasTerminator(endPara)
        // The last line of the note has no line break after it; a rule, a code block or a table cannot be that empty line.
        if !terminated, pending.runs.isEmpty, !mergeable(pending.kind) {
            done.append(pending); pending = Piece(kind: .paragraph, runs: [])
        }
        let out = NSMutableAttributedString()
        var pillID = 1
        for piece in done {
            out.append(NoteBuffer.attributedRuns(piece.runs, kind: piece.kind, pillID: &pillID))
            out.append(lineBreak(piece.kind))
        }
        out.append(NoteBuffer.attributedRuns(pending.runs, kind: pending.kind, pillID: &pillID))
        if terminated { out.append(lineBreak(pending.kind)) }
        else {
            // The kind of an empty last line is not in the buffer: its change is its own undo registration.
            let newTail = pending.runs.isEmpty ? pending.kind : .paragraph
            let oldTail = tailKind
            if newTail != oldTail { undoManager?.registerUndo(withTarget: self) { $0.changeTailKind(oldTail) }; tailKind = newTail }
        }
        let whole = NSRange(location: startPara.location, length: NSMaxRange(endPara) + (terminated ? 1 : 0) - startPara.location)
        let caret = whole.location + caretOffset
        replace(whole, with: out, caret: caret)
        return NSRange(location: range.location, length: max(0, caret - range.location))
    }

    // MARK: Drag and drop

    /// A drop inside the editor moves (or, with Option, copies) the dragged text; it arrives as markdown, so it keeps
    /// its formatting. Move and drop are one undo step. A drop from another app is pasted at the drop point.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, let text = Self.plainText(from: sender.draggingPasteboard) else { return false }
        let drop = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        guard (sender.draggingSource as? NoteTextView) === self else {
            guard let placed = insertMarkdown(text, replacing: NSRange(location: drop, length: 0)) else { return false }
            setSelectedRange(placed)
            return true
        }
        dragSourceHandled = true
        let source = selectedRange()
        if source.length > 0, drop >= source.location, drop <= NSMaxRange(source) { return true }   // dropped on itself
        let moves = sender.draggingSourceOperationMask.contains(.move) && !NSEvent.modifierFlags.contains(.option)
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        var at = drop
        if moves, source.length > 0 {
            replace(source, with: NSAttributedString(), caret: source.location)
            if drop > source.location { at -= source.length }
        }
        guard let placed = insertMarkdown(text, replacing: NSRange(location: at, length: 0)) else { return false }
        setSelectedRange(placed)
        return true
    }

    /// The move was done at the drop (as one step with the insertion), so the end of the drag must not delete the source again.
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if dragSourceHandled { dragSourceHandled = false; return }
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }
}
