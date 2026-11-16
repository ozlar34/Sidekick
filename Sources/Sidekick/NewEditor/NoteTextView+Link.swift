import AppKit
import NoteDocument

/// The small address field of Cmd+K: a rounded box with one text field, drawn in the text view under the selection (or
/// under the link or pill it edits). Return commits, Escape cancels, losing the focus (a click elsewhere) cancels without
/// taking the focus back.
final class NoteLinkFieldView: NSView, NSTextFieldDelegate {
    enum Result { case commit(String), cancel(restoreFocus: Bool) }

    static let size = NSSize(width: 300, height: 30)

    let textField = NSTextField()
    /// What the field shows now (while it is being edited, the field editor holds the text).
    var stringValue: String { (textField.currentEditor()?.string) ?? textField.stringValue }
    var onFinish: ((Result) -> Void)?
    private var finished = false

    init(address: String) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        setAccessibilityIdentifier("sidekick.linkAddressField")
        textField.frame = NSRect(x: 10, y: 5, width: Self.size.width - 20, height: 20)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.placeholderString = "Link address"
        textField.cell?.isScrollable = true
        textField.cell?.usesSingleLineMode = true
        textField.stringValue = address
        textField.delegate = self
        textField.setAccessibilityLabel("Link address")
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 8
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 0.5
        }
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        onFinish?(result)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): finish(.commit(textView.string)); return true
        case #selector(NSResponder.cancelOperation(_:)): finish(.cancel(restoreFocus: true)); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish(.cancel(restoreFocus: false)) }
}

/// Cmd+K in the new editor. The link is a mark on the buffer's characters (a pill is one object character whose address is
/// in its style), changed with one replace through the view's change notifications: one undo step, and the note document
/// follows from the buffer as for any other edit (an unedited link keeps its bytes).
extension NoteTextView {
    /// What Cmd+K acts on.
    struct LinkTarget {
        enum Kind: Equatable { case create, link, pill(PillForm) }
        let kind: Kind
        /// The text the link is made on, or the whole link or pill it edits.
        let range: NSRange
        /// The current address; empty for a new link.
        let address: String
    }

    private static var pillCounter = 1 << 20

    /// The open address field, if any.
    var linkField: NoteLinkFieldView? { subviews.lazy.compactMap { $0 as? NoteLinkFieldView }.first }

    // MARK: Finding the target

    /// The link or pill character `index` belongs to, with the whole extent of the link.
    private func linkObject(at index: Int, in para: NSRange) -> LinkTarget? {
        guard let storage = textStorage, index >= para.location, index < NSMaxRange(para),
              let style = storage.attribute(.noteStyle, at: index, effectiveRange: nil) as? NoteRunStyle else { return nil }
        if let form = style.pill, (string as NSString).character(at: index) == 0xFFFC, let address = style.pillText {
            return LinkTarget(kind: .pill(form), range: NSRange(location: index, length: 1), address: address)
        }
        guard let address = style.link else { return nil }
        func linked(_ i: Int) -> Bool { (storage.attribute(.noteStyle, at: i, effectiveRange: nil) as? NoteRunStyle)?.link == address }
        var lo = index, hi = index + 1
        while lo > para.location, linked(lo - 1) { lo -= 1 }
        while hi < NSMaxRange(para), linked(hi) { hi += 1 }
        return LinkTarget(kind: .link, range: NSRange(location: lo, length: hi - lo), address: address)
    }

    /// A link or pill at the caret (the character before it first, then the one after), the link or pill a selection lies
    /// in, else the selected text. Nothing in a code block, a table or a divider, on an empty selection, or across lines.
    func linkTarget() -> LinkTarget? {
        guard isEditable, let storage = textStorage else { return nil }
        let sel = selectedRange()
        guard let (_, para) = paragraph(at: sel.location), holdsMarks(kind(of: para)), NSMaxRange(sel) <= NSMaxRange(para) else { return nil }
        if sel.length == 0 {
            return linkObject(at: sel.location - 1, in: para) ?? linkObject(at: sel.location, in: para)
        }
        if let first = linkObject(at: sel.location, in: para), NSMaxRange(sel) <= NSMaxRange(first.range) { return first }
        // Text that can take a link: not a pill, not code.
        var linkable = false
        storage.enumerateAttributes(in: sel, options: []) { attrs, _, stop in
            if attrs[.attachment] == nil, !run(attrs).code { linkable = true; stop.pointee = true }
        }
        return linkable ? LinkTarget(kind: .create, range: sel, address: "") : nil
    }

    // MARK: The field

