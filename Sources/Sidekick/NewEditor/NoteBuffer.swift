import AppKit
import NoteDocument

extension NSAttributedString.Key {
    /// Block kind of a paragraph, carried by every character of it (NSNumber: 0 paragraph, 1...6 heading level).
    static let noteBlockKind = NSAttributedString.Key("sidekick.noteBlockKind")
    /// Bold mark with the delimiter spelling the file used (NSString "**" or "__"). Absent = not bold.
    static let noteBold = NSAttributedString.Key("sidekick.noteBold")
    /// Every other mark of a run (`NoteRunStyle`): italic, underline, strikethrough, code, link, pill. Absent = none.
    static let noteStyle = NSAttributedString.Key("sidekick.noteStyle")
}

/// The marks of a run other than bold, as one attribute value, so that the buffer carries a note document
/// losslessly. Styling them is left to later tickets. A pill carries its address and a number that makes it a
/// separate object even next to another pill; characters typed next to it that inherit the value no longer match
/// the address, and are read back as plain text.
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

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? NoteRunStyle else { return false }
        return italic == o.italic && underline == o.underline && strikethrough == o.strikethrough && code == o.code
            && link == o.link && pill == o.pill && pillText == o.pillText && pillID == o.pillID
    }
    override var hash: Int { pillID &* 31 &+ (link?.hashValue ?? 0) }

    /// The runs for `text` carrying these marks (bold is added by the caller). Text typed next to a pill inherits the
    /// attribute; the part that is not the address is plain text again.
    func runs(_ text: String) -> [Run] {
        let base = Run(text, italic: italic, underline: underline, strikethrough: strikethrough, code: code, link: link)
        guard let form = pill, let address = pillText, text != address else {
            var r = base; r.pill = pill; return [r]
        }
        func piece(_ s: String, pill: Bool) -> Run { var r = base; r.text = s; r.pill = pill ? form : nil; return r }
        if text.hasPrefix(address) { return [piece(address, pill: true), piece(String(text.dropFirst(address.count)), pill: false)] }
        if text.hasSuffix(address) { return [piece(String(text.dropLast(address.count)), pill: false), piece(address, pill: true)] }
        return [piece(text, pill: false)]
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
        default: return .heading(level: min(6, n))
        }
    }

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
                out.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            let isLast = i == blocks.count - 1
            if !(isLast && block.terminator.isEmpty) {
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
            out.append(Paragraph(kind: kind, runs: runs))
        }
        return out
    }

    // MARK: Styling

    private static func font(for kind: BlockKind, bold: Bool) -> NSFont {
        switch kind {
        case .paragraph, .bullet, .numbered, .checklist, .quote, .divider:   // styling of these kinds is tickets 07/08
            return NSFont.systemFont(ofSize: 15, weight: bold ? .bold : .regular)
        case .heading(let level):
            let size: CGFloat = level == 1 ? 28 : level == 2 ? 22 : 18
            return NSFont.systemFont(ofSize: size, weight: bold ? .bold : .semibold)
        }
    }

    static func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
        func style(_ line: CGFloat, _ spacing: CGFloat) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.minimumLineHeight = line; s.maximumLineHeight = line; s.paragraphSpacing = spacing
            return s
        }
        switch kind {
        case .paragraph, .bullet, .numbered, .checklist, .quote, .divider: return style(20, 1)
        case .heading(let level): return level == 1 ? style(32, 4) : level == 2 ? style(26, 3) : style(22, 2)
        }
    }

    /// Typing attributes for new text in a paragraph of `kind`.
    static func typingAttributes(for kind: BlockKind) -> [NSAttributedString.Key: Any] {
        [.noteBlockKind: attributeValue(kind), .font: font(for: kind, bold: false),
         .paragraphStyle: paragraphStyle(for: kind), .foregroundColor: NSColor.textColor]
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
                                   .foregroundColor: NSColor.textColor], range: range)
            storage.enumerateAttribute(.noteBold, in: range, options: []) { value, sub, _ in
                storage.addAttribute(.font, value: font(for: kind, bold: value != nil), range: sub)
            }
        }
    }
}
