import AppKit
import NoteDocument

/// A format command of the new editor (menu, toolbar popover, checklist button, shortcut).
enum NoteFormatCommand: Equatable {
    case bold, italic, underline, strikethrough, code
    case bullet, numbered, quote, checklist
    /// A heading level (1...3), or nil for body.
    case heading(Int?)
    case rule
}

/// What the toolbar and menu show for the caret: the active inline styles and the block kind of its line.
struct NoteFormatState: Equatable {
    var inline: Set<FormattingToolbarView.InlineKind> = []
    var heading: Int?
    var block: FormattingToolbarView.LinePrefix?
}

/// The format commands act on the note's buffer, never on marker characters: an inline command changes the mark
/// attributes of the selected text (or the typing style), a block command changes the block kind of the touched
/// lines, the rule inserts a divider line. Each one is a single replace through the view's change notifications, so it
/// is one undo step, and the note document follows from the buffer as for any other edit (an unedited block keeps its
/// bytes, an edited one its remembered forms, a new one the defaults).
///
/// Nothing happens in a code block, a table or on a divider: those lines hold no marks and have a fixed kind.
extension NoteTextView {
    func perform(_ command: NoteFormatCommand) {
        guard isEditable else { return }
        switch command {
        case .bold: toggleInline(.bold)
        case .italic: toggleInline(.italic)
        case .underline: toggleInline(.underline)
        case .strikethrough: toggleInline(.strikethrough)
        case .code: toggleInline(.code)
        case .rule: insertRule()
        case .bullet, .numbered, .quote, .checklist, .heading: changeBlockKinds(command)
        }
    }

    // MARK: Inline marks

    func holdsMarks(_ kind: BlockKind) -> Bool {
        switch kind {
        case .fence, .table, .divider: return false
        default: return true
        }
    }

    func run(_ attrs: [NSAttributedString.Key: Any]) -> Run {
        var r = Run("")
        r.bold = (attrs[.noteBold] as? String).flatMap(BoldDelimiter.init(rawValue:))
        if let s = attrs[.noteStyle] as? NoteRunStyle {
            r.italic = s.italic; r.underline = s.underline; r.strikethrough = s.strikethrough; r.code = s.code; r.link = s.link
        }
        return r
    }

    func write(_ r: Run, into attrs: inout [NSAttributedString.Key: Any]) {
        if let d = r.bold { attrs[.noteBold] = d.rawValue } else { attrs.removeValue(forKey: .noteBold) }
        if let style = NoteRunStyle(r, pillID: 0) { attrs[.noteStyle] = style } else { attrs.removeValue(forKey: .noteStyle) }
    }

    private func has(_ mark: Mark, _ r: Run) -> Bool {
        switch mark {
        case .bold: return r.bold != nil
        case .italic: return r.italic != nil
        case .underline: return r.underline
        case .strikethrough: return r.strikethrough
        case .code: return r.code
        case .link: return r.link != nil
        }
    }

    /// `r` with `mark` set or cleared. Bold, italic and code exclude each other (setting one swaps
    /// the other out); code also drops every other mark. Underline and strikethrough stack with the rest.
    private func toggled(_ r: Run, _ mark: Mark, on: Bool, bold: BoldDelimiter, italic: ItalicDelimiter) -> Run {
        var r = r
        if on {
            switch mark {
            case .bold: r.italic = nil; r.code = false
            case .italic: r.bold = nil; r.code = false
            default: break
            }
        }
        return r.applying(mark, setting: on, bold: bold, italic: italic)
    }

    /// The delimiters a newly marked run of the paragraph takes: the ones its other runs already use, else the defaults.
    private func delimiters(in para: NSRange) -> (BoldDelimiter, ItalicDelimiter) {
        var bold = BoldDelimiter.asterisks, italic = ItalicDelimiter.asterisk
        var foundBold = false, foundItalic = false
        textStorage?.enumerateAttributes(in: para, options: []) { attrs, _, stop in
            if !foundBold, let d = (attrs[.noteBold] as? String).flatMap(BoldDelimiter.init(rawValue:)) { bold = d; foundBold = true }
            if !foundItalic, let d = (attrs[.noteStyle] as? NoteRunStyle)?.italic { italic = d; foundItalic = true }
            if foundBold && foundItalic { stop.pointee = true }
        }
        return (bold, italic)
    }

