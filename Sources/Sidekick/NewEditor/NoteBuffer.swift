import AppKit
import NoteDocument

extension NSAttributedString.Key {
    /// Block kind of a paragraph, carried by every character of it (NSNumber: 0 paragraph, 1...6 heading level, 10 bullet, 11 numbered, 12/13 unchecked/checked item, 14 quote, 15 divider).
    static let noteBlockKind = NSAttributedString.Key("sidekick.noteBlockKind")
    /// Bold mark with the delimiter spelling the file used (NSString "**" or "__"). Absent = not bold.
    static let noteBold = NSAttributedString.Key("sidekick.noteBold")
    /// Every other mark of a run (`NoteRunStyle`): italic, underline, strikethrough, code, link, pill. Absent = none.
    static let noteStyle = NSAttributedString.Key("sidekick.noteStyle")
}

/// The marks of a run other than bold, as one attribute value, so that the buffer carries a note document
/// losslessly. A pill is one attachment character in the buffer; its address lives here (`pillText`), with a
/// number that makes it a separate object even next to another pill. Characters typed next to a pill never carry
/// the pill (`withoutPill`): the text is plain text again.
final class NoteRunStyle: NSObject {
    let italic: ItalicDelimiter?
    let underline: Bool
    let strikethrough: Bool
    let code: Bool
    let link: String?
    let pill: PillForm?
    let pillText: String?
    let pillID: Int

    init?(_ run: Run, pillID: Int) {
        guard run.italic != nil || run.underline || run.strikethrough || run.code || run.link != nil || run.pill != nil else { return nil }
        italic = run.italic; underline = run.underline; strikethrough = run.strikethrough
        code = run.code; link = run.link; pill = run.pill
        pillText = run.pill == nil ? nil : run.text
        self.pillID = run.pill == nil ? 0 : pillID
    }

    private init(copying o: NoteRunStyle, link: String?, dropPill: Bool) {
        italic = o.italic; underline = o.underline; strikethrough = o.strikethrough; code = o.code
        self.link = link
        pill = dropPill ? nil : o.pill
        pillText = dropPill ? nil : o.pillText
        pillID = dropPill ? 0 : o.pillID
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? NoteRunStyle else { return false }
        return italic == o.italic && underline == o.underline && strikethrough == o.strikethrough && code == o.code
            && link == o.link && pill == o.pill && pillText == o.pillText && pillID == o.pillID
    }
    override var hash: Int { pillID &* 31 &+ (link?.hashValue ?? 0) }

    /// The same marks without the pill (and, if asked, without the link); nil when no mark is left.
    func removing(pill dropPill: Bool, link dropLink: Bool) -> NoteRunStyle? {
        let s = NoteRunStyle(copying: self, link: dropLink ? nil : link, dropPill: dropPill)
        return s.italic == nil && !s.underline && !s.strikethrough && !s.code && s.link == nil && s.pill == nil ? nil : s
    }

    /// The runs for `text` carrying these marks (bold is added by the caller). The pill character becomes the pill run
    /// with its address; any other character is plain text, whatever it inherited.
    func runs(_ text: String) -> [Run] {
        let base = Run(text, italic: italic, underline: underline, strikethrough: strikethrough, code: code, link: link)
        guard let form = pill, let address = pillText else { return [base] }
        var out: [Run] = []
        var plain = ""
        func flush() { if !plain.isEmpty { var r = base; r.text = plain; r.pill = nil; out.append(r); plain = "" } }
        for ch in text {
            if ch == NotePillAttachment.objectCharacter { flush(); var r = base; r.text = address; r.pill = form; out.append(r) }
            else { plain.append(ch) }
        }
        flush()
        return out
    }
}

/// The buffer form of a note document: visible characters only, one text paragraph per block,
/// paragraphs separated by "\n". Block kind and marks are attributes, never characters.
///
/// Text after the last "\n" is the tail paragraph. It has a block only when it has text, or when
/// its kind is not a plain paragraph (a final empty heading, which has no character to carry it).
enum NoteBuffer {
    struct Paragraph: Equatable {
        var kind: BlockKind
        var runs: [Run]
    }

    // MARK: Kind <-> attribute

    static func attributeValue(_ kind: BlockKind) -> NSNumber {
        switch kind {
        case .paragraph: return 0
        case .heading(let level): return NSNumber(value: level)
        case .bullet: return 10
        case .numbered: return 11
        case .checklist(let checked): return checked ? 13 : 12
        case .quote: return 14
        case .divider: return 15
        case .fence: return 16
        case .table: return 17
        }
    }

    static func kind(fromAttribute value: Any?) -> BlockKind {
        guard let n = (value as? NSNumber)?.intValue, n >= 1 else { return .paragraph }
        switch n {
        case 10: return .bullet
        case 11: return .numbered
        case 12: return .checklist(checked: false)
        case 13: return .checklist(checked: true)
        case 14: return .quote
        case 15: return .divider
        case 16: return .fence
        case 17: return .table
        default: return .heading(level: min(6, n))
        }
    }