    /// Opens the address field (Cmd+K, Format > Link, the toolbar and popover Link button).
    func beginLinkEdit() {
        if let open = linkField {
            // Already open: bring the focus back to it if it left (asking again would end its editing).
            if !((window?.firstResponder as? NSView)?.isDescendant(of: open) ?? false) { window?.makeFirstResponder(open.textField) }
            return
        }
        guard let window, let target = linkTarget() else { return }
        let saved = selectedRange()
        let opened = (content: content, text: string)
        let field = NoteLinkFieldView(address: target.address)
        field.frame.origin = linkFieldOrigin(for: target.range)
        addSubview(field)
        scrollToVisible(field.frame)
        field.onFinish = { [weak self, weak field] result in
            field?.removeFromSuperview()
            guard let self else { return }
            var selection = saved
            switch result {
            case .commit(let raw):
                // The note must still be what the field was opened on.
                if self.content === opened.content, self.string == opened.text, let mapped = self.applyLink(raw, to: target, selection: saved) { selection = mapped }
                window.makeFirstResponder(self)
            case .cancel(let restoreFocus):
                if restoreFocus { window.makeFirstResponder(self) }
            }
            self.setSelectedRange(selection)
        }
        window.makeFirstResponder(field.textField)
        field.textField.currentEditor()?.selectAll(nil)   // typing replaces the address shown
    }

    /// Under the start of `range`, or above it when there is no room below.
    private func linkFieldOrigin(for range: NSRange) -> NSPoint {
        let size = NoteLinkFieldView.size
        let anchor = NoteTextEngine.caretRect(in: self, at: range.location)
        var y = anchor.maxY + 4
        if y + size.height > bounds.height, anchor.minY - 4 - size.height >= 0 { y = anchor.minY - 4 - size.height }
        let x = min(max(anchor.minX, 8), max(8, bounds.width - size.width - 8))
        return NSPoint(x: x, y: y)
    }

    // MARK: Committing

    /// A pill character for `address`, with the marks of `style`.
    private func pillObject(_ address: String, style: NoteRunStyle, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var run = style.runs(String(NotePillAttachment.objectCharacter)).first(where: { $0.pill != nil }) ?? Run(address, pill: .link)
        run.text = address
        Self.pillCounter += 1
        var attrs = attrs
        attrs[.noteStyle] = NoteRunStyle(run, pillID: Self.pillCounter)
        attrs[.attachment] = NotePillAttachment(address: address)
        return NSAttributedString(string: String(NotePillAttachment.objectCharacter), attributes: attrs)
    }

    /// Applies the typed address to the target as one replace; returns the selection to show afterwards, nil when nothing changed.
    private func applyLink(_ raw: String, to target: LinkTarget, selection saved: NSRange) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let address = Run.linkAddress(raw)
        guard address != target.address else { return nil }
        let original = storage.attributedSubstring(from: target.range)
        let out: NSAttributedString
        switch target.kind {
        case .pill:
            var attrs = original.attributes(at: 0, effectiveRange: nil)
            guard let style = attrs[.noteStyle] as? NoteRunStyle else { return nil }
            if address.isEmpty {
                // No link: the address stays as plain text (the marks other than the pill are kept).
                attrs.removeValue(forKey: .attachment)
                if let rest = style.removing(pill: true, link: false) { attrs[.noteStyle] = rest } else { attrs.removeValue(forKey: .noteStyle) }
                out = NSAttributedString(string: target.address, attributes: attrs)
            } else {
                // The pill keeps its form: the run is copied from the old style.
                out = pillObject(address, style: style, attrs: attrs)
            }
        case .create, .link:
            if address.isEmpty && target.kind == .create { return nil }
            let marked = NSMutableAttributedString(attributedString: original)
            var plainLabel = true
            marked.enumerateAttributes(in: NSRange(location: 0, length: marked.length), options: []) { attrs, range, _ in
                var attrs = attrs
                guard attrs[.attachment] == nil else { plainLabel = false; return }
                let r = run(attrs)
                if r.code { plainLabel = false; return }
                if r.bold != nil || r.italic != nil || r.underline || r.strikethrough { plainLabel = false }
                write(r.applying(.link(address), setting: !address.isEmpty, bold: .asterisks, italic: .asterisk), into: &attrs)
                marked.setAttributes(attrs, range: range)
            }
            if !address.isEmpty, plainLabel, marked.string == address {
                // A link whose label is its address is a pill (its link form).
                var attrs = original.attributes(at: 0, effectiveRange: nil)
                attrs.removeValue(forKey: .noteStyle)
                out = pillObject(address, style: NoteRunStyle(Run(address, pill: .link), pillID: 0)!, attrs: attrs)
            } else {
                out = marked
            }
        }
        guard !out.isEqual(to: original) else { return nil }
        replace(target.range, with: out, caret: target.range.location)
        // The selection keeps its place; positions after the target move with its new length.
        let delta = out.length - target.range.length
        func map(_ location: Int) -> Int {
            if location >= NSMaxRange(target.range) { return location + delta }
            return min(location, target.range.location + out.length)
        }
        let start = map(saved.location), end = map(NSMaxRange(saved))
        return NSRange(location: start, length: end - start)
    }
}