    private func toggleInline(_ mark: Mark) {
        let sel = selectedRange()
        guard let storage = textStorage else { return }
        let ranges = NoteBuffer.paragraphRanges(in: string as NSString)
        if sel.length == 0 {
            // No selection: the style of the next typed text. It lasts until the caret moves.
            guard let (_, para) = paragraph(at: sel.location), holdsMarks(kind(of: para)) else { return }
            var attrs = typingAttributes
            attrs.removeValue(forKey: .attachment)
            let (bold, italic) = delimiters(in: para)
            var r = run(attrs)
            r = toggled(r, mark, on: !has(mark, r), bold: bold, italic: italic)
            write(r, into: &attrs)
            typingAttributes = attrs
            armedTyping = (sel.location, attrs)
            publishFormatState()
            return
        }
        // The text to mark: the selection within every paragraph that holds marks, pills left out (a pill is an address).
        var pieces: [(range: NSRange, para: NSRange, run: Run)] = []
        for para in ranges {
            let part = NSIntersectionRange(para, sel)
            guard part.length > 0, holdsMarks(kind(of: para)) else { continue }
            storage.enumerateAttributes(in: part, options: []) { attrs, range, _ in
                if attrs[.attachment] == nil { pieces.append((range, para, self.run(attrs))) }
            }
        }
        guard let first = pieces.first, let last = pieces.last else { return }
        let on = !pieces.allSatisfy { has(mark, $0.run) }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let out = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: span))
        var cache: [Int: (BoldDelimiter, ItalicDelimiter)] = [:]
        for piece in pieces {
            let d = cache[piece.para.location] ?? delimiters(in: piece.para)
            cache[piece.para.location] = d
            var attrs = storage.attributes(at: piece.range.location, effectiveRange: nil)
            write(toggled(piece.run, mark, on: on, bold: d.0, italic: d.1), into: &attrs)
            for key in [NSAttributedString.Key.noteBold, .noteStyle] {
                let local = NSRange(location: piece.range.location - span.location, length: piece.range.length)
                if let v = attrs[key] { out.addAttribute(key, value: v, range: local) } else { out.removeAttribute(key, range: local) }
            }
        }
        guard !out.isEqual(to: storage.attributedSubstring(from: span)) else { return }
        replace(span, with: out, caret: NSMaxRange(sel))
        setSelectedRange(sel)
    }

    // MARK: Block kinds

    private func changeBlockKinds(_ command: NoteFormatCommand) {
        let all = NoteBuffer.paragraphRanges(in: string as NSString)
        let sel = selectedRange()
        let end = sel.length > 0 ? NSMaxRange(sel) - 1 : sel.location
        let touched = all.indices.filter { all[$0].location <= end && NSMaxRange(all[$0]) >= sel.location }
        guard let firstIndex = touched.first, let lastIndex = touched.last else { return }
        let kinds = touched.map { kind(of: all[$0]) }
        let changeable = touched.indices.filter { holdsMarks(kinds[$0]) }
        guard !changeable.isEmpty else { return }

        func isTarget(_ k: BlockKind) -> Bool {
            switch command {
            case .bullet: return k == .bullet
            case .numbered: return k == .numbered
            case .quote: return k == .quote
            case .checklist: if case .checklist = k { return true } else { return false }
            case .heading(let level): return level != nil && k == .heading(level: level!)
            default: return false
            }
        }
        let target: BlockKind
        switch command {
        case .bullet: target = .bullet
        case .numbered: target = .numbered
        case .quote: target = .quote
        case .checklist: target = .checklist(checked: false)
        case .heading(let level): target = level.map { .heading(level: $0) } ?? .paragraph
        default: return
        }

        var new = kinds
        if command == .heading(nil) {
            // Body only strips a heading.
            for i in changeable { if case .heading = kinds[i] { new[i] = .paragraph } }
        } else {
            // An empty plain line does not count for the toggle check (it has no prefix to have), but takes the kind.
            let counted = changeable.filter { !(all[touched[$0]].length == 0 && kinds[$0] == .paragraph) }
            if !counted.isEmpty && counted.allSatisfy({ isTarget(kinds[$0]) }) {
                for i in changeable where isTarget(kinds[i]) { new[i] = .paragraph }
            } else {
                for i in changeable { new[i] = isTarget(kinds[i]) ? kinds[i] : target }
            }
        }
        guard new != kinds else { return }

        let first = all[firstIndex], lastPara = all[lastIndex]
        let end2 = NSMaxRange(lastPara) + (hasTerminator(lastPara) ? 1 : 0)
        let out = NSMutableAttributedString()
        for (j, index) in touched.enumerated() {
            let para = all[index]
            let whole = NSRange(location: para.location, length: para.length + (hasTerminator(para) ? 1 : 0))
            guard whole.length > 0 else { continue }
            out.append(new[j] == kinds[j] ? (textStorage?.attributedSubstring(from: whole) ?? NSAttributedString()) : slice(whole, as: new[j]))
        }
        if out.length > 0 { replace(NSRange(location: first.location, length: end2 - first.location), with: out, caret: sel.location) }
        // The empty last line has no character to carry a kind.
        if lastPara.length == 0 && !hasTerminator(lastPara), let j = touched.indices.last, new[j] != kinds[j] { changeTailKind(new[j]) }
        // A numbered list over lines that were numbered already is numbered from 1 again (decided by Oguz).
        if command == .numbered, changeable.contains(where: { new[$0] == .numbered }) {
            content.renumber(blocks: changeable.filter { new[$0] == .numbered }.map { touched[$0] })
            onMarkdownChange?(content.markdown)
        }
        setSelectedRange(sel)
    }

    // MARK: Horizontal rule

    /// A divider line below the caret's line, and an empty plain line below it with the caret. An empty plain line becomes
    /// the divider itself.
    private func insertRule() {
        let sel = selectedRange()
        guard let (_, para) = paragraph(at: sel.length > 0 ? NSMaxRange(sel) - 1 : sel.location) else { return }
        let k = kind(of: para)
        guard k != .fence, k != .table else { return }
        let below = NSMutableAttributedString()
        below.append(lineBreak(.divider))
        if para.length == 0 && k == .paragraph {
            if hasTerminator(para) {
                below.append(lineBreak(.paragraph))
                replace(NSRange(location: para.location, length: 1), with: below, caret: para.location + 1)
            } else {
                replace(NSRange(location: para.location, length: 0), with: below, caret: para.location + 1)
            }
        } else if hasTerminator(para) {
            let at = NSMaxRange(para) + 1
            below.append(lineBreak(.paragraph))
            replace(NSRange(location: at, length: 0), with: below, caret: at + 1)
        } else {
            let at = NSMaxRange(para)
            let out = NSMutableAttributedString()
            out.append(lineBreak(k)); out.append(below)
            tailKind = .paragraph
            replace(NSRange(location: at, length: 0), with: out, caret: at + 2)
        }
    }

    // MARK: State for the toolbar and menu

    private static func inlineKinds(of r: Run) -> Set<FormattingToolbarView.InlineKind> {
        var kinds: Set<FormattingToolbarView.InlineKind> = []
        if r.bold != nil { kinds.insert(.bold) }
        if r.italic != nil { kinds.insert(.italic) }
        if r.underline { kinds.insert(.underline) }
        if r.strikethrough { kinds.insert(.strikethrough) }
        if r.code { kinds.insert(.code) }
        return kinds
    }

    /// The active inline styles (an empty selection: the typing style, so an armed style shows at once; a selection: what
    /// all of its text has) and the block kind of the line the selection starts in.
    var formatState: NoteFormatState {
        var state = NoteFormatState()
        let sel = selectedRange()
        guard let storage = textStorage else { return state }
        let ranges = NoteBuffer.paragraphRanges(in: string as NSString)
        if let (_, para) = paragraph(at: sel.location) {
            switch kind(of: para) {
            case .heading(let level): state.heading = min(3, level)
            case .bullet: state.block = .bullet
            case .numbered: state.block = .numbered
            case .checklist: state.block = .checklist
            case .quote: state.block = .blockquote
            default: break
            }
            if sel.length == 0, holdsMarks(kind(of: para)) {
                var attrs = typingAttributes
                attrs.removeValue(forKey: .attachment)
                state.inline = Self.inlineKinds(of: run(attrs))
            }
        }
        if sel.length > 0 {
            var common: Set<FormattingToolbarView.InlineKind>?
            for para in ranges {
                let part = NSIntersectionRange(para, sel)
                guard part.length > 0, holdsMarks(kind(of: para)) else { continue }
                storage.enumerateAttributes(in: part, options: []) { attrs, _, _ in
                    guard attrs[.attachment] == nil else { return }
                    let kinds = Self.inlineKinds(of: self.run(attrs))
                    common = common.map { $0.intersection(kinds) } ?? kinds
                }
            }
            state.inline = common ?? []
        }
        return state
    }

    func publishFormatState() {
        guard let report = onFormatStateChange, !formatStateSuspended else { return }
        report(formatState)
    }

    /// Hands what the toolbar shows to `controller`, now and after every change of caret, selection or text.
    func bindFormatState(to controller: EditorController) {
        onFormatStateChange = { [weak controller] state in
            guard let c = controller else { return }
            if c.activeInlineKinds != state.inline { c.activeInlineKinds = state.inline }
            if c.activeHeadingLevel != state.heading { c.activeHeadingLevel = state.heading }
            if c.activeLinePrefix != state.block { c.activeLinePrefix = state.block }
        }
        publishFormatState()
    }
}