    /// A code block is one paragraph: its lines are separated by U+2028 (a line break inside a paragraph), so that
    /// "\n" stays the paragraph separator. A table's text already uses U+2028 between rows. Styling as a code
    /// block or grid is ticket 12.
    private static let lineSeparator = "\u{2028}"

    // MARK: Document -> buffer

    /// Attributed text for a document (marks and kinds as attributes; fonts are added by `restyle`)
    /// and the kind of the empty tail paragraph.
    static func attributed(for document: NoteDocument) -> (text: NSAttributedString, tailKind: BlockKind) {
        let out = NSMutableAttributedString()
        var tailKind = BlockKind.paragraph
        var pillID = 1
        let blocks = document.blocks
        for (i, block) in blocks.enumerated() {
            let kindAttr = attributeValue(block.kind)
            for run in block.runs {
                var attrs: [NSAttributedString.Key: Any] = [.noteBlockKind: kindAttr]
                if let d = run.bold { attrs[.noteBold] = d.rawValue }
                if let style = NoteRunStyle(run, pillID: pillID) { attrs[.noteStyle] = style; pillID += 1 }
                var text = block.kind == .fence ? run.text.replacingOccurrences(of: "\n", with: lineSeparator, options: .literal) : run.text
                if run.pill != nil {   // one object: the character stands for the whole address
                    text = String(NotePillAttachment.objectCharacter)
                    attrs[.attachment] = NotePillAttachment(address: run.text)
                }
                out.append(NSAttributedString(string: text, attributes: attrs))
            }
            let isLast = i == blocks.count - 1
            // A divider at the end of a note always has a normal line below it, so the line below exists in the buffer
            // even when the file ends right after the rule (the document keeps its bytes until an edit).
            if !(isLast && block.terminator.isEmpty) || block.kind == .divider {
                out.append(NSAttributedString(string: "\n", attributes: [.noteBlockKind: kindAttr]))
            } else if block.runs.isEmpty {
                tailKind = block.kind
            }
        }
        return (out, tailKind)
    }

    static func paragraphs(of document: NoteDocument) -> [Paragraph] {
        document.blocks.map { Paragraph(kind: $0.kind, runs: $0.runs) }
    }

    // MARK: Buffer -> paragraphs

    /// UTF-16 ranges of the paragraphs of `string`, each excluding its "\n". The last one is the tail.
    static func paragraphRanges(in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        for i in 0..<string.length where string.character(at: i) == 0x0A {
            ranges.append(NSRange(location: start, length: i - start))
            start = i + 1
        }
        ranges.append(NSRange(location: start, length: string.length - start))
        return ranges
    }

    /// The blocks the buffer stands for. `tailKind` is the kind of the tail when it has no characters.
    static func paragraphs(in text: NSAttributedString, tailKind: BlockKind) -> [Paragraph] {
        let ns = text.string as NSString
        let ranges = paragraphRanges(in: ns)
        var out: [Paragraph] = []
        for (i, r) in ranges.enumerated() {
            let isTail = i == ranges.count - 1
            if isTail && r.length == 0 && tailKind == .paragraph { break }
            // The terminating "\n" carries the paragraph's kind; the tail has none, so its last character does.
            let kind: BlockKind
            if r.length == 0 && isTail { kind = tailKind }
            else { kind = Self.kind(fromAttribute: text.attribute(.noteBlockKind, at: isTail ? r.location + r.length - 1 : r.location + r.length, effectiveRange: nil)) }
            var runs: [Run] = []
            if r.length > 0 {
                text.enumerateAttribute(.noteBold, in: r, options: []) { value, boldRange, _ in
                    let delimiter = (value as? String).flatMap(BoldDelimiter.init(rawValue:))
                    text.enumerateAttribute(.noteStyle, in: boldRange, options: []) { style, range, _ in
                        let substring = ns.substring(with: range)
                        for var run in (style as? NoteRunStyle)?.runs(substring) ?? [Run(substring)] {
                        run.bold = delimiter
                        // Same marks as the run before (a pill never merges): attributes such as the font split ranges.
                        if var last = runs.last, last.pill == nil, run.pill == nil {
                            let (a, b) = (last.text, run.text)
                            last.text = ""; run.text = ""
                            if last == run { runs[runs.count - 1].text = a + b; continue }
                            run.text = b
                        }
                        runs.append(run)
                        }
                    }
                }
            }
            if kind == .fence {
                for k in runs.indices { runs[k].text = runs[k].text.replacingOccurrences(of: lineSeparator, with: "\n", options: .literal) }
            }
            out.append(Paragraph(kind: kind, runs: runs))
        }
        return out
    }

    // MARK: Styling

