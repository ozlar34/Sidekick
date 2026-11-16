import AppKit

/// The URL pill as one inline object: a single attachment character (U+FFFC) in the buffer whose cell draws the chip.
/// The address is not in the text; it is read from the character's `NoteRunStyle` (`pillText`), so the caret steps over
/// the whole pill and Backspace or Delete removes it as one unit.
final class NotePillAttachment: NSTextAttachment {
    /// Character that stands for a pill in the buffer.
    static let objectCharacter: Character = "\u{FFFC}"

    let displayText: String

    init(address: String) {
        displayText = Self.displayText(forAddress: address)
        super.init(data: nil, ofType: nil)
        attachmentCell = NotePillCell(text: displayText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What the chip shows: the address without scheme, leading `www.` and trailing slashes (as in the old editor).
    static func displayText(forAddress address: String) -> String {
        var s = address
        if s.hasPrefix("https://") { s.removeFirst("https://".count) }
        else if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        if s.hasPrefix("www.") { s.removeFirst("www.".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? address : s
    }
}

/// Draws a pill: rounded box in the control background colour with a hairline border and the display text in
/// secondary label colour. Same look as the old editor's link chip.
final class NotePillCell: NSTextAttachmentCell {
    private static let font = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let horizontalPadding: CGFloat = 6
    private static let corner: CGFloat = 4
    private static let height: CGFloat = 20
    /// The old chip reached 5.6 pt below the baseline and 14.4 pt above it.
    private static let belowBaseline: CGFloat = 5.6

    private let text: String

    init(text: String) {
        self.text = text
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
    }

    override func cellSize() -> NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + Self.horizontalPadding * 2, height: Self.height)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -Self.belowBaseline) }

    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.25, dy: 0.25), xRadius: Self.corner, yRadius: Self.corner)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let size = (text as NSString).size(withAttributes: labelAttributes)
        (text as NSString).draw(at: NSPoint(x: cellFrame.minX + Self.horizontalPadding, y: cellFrame.midY - size.height / 2),
                                withAttributes: labelAttributes)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
