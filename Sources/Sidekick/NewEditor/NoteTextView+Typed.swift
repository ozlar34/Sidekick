import AppKit
import NoteDocument

/// Typed markdown in the new editor: the rule table lives in the note document module (`TypedMarkdown`); this file
/// reads the caret's paragraph from the buffer, asks the table, and applies the answer as ONE undo step of its own, so
/// that Cmd+Z right after a conversion gives back the characters as typed. Those stay literal: a trigger fires only
/// when the character just typed completes it, and the document writes literal text escaped.
///
/// Nothing converts in a code block, a table or on a divider (the rule table refuses those kinds), nor in inline code.
extension NoteTextView {
    /// The caret's paragraph as the note document would see it.
    private func model(of para: NSRange) -> NoteBuffer.Paragraph? {
        guard let storage = textStorage else { return nil }
        let whole = NSRange(location: para.location, length: para.length + (hasTerminator(para) ? 1 : 0))
        return NoteBuffer.paragraphs(in: storage.attributedSubstring(from: whole), tailKind: tailKind).first
    }

    /// Visible-text offset (a pill counts as its address) of buffer position `location` inside `para`.
    private func runOffset(of location: Int, in para: NSRange) -> Int {
        guard let storage = textStorage else { return location - para.location }
        var n = 0
        for i in para.location..<location {
            if storage.attribute(.attachment, at: i, effectiveRange: nil) != nil,
               let address = (storage.attribute(.noteStyle, at: i, effectiveRange: nil) as? NoteRunStyle)?.pillText { n += address.utf16.count }
            else { n += 1 }
        }
        return n
    }

    /// Buffer length of the first `offset` visible-text units of `runs` (a pill is one character).
    private func bufferLength(of offset: Int, in runs: [Run]) -> Int {
        var left = offset, n = 0
        for r in runs where left > 0 {
            let len = r.text.utf16.count
            if r.pill != nil { n += 1; left -= len; continue }
            let take = min(left, len)
            n += take; left -= take
        }
        return n
    }

    /// Called after a single plain character was typed.
    func applyTypedMarkdown(typed ch: Character, typedAttributes: [NSAttributedString.Key: Any]) {
        let sel = selectedRange()
        guard sel.length == 0, let (index, para) = paragraph(at: sel.location), para.length > 0, let m = model(of: para),
              let c = TypedMarkdown.convert(kind: m.kind, runs: m.runs, caret: runOffset(of: sel.location, in: para), typed: ch) else { return }
        apply(c, to: para, index: index, typedAttributes: typedAttributes)
    }

    /// Enter completes a bare URL at the end of a line (its own undo step, before the Enter's).
    func completeURLBeforeEnter() {
        let sel = selectedRange()
        guard sel.length == 0, let (index, para) = paragraph(at: sel.location), para.length > 0, sel.location == NSMaxRange(para),
              let m = model(of: para),
              let c = TypedMarkdown.convert(kind: m.kind, runs: m.runs, caret: runOffset(of: sel.location, in: para), typed: "\n") else { return }
        apply(c, to: para, index: index, typedAttributes: typingAttributes)
        splitUndoGroup()
    }

    /// Cmd+Z of a conversion puts the caret after the characters as typed. AppKit would select them (typing would then replace
    /// them), so the caret goes back through an undo action registered BEFORE the edit, which therefore runs after it.
    func registerCaretForUndo(at location: Int) {
        undoManager?.registerUndo(withTarget: self) { tv in
            let length = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(location, length), length: 0))
        }
    }

    private func apply(_ c: TypedConversion, to para: NSRange, index: Int, typedAttributes: [NSAttributedString.Key: Any]) {
        splitUndoGroup()
        registerCaretForUndo(at: selectedRange().location)
        let terminated = hasTerminator(para)
        let whole = NSRange(location: para.location, length: para.length + (terminated ? 1 : 0))
        switch c.kind {
        case .divider:
            makeDivider(of: para)
            return
        case .fence:
            // The code block is one empty line; a plain line stays below it (the end of a note has one to leave by).
            replace(whole, with: lineBreak(.fence), caret: para.location)
            return
        default: break
        }
        var pillID = 1
        let out = NoteBuffer.attributedRuns(c.runs, kind: c.kind, pillID: &pillID)
        if terminated { out.append(lineBreak(c.kind)) } else if out.length == 0 { tailKind = c.kind }
        replace(whole, with: out, caret: para.location + bufferLength(of: c.caret, in: c.runs))
        if let n = c.number {
            content.setNumber(n, ofBlock: index)
            refreshNumberGutters(in: nil)
            needsDisplay = true
            onMarkdownChange?(content.markdown)
        }
        // What was armed for the typed text (09) stays armed for the next one.
        var attrs = typingAttributes
        for key in [NSAttributedString.Key.noteBold, .noteStyle] {
            if let v = typedAttributes[key] { attrs[key] = v } else { attrs.removeValue(forKey: key) }
        }
        attrs.removeValue(forKey: .attachment)
        typingAttributes = attrs
        plainAfterConversion = (selectedRange().location, attrs)
        publishFormatState()
    }

    /// Makes a pill of every bare URL that the pasted text (buffer range `from..<to`) touches, as one undo step.
    func convertPastedURLs(from: Int, to: Int) {
        guard to > from else { return }
        let ns = string as NSString
        var firstDone = false
        var caret = to
        // First to last paragraph: a replaced paragraph shifts what follows it, so ranges are read again each time.
        for i in 0..<NoteBuffer.paragraphRanges(in: ns).count {
            let ranges = NoteBuffer.paragraphRanges(in: string as NSString)
            guard ranges.indices.contains(i) else { break }
            let para = ranges[i]
            guard para.length > 0, para.location < caret, NSMaxRange(para) >= from, let m = model(of: para) else { continue }
            let lo = runOffset(of: max(from, para.location), in: para)
            let hi = runOffset(of: min(caret, NSMaxRange(para)), in: para)
            guard let runs = TypedMarkdown.pills(kind: m.kind, runs: m.runs, overlapping: lo..<max(hi, lo + 1)) else { continue }
            if !firstDone { splitUndoGroup(); firstDone = true }
            var pillID = 1
            let out = NoteBuffer.attributedRuns(runs, kind: m.kind, pillID: &pillID)
            let before = para.length
            if hasTerminator(para) { out.append(lineBreak(m.kind)) }
            let whole = NSRange(location: para.location, length: para.length + (hasTerminator(para) ? 1 : 0))
            // The caret keeps its place in the text: what is left of it is shortened by the pills before it.
            let newCaret = caret >= para.location && caret <= NSMaxRange(para)
                ? para.location + bufferLength(of: runOffset(of: caret, in: para), in: runs)
                : caret - before + (out.length - (hasTerminator(para) ? 1 : 0))
            replace(whole, with: out, caret: newCaret)
            caret = newCaret
        }
    }
}