    private static func font(for kind: BlockKind, bold: Bool) -> NSFont {
        switch kind {
        case .paragraph, .bullet, .numbered, .checklist, .divider, .fence, .table:   // code blocks and tables: ticket 12
            return NSFont.systemFont(ofSize: 15, weight: bold ? .bold : .regular)
        case .quote:   // italic, as in the old editor
            return NSFontManager.shared.convert(NSFont.systemFont(ofSize: 15, weight: bold ? .bold : .regular), toHaveTrait: .italicFontMask)
        case .heading(let level):
            let size: CGFloat = level == 1 ? 28 : level == 2 ? 22 : 18
            return NSFont.systemFont(ofSize: size, weight: bold ? .bold : .semibold)
        }
    }

    /// Text indent of a paragraph of `kind`: where its text starts (and wrapped lines hang) so that the drawn
    /// marker (bullet, number, checkbox) has room on the left. Quotes are indented as a block.
    static func indent(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .bullet: return 11   // text starts where the old editor put it (bullet glyph + space)
        case .numbered: return 17
        case .checklist: return 18   // 14 pt box column + 4 pt gap, as in the old editor
        case .quote: return 18
        case .paragraph, .heading, .divider, .fence, .table: return 0
        }
    }

    static func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
        func style(_ line: CGFloat, _ spacing: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.minimumLineHeight = line; s.maximumLineHeight = line; s.paragraphSpacing = spacing
            s.firstLineHeadIndent = indent; s.headIndent = indent
            return s
        }
        switch kind {
        case .paragraph, .divider, .fence, .table: return style(20, 1)
        case .quote: return style(20, 1, indent: indent(for: kind))
        case .bullet, .numbered, .checklist: return style(20, 7, indent: indent(for: kind))   // list rows have air between them
        case .heading(let level): return level == 1 ? style(32, 4) : level == 2 ? style(26, 3) : style(22, 2)
        }
    }

    /// Text colour of a paragraph: checked items are dimmed, quotes are secondary.
    static func color(for kind: BlockKind) -> NSColor {
        switch kind {
        case .checklist(checked: true): return .tertiaryLabelColor
        case .quote: return .secondaryLabelColor
        default: return .textColor
        }
    }

    /// Typing attributes for new text in a paragraph of `kind`.
    static func typingAttributes(for kind: BlockKind) -> [NSAttributedString.Key: Any] {
        [.noteBlockKind: attributeValue(kind), .font: font(for: kind, bold: false),
         .paragraphStyle: paragraphStyle(for: kind), .foregroundColor: color(for: kind)]
    }

    /// Makes every paragraph touched by `edited` uniform: its kind is the kind of its terminating
    /// character, and font and paragraph style follow from kind and bold mark.
    static func restyle(_ storage: NSTextStorage, edited: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let lo = max(0, edited.location - 1)
        let hi = min(ns.length, NSMaxRange(edited) + 1)
        for r in paragraphRanges(in: ns) {
            let end = min(ns.length, r.location + r.length + 1)   // include the "\n"
            if end < lo || r.location > hi { continue }
            let range = NSRange(location: r.location, length: end - r.location)
            guard range.length > 0 else { continue }
            let kind = Self.kind(fromAttribute: storage.attribute(.noteBlockKind, at: end - 1, effectiveRange: nil))
            storage.addAttributes([.noteBlockKind: attributeValue(kind), .paragraphStyle: paragraphStyle(for: kind),
                                   .foregroundColor: color(for: kind)], range: range)
            Self.stylePieces(of: storage, in: range, kind: kind)
        }
    }

    // MARK: Marks

    /// Font and decoration of every piece of `range` (a paragraph) from its marks: bold, italic, underline,
    /// strikethrough, inline code, link. Strikethrough is per piece: the mark, or a checked item.
    private static func stylePieces(of storage: NSTextStorage, in range: NSRange, kind: BlockKind) {
        for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .backgroundColor] { storage.removeAttribute(key, range: range) }
        let checked: Bool
        if case .checklist(checked: true) = kind { checked = true } else { checked = false }
        let single = NSUnderlineStyle.single.rawValue
        storage.enumerateAttribute(.noteBold, in: range, options: []) { bold, boldRange, _ in
            storage.enumerateAttribute(.noteStyle, in: boldRange, options: []) { value, piece, _ in
                let style = value as? NoteRunStyle
                var font = Self.font(for: kind, bold: bold != nil)
                if style?.italic != nil { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if style?.code == true {
                    font = NSFont.monospacedSystemFont(ofSize: 15 * 0.9, weight: .regular)
                    storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: piece)
                }
                storage.addAttribute(.font, value: font, range: piece)
                if style?.underline == true || style?.link != nil { storage.addAttribute(.underlineStyle, value: single, range: piece) }
                if style?.strikethrough == true || checked { storage.addAttribute(.strikethroughStyle, value: single, range: piece) }
                if style?.link != nil { storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: piece) }
            }
        }
    }
}
