import AppKit
import SwiftUI

/// Markdown formatting toolbar shown below the TextEditor in edit mode.
/// Buttons call the `wrapSelection` closure (provided by EditorPaneView)
/// which bridges to NSTextView. All string manipulation logic is
/// extracted into `applyMarkdownWrap` (pure, unit-testable — no AppKit).
struct FormattingToolbarView: View {
    let wrapSelection: (String, String) -> Void
    let applyLinePrefix: () -> Void
    /// Apply a heading level (or strip back to body) on the line(s)
    /// containing the selection. `nil` = Body. Defaults to a no-op so
    /// existing call sites (tests, previews) compile without change.
    /// Named distinctly from the static `applyHeadingLevel(body:range:level:)`
    /// (mirrors `applyLinePrefix` vs `applyBulletedList`).
    var applyHeading: (Int?) -> Void = { _ in }
    /// Toggle a numbered-list (`1. `, `2. `, …) on the line(s) containing
    /// the selection. Mirrors `applyLinePrefix`'s shape — toggle off when
    /// every non-empty line already has a `<digits>. ` prefix.
    var applyNumberedList: () -> Void = {}
    /// Toggle a block-quote (`> `) prefix on the line(s) containing the
    /// selection. Mirrors `applyLinePrefix` exactly with `"> "` instead of `"- "`.
    var applyBlockQuote: () -> Void = {}
    /// Toggle a GFM task-list (`- [ ] ` / `- [x] `) prefix on the line(s)
    /// containing the selection. Mirrors `applyLinePrefix`'s shape — toggle
    /// off when every non-empty line already has the prefix.
    var applyChecklist: () -> Void = {}
    /// Insert a markdown thematic break (`---`) on its own line below the
    /// caret line. One-shot insert (no toggle-off path) — round-trip-safe
    /// because the source bytes survive untouched in the buffer.
    var insertThematicBreak: () -> Void = {}
    /// Set when the caret is inside a bold / italic / code span. Drives the
    /// active-state highlight on the corresponding button. Defaults to nil so
    /// existing call sites (tests, previews, menu-only invocations) compile
    /// without change. Populated by EditorPaneView from
    /// HybridEditorController.activeInlineKind.
    var activeInlineKind: InlineKind? = nil
    /// Heading level (1–3) of the line containing the caret, or nil if the
    /// caret is on a non-heading line. Drives the popover's active-row
    /// checkmark on Heading / Subheading / Body. Populated by EditorPaneView
    /// from HybridEditorController.activeHeadingLevel.
    var activeHeadingLevel: Int? = nil
    /// Line-prefix block format (bullet / numbered / checklist / blockquote)
    /// of the line containing the caret, or nil for plain lines. Drives the
    /// popover's active-state highlight on the four list-shape rows + the
    /// standalone Checklist button. Populated by EditorPaneView from
    /// HybridEditorController.activeLinePrefix.
    var activeLinePrefix: LinePrefix? = nil

    /// Inline kinds currently armed on an empty selection (quick-260523-29t).
    /// OR-ed into each inline button's `isActive` highlight so the toolbar
    /// shows "armed for next-typed character" the same way it shows
    /// "caret inside an existing pair". Defaults empty so existing call
    /// sites (tests, previews) compile without change.
    var armedInlineKinds: Set<InlineKind> = []

    /// Apple Notes-style: a single "Aa" trigger collapses every formatting
    /// control behind one popover. Inline buttons (B/I/U/S) and paragraph
    /// styles (Heading / Subheading / Body / Bulleted / Numbered / Quote)
    /// live inside `FormattingPopoverView`. Inline code (⌘⌥C) and Link (⌘K)
    /// remain reachable via the Format menu / shortcuts but aren't surfaced
    /// in the popover — Apple Notes itself doesn't either.
    @State private var popoverShown = false

    var body: some View {
        HStack(spacing: 2) {
            FormatPopoverTrigger(isOpen: $popoverShown)
                .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
                    FormattingPopoverView(
                        wrapSelection: wrapSelection,
                        applyLinePrefix: applyLinePrefix,
                        applyHeading: applyHeading,
                        applyNumberedList: applyNumberedList,
                        applyBlockQuote: applyBlockQuote,
                        applyChecklist: applyChecklist,
                        insertThematicBreak: insertThematicBreak,
                        activeInlineKind: activeInlineKind,
                        activeHeadingLevel: activeHeadingLevel,
                        activeLinePrefix: activeLinePrefix,
                        armedInlineKinds: armedInlineKinds,
                        dismiss: { popoverShown = false }
                    )
                }

            // Apple Notes places the checklist button immediately right of
            // the "Aa" trigger — single tap, no popover. ⌘⇧L parity (D-S-02
            // explicit modifier mask via the menu equivalent in AppDelegate).
            FormatButton(
                systemName: "checklist",
                tooltip: "Checklist (⌘⇧L)",
                accessibilityLabel: "Checklist",
                isActive: activeLinePrefix == .checklist
            ) { applyChecklist() }

            Spacer()
        }
    }

    /// Pure string transformation: insert or wrap markdown markers around
    /// the specified range. Returns the new body plus the cursor location
    /// (UTF-16 units, 0-length selection) where the NSTextView should
    /// place the caret after the insert.
    ///
    /// - With a non-empty selection: wraps with `prefix + selected + suffix`;
    ///   cursor lands after the inserted suffix (range.location + prefix + selection + suffix).
    /// - With an empty selection: inserts `prefix + suffix` and places the
    ///   cursor between them (range.location + prefix.utf16.count). Exception:
    ///   if prefix ends with `[` (link case), still use prefix.utf16.count so
    ///   the cursor lands inside the brackets for link-text entry.
    ///
    /// `body` is treated as NSString for range arithmetic — all offsets are
    /// UTF-16 code units to match NSRange semantics (PreviewToggleTests pins
    /// the same UTF-16 contract for cursor offsets elsewhere in the app).
    internal static func applyMarkdownWrap(
        prefix: String,
        suffix: String,
        body: String,
        range: NSRange
    ) -> (newBody: String, cursorLocation: Int) {
        let nsBody = body as NSString
        // Clamp range defensively — inputs from NSTextView are trusted
        // in production but tests may pass sub-optimal ranges.
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        // F-05: wrap inside a fenced code block is inert. Markdown markers
        // inside `\`\`\`` content render as literal characters, so dropping
        // `**` or `~~` into a code block both fails to format the visual
        // text AND corrupts the code itself. If the selection sits fully
        // inside a fenced block's content range, return the body unchanged.
        // Selections that straddle the fence boundary are rare and undefined
        // under CommonMark; treat the same way.
        for fence in MarkdownInlineParser.findFencedCodeBlocks(in: body) {
            let fenceContent = fence.contentRange
            let selEnd = safeLocation + safeLength
            let startInside = safeLocation >= fenceContent.location
                && safeLocation <= fenceContent.location + fenceContent.length
            let endInside = selEnd >= fenceContent.location
                && selEnd <= fenceContent.location + fenceContent.length
            if startInside || endInside {
                return (body, safeLocation)
            }
        }

        // MARK: Universal toggle-off / swap
        // The hybrid editor hides `**`/`*`/`` ` `` glyphs as zero-width, so the
        // caret/selection can land in subtly different byte positions for the
        // same visual click. Instead of case-matching on selection shape, ask
        // the parser: "is there an inline-kind pair on this line that the
        // selection overlaps or contains?" — if yes, transform it.
        //
        // Transform rules for inline formats (bold/italic/code):
        //   • same kind  → strip markers (toggle off).
        //   • different kind → swap, but only inside the bold/italic/code
        //     mutual-exclusion set (CommonMark forbids composed
        //     ***bold-italic*** in this codebase). Strikethrough and
        //     underline are orthogonal to the bold/italic/code set —
        //     a different-kind hit involving them falls through to the
        //     wrap path so markers stack (e.g. `**~~foo~~**`).
        // Link (`prefix == "["`) intentionally skips this branch — ⌘K over
        // bold text should wrap the whole thing as a link, not strip it.
        let requestedKind: InlineKind? = inlineKind(forPrefix: prefix)
        if let kind = requestedKind,
           let pair = findAnyEnclosingInlinePair(body: body, selection: safeRange) {
            let innerText = nsBody.substring(with: pair.inner)
            let mutexSet: Set<InlineKind> = [.bold, .italic, .code]
            let canSwap = mutexSet.contains(pair.kind) && mutexSet.contains(kind)
            if pair.kind != kind && !canSwap {
                // Different kind, outside the mutex set → don't transform here;
                // fall through to the wrap path so the new markers stack
                // around the existing pair's whole span.
            } else if pair.kind == kind {
                // Same kind → strip.
                let newBody = nsBody.replacingCharacters(in: pair.whole, with: innerText)
                let openLen = pair.inner.location - pair.whole.location
                let closeLen = (pair.whole.location + pair.whole.length)
                    - (pair.inner.location + pair.inner.length)
                // Cursor placement based on where the original caret/selection
                // start sat relative to the pair:
                //   - before pair → unchanged (nothing stripped before it)
                //   - inside pair → shift left by openLen (open marker removed)
                //   - after pair → shift left by openLen + closeLen (both removed)
                let newCursor: Int
                if safeLocation <= pair.whole.location {
                    newCursor = safeLocation
                } else if safeLocation <= pair.whole.location + pair.whole.length {
                    newCursor = max(pair.whole.location, safeLocation - openLen)
                } else {
                    newCursor = safeLocation - (openLen + closeLen)
                }
                return (newBody, newCursor)
            } else {
                // Different kind → swap markers, keep inner text.
                let replacement = prefix + innerText + suffix
                let newBody = nsBody.replacingCharacters(in: pair.whole, with: replacement)
                // Cursor: preserve the caret's offset within the inner text
                // when possible; otherwise land at the start of the new inner.
                let newPrefixLen = (prefix as NSString).length
                let innerLen = (innerText as NSString).length
                let oldInnerStart = pair.inner.location
                let caretOffsetInInner = max(0, min(safeLocation - oldInnerStart, innerLen))
                let newCursor = pair.whole.location + newPrefixLen + caretOffsetInInner
                return (newBody, newCursor)
            }
        }

        let selected = safeLength > 0 ? nsBody.substring(with: safeRange) : ""
        let insert: String
        let cursor: Int
        if selected.isEmpty {
            insert = prefix + suffix
            cursor = safeLocation + (prefix as NSString).length
        } else {
            insert = prefix + selected + suffix
            // D-UX-01: for Link wrap on non-empty selection, cursor lands INSIDE ().
            // Specifically: safeLocation + "[".length + selected.length + "](".length = safeLocation + 1 + N + 2
            if prefix == "[" && suffix == "]()" {
                cursor = safeLocation + 1 + (selected as NSString).length + 2
            } else {
                cursor = safeLocation + (insert as NSString).length
            }
        }
        let newBody = nsBody.replacingCharacters(in: safeRange, with: insert)
        return (newBody, cursor)
    }

    /// Inline-format kind for toggle/swap detection. Line-prefix formats
    /// (headings, bullets) and link are intentionally NOT inline kinds.
    /// Bold/italic/code are mutually exclusive (the swap branch in
    /// `applyMarkdownWrap` only operates inside that set). Strikethrough
    /// and underline are orthogonal — they participate in toggle-off but
    /// stack rather than swap when the requested kind differs.
    internal enum InlineKind { case bold, italic, code, strikethrough, underline }

    /// Line-prefix block format of the caret's line. Drives the popover
    /// active-state highlight for the four list-shape rows. Mutually
    /// exclusive — a line is either bulleted, numbered, a checklist, a
    /// blockquote, or none of these. Headings are NOT included here; they
    /// have their own publisher (`activeHeadingLevel`).
    internal enum LinePrefix { case bullet, numbered, checklist, blockquote }

    /// Classify the line containing the caret. Single-line scan over the
    /// recognized prefixes — cheaper than re-running the full parser for
    /// what is purely a UI hint. Mirrors the `updateActiveHeadingLevel`
    /// pattern in HybridEditorView.Coordinator.
    ///
    /// Order matters: checklist (`- [ ] ` / `- [x] `) is detected before
    /// bullet (`- `), since the checklist prefix begins with a bullet
    /// prefix and the more-specific match wins.
    internal static func activeLinePrefix(body: String, selection: NSRange) -> LinePrefix? {
        let nsBody = body as NSString
        guard selection.location >= 0,
              selection.location <= nsBody.length else { return nil }
        let probe = NSRange(location: min(selection.location, nsBody.length), length: 0)
        let lineRange = nsBody.lineRange(for: probe)
        let line = nsBody.substring(with: lineRange) as NSString

        // Checklist: `- [ ] ` or `- [x] ` / `- [X] `
        if line.length >= 6,
           line.character(at: 0) == 0x2D,   // '-'
           line.character(at: 1) == 0x20,   // ' '
           line.character(at: 2) == 0x5B,   // '['
           line.character(at: 4) == 0x5D,   // ']'
           line.character(at: 5) == 0x20 {  // ' '
            let state = line.character(at: 3)
            if state == 0x20 || state == 0x78 || state == 0x58 {
                return .checklist
            }
        }

        // Bullet: `- ` or `* `
        if line.length >= 2,
           (line.character(at: 0) == 0x2D || line.character(at: 0) == 0x2A),
           line.character(at: 1) == 0x20 {
            return .bullet
        }

        // Numbered: `<digits>+. `
        var i = 0
        while i < line.length, line.character(at: i) >= 0x30, line.character(at: i) <= 0x39 {
            i += 1
        }
        if i > 0,
           i + 1 < line.length,
           line.character(at: i) == 0x2E,       // '.'
           line.character(at: i + 1) == 0x20 {  // ' '
            return .numbered
        }

        // Blockquote: `> `
        if line.length >= 2,
           line.character(at: 0) == 0x3E,   // '>'
           line.character(at: 1) == 0x20 {
            return .blockquote
        }

        return nil
    }

    /// Returns the inline kind whose pair currently encloses the selection
    /// (caret or range), or nil if the selection sits in plain text. Thin
    /// wrapper over `findAnyEnclosingInlinePair` — exposed so the editor's
    /// selection observer can drive the toolbar's active-state highlight.
    /// Bold/italic/code are mutually exclusive in the parser (italic regex
    /// excludes `**…**` via lookarounds), so a single optional suffices.
    internal static func activeInlineKind(body: String, selection: NSRange) -> InlineKind? {
        return findAnyEnclosingInlinePair(body: body, selection: selection)?.kind
    }

    /// Map a wrap prefix to its inline kind; returns nil for non-inline
    /// prefixes (link `[`, or anything unrecognized). Used by
    /// `applyMarkdownWrap` to gate the universal toggle-off / swap branch.
    internal static func inlineKind(forPrefix prefix: String) -> InlineKind? {
        switch prefix {
        case "**": return .bold
        case "*":  return .italic
        case "`":  return .code
        case "~~": return .strikethrough
        case "<u>": return .underline
        default:   return nil
        }
    }

    // MARK: - Armed inline-format helpers (hide-markers-on-empty-selection)
    //
    // These power the "Cmd+B with empty selection does NOT insert ****; it arms
    // the next-typed character" UX. Pure state-transition + string-composition
    // math, no AppKit deps — see ArmedInlineFormatTests for the contract.

    /// Bold/italic/code are mutually exclusive (CommonMark forbids composed
    /// triple-asterisk in this codebase — see comment on applyMarkdownWrap's
    /// mutex set at line 159). Underline + strikethrough are orthogonal: they
    /// can stack with each other and with any one mutex kind.
    private static let mutexInlineKinds: Set<InlineKind> = [.bold, .italic, .code]

    /// Wrap markers per inline kind. Single source of truth shared with the
    /// `inlineKind(forPrefix:)` table above.
    private static func prefixFor(_ kind: InlineKind) -> String {
        switch kind {
        case .bold:          return "**"
        case .italic:        return "*"
        case .code:          return "`"
        case .strikethrough: return "~~"
        case .underline:     return "<u>"
        }
    }

    private static func suffixFor(_ kind: InlineKind) -> String {
        switch kind {
        case .bold:          return "**"
        case .italic:        return "*"
        case .code:          return "`"
        case .strikethrough: return "~~"
        case .underline:     return "</u>"
        }
    }

    /// Pure state-transition for arming an inline kind on an empty selection.
    ///
    /// Rules (from locked decisions for quick-29t):
    ///   1. If `requestedKind` is already armed → toggle off (remove from BOTH
    ///      `set` and `order`).
    ///   2. Else if `requestedKind` is in the bold/italic/code mutex set AND a
    ///      different mutex kind is currently armed → replace that mutex kind
    ///      in place. Both `set` and `order` are updated; the requested kind
    ///      takes the existing mutex kind's slot in `order` so orthogonal
    ///      neighbours (underline / strikethrough) keep their positions.
    ///   3. Else → append `requestedKind` to `order` (becomes the new
    ///      outermost / last-armed) and insert into `set`. This covers both
    ///      "first arm" and "orthogonal stack" cases.
    ///
    /// Inputs are not mutated; a fresh tuple is returned.
    internal static func armedInlineKindsAfterArm(
        current: (set: Set<InlineKind>, order: [InlineKind]),
        requestedKind: InlineKind
    ) -> (set: Set<InlineKind>, order: [InlineKind]) {
        // Rule 1: re-arming the same kind toggles off.
        if current.set.contains(requestedKind) {
            var newSet = current.set
            newSet.remove(requestedKind)
            let newOrder = current.order.filter { $0 != requestedKind }
            return (newSet, newOrder)
        }

        // Rule 2: mutex-replace. If the requested kind is in the mutex set
        // and another mutex kind is already armed, swap in-place.
        if mutexInlineKinds.contains(requestedKind),
           let existingMutex = current.order.first(where: { mutexInlineKinds.contains($0) }) {
            var newSet = current.set
            newSet.remove(existingMutex)
            newSet.insert(requestedKind)
            var newOrder = current.order
            if let idx = newOrder.firstIndex(of: existingMutex) {
                newOrder[idx] = requestedKind
            }
            return (newSet, newOrder)
        }

        // Rule 3: append (first arm OR orthogonal stack).
        var newSet = current.set
        newSet.insert(requestedKind)
        var newOrder = current.order
        newOrder.append(requestedKind)
        return (newSet, newOrder)
    }

    /// Pure composition: given the `order` of armed kinds (innermost first,
    /// outermost last), build the (prefix, suffix) pair that wraps a single
    /// typed character.
    ///
    /// Reading left-to-right, the OUTER prefix comes first. Example for
    /// `order = [.bold, .underline]` (bold armed first, underline second):
    ///   prefix = "<u>**"   (outer <u> then inner **)
    ///   suffix = "**</u>"  (inner ** then outer </u>)
    /// Wrapping "X" gives `<u>**X**</u>`, which renders as bold-and-underlined.
    internal static func composeArmedWrap(
        order: [InlineKind]
    ) -> (prefix: String, suffix: String) {
        let prefix = order.reversed().map { prefixFor($0) }.joined()
        let suffix = order.map { suffixFor($0) }.joined()
        return (prefix, suffix)
    }

    /// Find any inline-kind marker pair (bold / italic / code) on the line
    /// containing the selection whose whole span (open + content + close)
    /// overlaps or contains the selection. Returns (kind, whole, inner) in
    /// body coordinates, or nil if no such pair exists on that line.
    ///
    /// Scan order is bold → italic → code. Italic regex already excludes
    /// `**…**` via lookarounds so bold-first is deterministic; code is last
    /// since `` `…` `` is the least ambiguous.
    ///
    /// Overlap match covers:
    ///   • caret (length 0) anywhere in [wholeStart…wholeEnd], including on
    ///     the hidden zero-width marker glyphs
    ///   • selection fully inside the whole pair
    ///   • selection start OR end landing inside the whole pair
    ///   • selection containing the whole pair
    /// Pairs cannot span paragraph boundaries in CommonMark, so scanning the
    /// single line containing the selection start is sufficient.
    private static func findAnyEnclosingInlinePair(
        body: String,
        selection: NSRange
    ) -> (kind: InlineKind, whole: NSRange, inner: NSRange)? {
        let ns = body as NSString
        guard selection.location >= 0,
              selection.location + selection.length <= ns.length else { return nil }
        let probe = NSRange(location: min(selection.location, ns.length), length: 0)
        let lineRange = ns.lineRange(for: probe)
        let lineText = ns.substring(with: lineRange)
        let selStartInLine = selection.location - lineRange.location
        let selEndInLine = selStartInLine + selection.length

        func matchResult(open: NSRange, close: NSRange) -> (whole: NSRange, inner: NSRange)? {
            let innerStart = open.location + open.length
            let innerEnd = close.location
            guard innerEnd > innerStart else { return nil }
            let wholeStart = open.location
            let wholeEnd = close.location + close.length

            // Overlap test — see doc comment above.
            let caretInPair = selection.length == 0
                && selStartInLine >= wholeStart && selStartInLine <= wholeEnd
            let startInPair = selStartInLine >= wholeStart && selStartInLine < wholeEnd
            let endInPair = selEndInLine > wholeStart && selEndInLine <= wholeEnd
            let containsPair = selStartInLine <= wholeStart && selEndInLine >= wholeEnd
            guard caretInPair || startInPair || endInPair || containsPair else { return nil }

            let whole = NSRange(location: lineRange.location + wholeStart, length: wholeEnd - wholeStart)
            let inner = NSRange(location: lineRange.location + innerStart, length: innerEnd - innerStart)
            return (whole, inner)
        }

        for m in MarkdownInlineParser.findBoldRanges(in: lineText) {
            if let r = matchResult(open: m.markerOpenRange, close: m.markerCloseRange) {
                return (.bold, r.whole, r.inner)
            }
        }
        for m in MarkdownInlineParser.findItalicRanges(in: lineText) {
            if let r = matchResult(open: m.markerOpenRange, close: m.markerCloseRange) {
                return (.italic, r.whole, r.inner)
            }
        }
        for m in MarkdownInlineParser.findInlineCodeRanges(in: lineText) {
            if let r = matchResult(open: m.markerOpenRange, close: m.markerCloseRange) {
                return (.code, r.whole, r.inner)
            }
        }
        for m in MarkdownInlineParser.findStrikethroughRanges(in: lineText) {
            if let r = matchResult(open: m.markerOpenRange, close: m.markerCloseRange) {
                return (.strikethrough, r.whole, r.inner)
            }
        }
        for m in MarkdownInlineParser.findUnderlineRanges(in: lineText) {
            if let r = matchResult(open: m.markerOpenRange, close: m.markerCloseRange) {
                return (.underline, r.whole, r.inner)
            }
        }
        return nil
    }

    /// Pure string transformation: toggles a `"- "` prefix on every line in
    /// the block containing `range`. Mirrors the Apple Notes / Bear
    /// convention: if every non-empty line in the expanded block already
    /// starts with `"- "`, the prefix is stripped from each line
    /// (toggle off). Otherwise — mixed or no prefixes — `"- "` is prepended
    /// to EVERY line in the block, including empty lines (an empty bullet
    /// `"- "` is a real thing in Notes).
    ///
    /// - Returns `newBody` and `newSelection` (NSRange) covering the
    ///   transformed line block. Callers re-select the block so the user
    ///   can hit ⌘⇧8 again to toggle off.
    ///
    /// UTF-16 discipline (same as `applyMarkdownWrap`): `body` is treated as
    /// NSString; lineRange(for:) returns UTF-16 spans that include the
    /// trailing `\n` (or end-of-string when the final line has no newline).
    ///
    /// Empty selection (`range.length == 0`) still works — `lineRange(for:)`
    /// returns the enclosing line's span, so the caret's x-position doesn't
    /// affect where the prefix lands (it's always line-start).
    internal static func applyBulletedList(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString

        // Clamp defensively — mirrors applyMarkdownWrap's safe-range pattern.
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        // Expand to line-block bounds. lineRange(for:) returns the NSRange
        // covering full lines, including any trailing "\n".
        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)

        // Preserve trailing newline on rejoin if the block ends with one.
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        // Split lines. components(separatedBy:) yields a trailing "" when
        // the string ends with "\n" — we handle that explicitly on rejoin.
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Determine mode: all non-empty lines prefixed → strip; otherwise add.
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { ($0 as NSString).hasPrefix("- ") }

        let transformed: [String]
        if allPrefixed {
            // Strip mode: drop leading "- " (2 UTF-16 units) from each
            // non-empty line. Empty lines stay untouched.
            transformed = lines.map { line -> String in
                let ns = line as NSString
                if ns.hasPrefix("- ") {
                    return ns.substring(from: 2)
                }
                return line
            }
        } else {
            // Add mode: prepend "- " to EVERY line (including empties —
            // consistent with Apple Notes behavior).
            transformed = lines.map { "- " + $0 }
        }

        // Rejoin, preserving the trailing newline if the original had one.
        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: applies, swaps, or strips a heading
    /// prefix (`# `, `## `, `### `, …) on every line in the block containing
    /// `range`. Mirrors `applyBulletedList`'s shape: line-block expansion,
    /// per-line prefix manipulation, toggle-off on re-pick.
    ///
    /// - `level`: `nil` → strip any heading prefix from every line (force
    ///   Body). `1…6` → apply that heading level to every line.
    /// - **Toggle rule**: if `level != nil` AND every non-empty line in the
    ///   expanded block already has exactly that level, the call is treated
    ///   as `level = nil` (strip → Body). This mirrors the bullet toggle
    ///   convention and lets ⌘⌥2 on an H2 line strip back to body.
    /// - Existing heading prefixes are stripped before the new prefix is
    ///   prepended, so applying H1 to an H2 line produces an H1 line (level
    ///   swap, not stacked hashes).
    /// - Empty lines: when applying a level, an empty line still gets the
    ///   prefix (consistent with bullet behaviour — an empty heading line
    ///   `"## "` is a real thing). When stripping, empty lines stay empty.
    ///
    /// Returns `newBody` and `newSelection` (NSRange) covering the
    /// transformed line block. Callers re-select the block so a follow-up
    /// shortcut press can toggle it off cleanly.
    internal static func applyHeadingLevel(
        body: String,
        range: NSRange,
        level: Int?
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString

        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let requestedLevel: Int?
        if let lvl = level, lvl >= 1, lvl <= 6 {
            requestedLevel = lvl
        } else {
            requestedLevel = nil
        }

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Returns (level, prefixLength) for a line whose first chars are
        // 1–6 `#` followed by a single space; nil otherwise. Single-line
        // scan is cheaper than re-running the full parser per line.
        func headingPrefix(of line: String) -> (level: Int, prefixLen: Int)? {
            let ns = line as NSString
            var hashes = 0
            while hashes < ns.length, ns.character(at: hashes) == 0x23 /* # */ {
                hashes += 1
            }
            guard hashes >= 1, hashes <= 6,
                  hashes < ns.length, ns.character(at: hashes) == 0x20 /* space */
            else { return nil }
            return (hashes, hashes + 1)
        }

        // Toggle detection — only triggers when the caller specified a level.
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let effectiveLevel: Int?
        if let lvl = requestedLevel,
           !nonEmptyLines.isEmpty,
           nonEmptyLines.allSatisfy({ headingPrefix(of: $0)?.level == lvl }) {
            effectiveLevel = nil
        } else {
            effectiveLevel = requestedLevel
        }

        let newPrefix: String = effectiveLevel.map { String(repeating: "#", count: $0) + " " } ?? ""

        let transformed: [String] = lines.map { line in
            let stripped: String
            if let h = headingPrefix(of: line) {
                stripped = (line as NSString).substring(from: h.prefixLen)
            } else {
                stripped = line
            }
            if effectiveLevel == nil {
                return stripped
            }
            return newPrefix + stripped
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: toggles a numbered-list prefix (`1. `,
    /// `2. `, … sequentially per line, restarting at 1 across the block) on
    /// every line in the block containing `range`. Mirrors `applyBulletedList`
    /// exactly: line-block expansion, all-prefixed-toggle-off rule, UTF-16
    /// discipline. The "all prefixed" check accepts any `<digits>+. ` prefix
    /// (so a hand-edited `5. foo\n7. bar` block still toggles off cleanly).
    /// On add, any pre-existing numeric prefix is stripped first and the
    /// block is re-numbered from 1 — guarantees readable raw markdown.
    internal static func applyNumberedList(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Returns prefix length if the line starts with `<digits>+. `; nil
        // otherwise. Single-line scan — cheaper than a NSRegularExpression.
        func numberedPrefixLen(of line: String) -> Int? {
            let ns = line as NSString
            var i = 0
            while i < ns.length, ns.character(at: i) >= 0x30 /* 0 */, ns.character(at: i) <= 0x39 /* 9 */ {
                i += 1
            }
            guard i > 0,
                  i + 1 < ns.length,
                  ns.character(at: i) == 0x2E /* . */,
                  ns.character(at: i + 1) == 0x20 /* space */
            else { return nil }
            return i + 2
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { numberedPrefixLen(of: $0) != nil }

        let transformed: [String]
        if allPrefixed {
            transformed = lines.map { line -> String in
                if let p = numberedPrefixLen(of: line) {
                    return (line as NSString).substring(from: p)
                }
                return line
            }
        } else {
            // Add mode: strip any existing numeric prefix, re-number from 1.
            var counter = 1
            transformed = lines.map { line -> String in
                let stripped: String
                if let p = numberedPrefixLen(of: line) {
                    stripped = (line as NSString).substring(from: p)
                } else {
                    stripped = line
                }
                let prefix = "\(counter). "
                counter += 1
                return prefix + stripped
            }
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: toggles a `"> "` prefix on every line in
    /// the block containing `range`. Mirrors `applyBulletedList` exactly with
    /// `"> "` instead of `"- "` — same line-block expansion, same toggle rule.
    internal static func applyBlockQuote(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { ($0 as NSString).hasPrefix("> ") }

        let transformed: [String]
        if allPrefixed {
            transformed = lines.map { line -> String in
                let ns = line as NSString
                if ns.hasPrefix("> ") {
                    return ns.substring(from: 2)
                }
                return line
            }
        } else {
            transformed = lines.map { "> " + $0 }
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: toggles a GFM task-list prefix
    /// (`- [ ] `) on every line in the block containing `range`. Mirrors
    /// `applyBulletedList` exactly — line-block expansion, all-prefixed-
    /// toggle-off rule, UTF-16 discipline. Both unchecked (`- [ ] `) and
    /// checked (`- [x] ` / `- [X] `) prefixes count as "prefixed" for the
    /// toggle-off check, so flipping a partially-completed list off works.
    /// On add, an unchecked `- [ ] ` prefix is prepended to every line
    /// (including empties — a blank task line is real).
    internal static func applyChecklist(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Returns the prefix length (always 6) if the line starts with a GFM
        // task-list prefix, nil otherwise. Single-line scan — cheaper than
        // running NSRegularExpression per line.
        func checklistPrefixLen(of line: String) -> Int? {
            let ns = line as NSString
            guard ns.length >= 6 else { return nil }
            // `- [` → first 3 chars
            if ns.character(at: 0) != 0x2D /* - */ { return nil }
            if ns.character(at: 1) != 0x20 /* space */ { return nil }
            if ns.character(at: 2) != 0x5B /* [ */ { return nil }
            let state = ns.character(at: 3)
            // space, x, or X
            guard state == 0x20 || state == 0x78 || state == 0x58 else { return nil }
            if ns.character(at: 4) != 0x5D /* ] */ { return nil }
            if ns.character(at: 5) != 0x20 /* space */ { return nil }
            return 6
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { checklistPrefixLen(of: $0) != nil }

        let transformed: [String]
        if allPrefixed {
            transformed = lines.map { line -> String in
                if let p = checklistPrefixLen(of: line) {
                    return (line as NSString).substring(from: p)
                }
                return line
            }
        } else {
            // Add mode: `- [ ] ` prepended to every line, including empties.
            transformed = lines.map { "- [ ] " + $0 }
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Applies a checklist toggle directly on an NSTextView. Mirrors
    /// `performBlockQuote` exactly — same edit-sandwich pattern, same caret
    /// restore semantics.
    static func performChecklist(in textView: NSTextView) {
        let body = textView.string
        let range = textView.selectedRange()
        let (fullNewBody, _) = applyChecklist(body: body, range: range)

        let nsBody = body as NSString
        let blockRange = nsBody.lineRange(for: range)

        let deltaLength = (fullNewBody as NSString).length - nsBody.length
        let newBlockLength = blockRange.length + deltaLength
        let newBlock = (fullNewBody as NSString).substring(
            with: NSRange(location: blockRange.location, length: newBlockLength)
        )

        guard textView.shouldChangeText(in: blockRange, replacementString: newBlock) else { return }
        textView.replaceCharacters(in: blockRange, with: newBlock)
        textView.didChangeText()

        // Caret restore: empty selection + single-line result → caret AFTER
        // the new `- [ ] ` prefix (or at line start if stripped). Prefix is
        // always 6 chars when present.
        if range.length == 0, !newBlock.contains("\n") {
            let caretOffset = deltaLength > 0 ? 6 : 0
            textView.setSelectedRange(
                NSRange(location: blockRange.location + max(0, caretOffset), length: 0)
            )
        } else {
            textView.setSelectedRange(
                NSRange(location: blockRange.location, length: (newBlock as NSString).length)
            )
        }
    }

    /// Click-to-toggle: if `markerCharIndex` lands on the `-` of a task-list
    /// line, flip the state char (` ` ↔ `x`) at offset +3 and trigger a
    /// reparse via the edit sandwich. Returns true when a toggle happened
    /// (caller should NOT fall through to the default mouseDown caret-move).
    static func toggleChecklistState(at markerCharIndex: Int, in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        guard markerCharIndex >= 0, markerCharIndex < nsBody.length else { return false }

        // Constrain to the line containing the click — checklist prefixes
        // always start at line begin, so the dash must sit at lineStart.
        let lineRange = nsBody.lineRange(for: NSRange(location: markerCharIndex, length: 0))
        guard markerCharIndex == lineRange.location else { return false }

        // Verify the line really has the task-list prefix (6 chars min).
        guard lineRange.length >= 6 else { return false }
        let prefix = nsBody.substring(with: NSRange(location: lineRange.location, length: 6))
        let prefixNS = prefix as NSString
        guard prefixNS.character(at: 0) == 0x2D /* - */,
              prefixNS.character(at: 1) == 0x20,
              prefixNS.character(at: 2) == 0x5B /* [ */,
              prefixNS.character(at: 4) == 0x5D /* ] */,
              prefixNS.character(at: 5) == 0x20 else { return false }

        let stateChar = prefixNS.character(at: 3)
        let replacement: String
        switch stateChar {
        case 0x20: replacement = "x"
        case 0x78, 0x58: replacement = " "
        default: return false
        }

        let stateRange = NSRange(location: lineRange.location + 3, length: 1)
        guard textView.shouldChangeText(in: stateRange, replacementString: replacement) else { return false }
        textView.replaceCharacters(in: stateRange, with: replacement)
        textView.didChangeText()
        return true
    }

    /// Enter continuation: when Enter is pressed on a task-list line, either
    /// continue the list (`\n- [ ] `) or exit it (strip the empty prefix).
    /// Returns true when the helper handled the Enter (caller should NOT
    /// fall through to the default `insertNewline:` behavior).
    static func handleChecklistReturn(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()
        // Only fire on caret (no selection) — a non-empty selection should
        // delete and insert a newline, matching default behavior.
        guard selection.length == 0 else { return false }

        let lineRange = nsBody.lineRange(for: selection)
        // Strip trailing newline for content inspection.
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > lineRange.location {
            let lastChar = nsBody.character(at: lineEnd - 1)
            if lastChar == 0x0A /* \n */ || lastChar == 0x0D /* \r */ {
                lineEnd -= 1
            }
        }
        let lineLen = lineEnd - lineRange.location
        guard lineLen >= 6 else { return false }
        let prefix = nsBody.substring(with: NSRange(location: lineRange.location, length: 6))
        let prefixNS = prefix as NSString
        guard prefixNS.character(at: 0) == 0x2D,
              prefixNS.character(at: 1) == 0x20,
              prefixNS.character(at: 2) == 0x5B,
              (prefixNS.character(at: 3) == 0x20
                || prefixNS.character(at: 3) == 0x78
                || prefixNS.character(at: 3) == 0x58),
              prefixNS.character(at: 4) == 0x5D,
              prefixNS.character(at: 5) == 0x20 else { return false }

        // Empty-checklist-line exit: line is exactly the 6-char prefix and
        // caret is at the end of it. Strip the prefix and let the user fall
        // out of the list with the caret at line start.
        if lineLen == 6, selection.location == lineRange.location + 6 {
            let stripRange = NSRange(location: lineRange.location, length: 6)
            guard textView.shouldChangeText(in: stripRange, replacementString: "") else { return false }
            textView.replaceCharacters(in: stripRange, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        // Caret must be past the 6-char prefix to trigger continuation. A
        // caret inside the prefix region (or at line start) means the user
        // is editing the prefix itself or splitting before it — let the
        // default newline insert behavior win.
        guard selection.location >= lineRange.location + 6 else { return false }

        // Continuation: insert `\n- [ ] ` at caret position. New line starts
        // unchecked even if the source line was checked — Apple Notes parity.
        let insertion = "\n- [ ] "
        guard textView.shouldChangeText(in: selection, replacementString: insertion) else { return false }
        textView.replaceCharacters(in: selection, with: insertion)
        textView.didChangeText()
        let newCaret = selection.location + (insertion as NSString).length
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        return true
    }

    // MARK: - Atomic inline-format marker delete (quick-260524-0ia)
    //
    // Design decisions (locked — see PLAN.md for full rationale):
    //
    // D-01: ALWAYS delete the pair atomically — preserves inner text, removes
    //       both markers in one edit. Half-deleted markers expose raw markdown.
    // D-02: Cursor INSIDE a marker run also fires atomic delete — any partial
    //       deletion produces the same broken render.
    // D-03: Link [label](url) deletes the whole wrapper and keeps the label.
    // D-04: Routed via doCommand (NOT NSTextView override) — keeps delete logic
    //       unified with checklist handlers; priority: atomic-marker → checklist → default.
    // D-05: Detection uses the parser's named find* functions, NOT .sidekickHiddenMarker
    //       (that attribute is set on 4 different scopes — inline, block, bare-URL, link wrapper).
    // D-06: Return false when no pair is adjacent — preserves checklist & native delete.
    // D-07: Inside a fenced code block → return nil (markers are literal text there).

    /// Direction for an atomic-marker delete keystroke.
    enum AtomicMarkerDeleteDirection { case backward, forward }

    /// Result of an atomic-marker delete decision.
    struct AtomicMarkerDeleteResult: Equatable {
        /// The full NSRange to replace (open marker + inner content + close marker).
        let deleteRange: NSRange
        /// The inner content text to leave in place of the deletion.
        let replacement: String
        /// Caret location AFTER the edit: deleteRange.location + replacement.utf16 count.
        let postCaret: Int
    }

    /// Determine whether a Backspace / forward-delete at `caret` should be
    /// promoted to an atomic inline-format marker pair deletion.
    ///
    /// Returns nil when no inline-format pair has marker bytes adjacent to
    /// (or containing) `caret` in the requested direction, or when the caret
    /// is inside a fenced code block (D-07), or body is empty.
    ///
    /// Adjacency rules (D-02 — cursor-inside-run also fires):
    ///   .backward:  caret > marker.location && caret <= marker.location + marker.length
    ///   .forward:   caret >= marker.location && caret < marker.location + marker.length
    ///
    /// Pair-detection order (first hit wins):
    ///   1. Links (findLinkRanges) — largest containing structure
    ///   2. Underline (findUnderlineRanges) — asymmetric close (`</u>`, 4 chars)
    ///   3. Bold (findBoldRanges)
    ///   4. Strikethrough (findStrikethroughRanges)
    ///   5. Inline code (findInlineCodeRanges)
    ///   6. Italic (findItalicRanges) — 1-char markers, checked last to avoid
    ///      false matches inside bold/strike runs.
    static func atomicMarkerDeleteRange(
        body: String,
        caret: Int,
        direction: AtomicMarkerDeleteDirection
    ) -> AtomicMarkerDeleteResult? {
        let ns = body as NSString
        guard ns.length > 0 else { return nil }

        // D-07: fenced code block guard — markers are literal inside fences.
        for fence in MarkdownInlineParser.findFencedCodeBlocks(in: body) {
            let cr = fence.contentRange
            if caret >= cr.location && caret <= cr.location + cr.length {
                return nil
            }
        }

        // Adjacency predicate (D-02: inside the run also fires).
        func isAdjacent(_ markerRange: NSRange, _ caret: Int, _ dir: AtomicMarkerDeleteDirection) -> Bool {
            switch dir {
            case .backward:
                return caret > markerRange.location && caret <= markerRange.location + markerRange.length
            case .forward:
                return caret >= markerRange.location && caret < markerRange.location + markerRange.length
            }
        }

        // 1. Link pass — highest priority (outer structure).
        for m in MarkdownInlineParser.findLinkRanges(in: body) {
            let adjacentToMarker = isAdjacent(m.openBracketRange, caret, direction)
                || isAdjacent(m.closeBracketRange, caret, direction)
                || isAdjacent(m.openParenRange, caret, direction)
                || isAdjacent(m.urlRange, caret, direction)
                || isAdjacent(m.closeParenRange, caret, direction)
            if adjacentToMarker {
                let spanStart = m.openBracketRange.location
                let spanEnd   = m.closeParenRange.location + m.closeParenRange.length
                let deleteRange = NSRange(location: spanStart, length: spanEnd - spanStart)
                let replacement = ns.substring(with: m.labelRange)   // D-03: keep label only
                let postCaret = spanStart + (replacement as NSString).length
                return AtomicMarkerDeleteResult(deleteRange: deleteRange, replacement: replacement, postCaret: postCaret)
            }
        }

        // 1b. Bare-URL pass — whole-URL atomic delete. A bare URL renders as a
        //     single collapsed link chip (every char hidden behind one pill),
        //     so a Backspace/forward-Delete adjacent to it must remove the
        //     entire URL in one step — parity with how `[label](url)` deletes
        //     atomically above. There is no marker/label to keep, so the whole
        //     span is the delete range and the replacement is empty.
        //
        //     Ordered before the emphasis passes so a URL containing `_`, `*`,
        //     or `~` is never mis-split by the bold/italic/strike parsers
        //     (e.g. `https://host/a_b_c` must not delete just `_b_`).
        for urlRange in MarkdownInlineParser.findAutoLinkRanges(in: body) {
            if isAdjacent(urlRange, caret, direction) {
                return AtomicMarkerDeleteResult(
                    deleteRange: urlRange,
                    replacement: "",
                    postCaret: urlRange.location
                )
            }
        }

        // 2. Underline pass — asymmetric close (`</u>` = 4 chars) before bold.
        for m in MarkdownInlineParser.findUnderlineRanges(in: body) {
            if isAdjacent(m.markerOpenRange, caret, direction) || isAdjacent(m.markerCloseRange, caret, direction) {
                let spanStart = m.markerOpenRange.location
                let spanEnd   = m.markerCloseRange.location + m.markerCloseRange.length
                let deleteRange = NSRange(location: spanStart, length: spanEnd - spanStart)
                let replacement = ns.substring(with: m.contentRange)
                let postCaret = spanStart + (replacement as NSString).length
                return AtomicMarkerDeleteResult(deleteRange: deleteRange, replacement: replacement, postCaret: postCaret)
            }
        }

        // 3. Bold pass.
        for m in MarkdownInlineParser.findBoldRanges(in: body) {
            if isAdjacent(m.markerOpenRange, caret, direction) || isAdjacent(m.markerCloseRange, caret, direction) {
                let spanStart = m.markerOpenRange.location
                let spanEnd   = m.markerCloseRange.location + m.markerCloseRange.length
                let deleteRange = NSRange(location: spanStart, length: spanEnd - spanStart)
                let replacement = ns.substring(with: m.contentRange)
                let postCaret = spanStart + (replacement as NSString).length
                return AtomicMarkerDeleteResult(deleteRange: deleteRange, replacement: replacement, postCaret: postCaret)
            }
        }

        // 4. Strikethrough pass.
        for m in MarkdownInlineParser.findStrikethroughRanges(in: body) {
            if isAdjacent(m.markerOpenRange, caret, direction) || isAdjacent(m.markerCloseRange, caret, direction) {
                let spanStart = m.markerOpenRange.location
                let spanEnd   = m.markerCloseRange.location + m.markerCloseRange.length
                let deleteRange = NSRange(location: spanStart, length: spanEnd - spanStart)
                let replacement = ns.substring(with: m.contentRange)
                let postCaret = spanStart + (replacement as NSString).length
                return AtomicMarkerDeleteResult(deleteRange: deleteRange, replacement: replacement, postCaret: postCaret)
            }
        }

        // 5. Inline code pass.
        for m in MarkdownInlineParser.findInlineCodeRanges(in: body) {
            if isAdjacent(m.markerOpenRange, caret, direction) || isAdjacent(m.markerCloseRange, caret, direction) {
                let spanStart = m.markerOpenRange.location
                let spanEnd   = m.markerCloseRange.location + m.markerCloseRange.length
                let deleteRange = NSRange(location: spanStart, length: spanEnd - spanStart)
                let replacement = ns.substring(with: m.contentRange)
                let postCaret = spanStart + (replacement as NSString).length
                return AtomicMarkerDeleteResult(deleteRange: deleteRange, replacement: replacement, postCaret: postCaret)
            }
        }

        // 6. Italic pass — 1-char markers, lowest priority.
        for m in MarkdownInlineParser.findItalicRanges(in: body) {
            if isAdjacent(m.markerOpenRange, caret, direction) || isAdjacent(m.markerCloseRange, caret, direction) {
                let spanStart = m.markerOpenRange.location
                let spanEnd   = m.markerCloseRange.location + m.markerCloseRange.length
                let deleteRange = NSRange(location: spanStart, length: spanEnd - spanStart)
                let replacement = ns.substring(with: m.contentRange)
                let postCaret = spanStart + (replacement as NSString).length
                return AtomicMarkerDeleteResult(deleteRange: deleteRange, replacement: replacement, postCaret: postCaret)
            }
        }

        return nil
    }

    /// Atomic-marker Backspace handler (quick-260524-0ia).
    /// Returns true when a collapsed caret is adjacent to (or inside) an
    /// inline-format marker run and the full pair was deleted atomically.
    /// Returns false for non-collapsed selections (D-06) and when no pair
    /// is adjacent — caller falls through to the existing checklist handler.
    static func handleAtomicMarkerBackspace(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }   // D-06: non-empty selection → false
        guard let result = atomicMarkerDeleteRange(
            body: textView.string,
            caret: selection.location,
            direction: .backward
        ) else { return false }

        guard textView.shouldChangeText(in: result.deleteRange, replacementString: result.replacement) else { return false }
        textView.replaceCharacters(in: result.deleteRange, with: result.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: result.postCaret, length: 0))
        return true
    }

    /// Atomic-marker forward-delete handler (quick-260524-0ia).
    /// Returns true when a collapsed caret is adjacent to (or inside) an
    /// inline-format marker run and the full pair was deleted atomically.
    /// Returns false for non-collapsed selections (D-06) and when no pair
    /// is adjacent — caller falls through to the existing checklist handler.
    static func handleAtomicMarkerForwardDelete(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }   // D-06: non-empty selection → false
        guard let result = atomicMarkerDeleteRange(
            body: textView.string,
            caret: selection.location,
            direction: .forward
        ) else { return false }

        guard textView.shouldChangeText(in: result.deleteRange, replacementString: result.replacement) else { return false }
        textView.replaceCharacters(in: result.deleteRange, with: result.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: result.postCaret, length: 0))
        return true
    }

    /// EDIT-03 — Backspace on a checklist line. Handles Paths A, B, E.
    /// Returns true if the keystroke was consumed (prefix stripped); false to
    /// fall through to NSTextView's default single-character delete.
    static func handleChecklistBackspace(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()

        // Path E: a non-empty selection that overlaps the checklist prefix.
        if selection.length > 0 {
            let lineRange = nsBody.lineRange(for: selection)
            guard lineRange.length >= 6 else { return false }
            let prefix = nsBody.substring(with: NSRange(location: lineRange.location, length: 6))
            let prefixNS = prefix as NSString
            guard prefixNS.character(at: 0) == 0x2D,
                  prefixNS.character(at: 1) == 0x20,
                  prefixNS.character(at: 2) == 0x5B,
                  (prefixNS.character(at: 3) == 0x20
                    || prefixNS.character(at: 3) == 0x78
                    || prefixNS.character(at: 3) == 0x58),
                  prefixNS.character(at: 4) == 0x5D,
                  prefixNS.character(at: 5) == 0x20 else { return false }
            // Only intercept if the selection starts within the 6-char prefix zone.
            let prefixEnd = lineRange.location + 6
            guard selection.location < prefixEnd else { return false }
            // Union: from line start through the end of the original selection.
            let unionEnd = selection.location + selection.length
            let unionRange = NSRange(location: lineRange.location,
                                     length: unionEnd - lineRange.location)
            guard textView.shouldChangeText(in: unionRange, replacementString: "") else { return false }
            textView.replaceCharacters(in: unionRange, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        // Caret-only — Paths A and B collapse to one branch.
        let lineRange = nsBody.lineRange(for: selection)
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > lineRange.location {
            let lastChar = nsBody.character(at: lineEnd - 1)
            if lastChar == 0x0A || lastChar == 0x0D { lineEnd -= 1 }
        }
        let lineLen = lineEnd - lineRange.location
        guard lineLen >= 6 else { return false }
        let prefix = nsBody.substring(with: NSRange(location: lineRange.location, length: 6))
        let prefixNS = prefix as NSString
        guard prefixNS.character(at: 0) == 0x2D,
              prefixNS.character(at: 1) == 0x20,
              prefixNS.character(at: 2) == 0x5B,
              (prefixNS.character(at: 3) == 0x20
                || prefixNS.character(at: 3) == 0x78
                || prefixNS.character(at: 3) == 0x58),
              prefixNS.character(at: 4) == 0x5D,
              prefixNS.character(at: 5) == 0x20 else { return false }

        // D-05 (Path A) and D-06 (Path B): caret exactly at lineStart + 6 → strip prefix.
        guard selection.location == lineRange.location + 6 else { return false }
        let stripRange = NSRange(location: lineRange.location, length: 6)
        guard textView.shouldChangeText(in: stripRange, replacementString: "") else { return false }
        textView.replaceCharacters(in: stripRange, with: "")
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        return true
    }

    /// EDIT-03 — Forward-delete (fn+Delete) on a checklist line. Handles Path C.
    /// Path D (forward-delete from content start) is intentionally NOT intercepted —
    /// it is already clean, so this helper only fires when the caret is at line start.
    static func handleChecklistForwardDelete(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }   // selections handled by Backspace path

        let lineRange = nsBody.lineRange(for: selection)
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > lineRange.location {
            let lastChar = nsBody.character(at: lineEnd - 1)
            if lastChar == 0x0A || lastChar == 0x0D { lineEnd -= 1 }
        }
        let lineLen = lineEnd - lineRange.location
        guard lineLen >= 6 else { return false }
        let prefix = nsBody.substring(with: NSRange(location: lineRange.location, length: 6))
        let prefixNS = prefix as NSString
        guard prefixNS.character(at: 0) == 0x2D,
              prefixNS.character(at: 1) == 0x20,
              prefixNS.character(at: 2) == 0x5B,
              (prefixNS.character(at: 3) == 0x20
                || prefixNS.character(at: 3) == 0x78
                || prefixNS.character(at: 3) == 0x58),
              prefixNS.character(at: 4) == 0x5D,
              prefixNS.character(at: 5) == 0x20 else { return false }

        // Path C: caret AT line start. Forward-delete would remove `-` and break the
        // prefix — strip all 6 chars instead. Path D (caret at lineStart+6) is left alone.
        guard selection.location == lineRange.location else { return false }
        let stripRange = NSRange(location: lineRange.location, length: 6)
        guard textView.shouldChangeText(in: stripRange, replacementString: "") else { return false }
        textView.replaceCharacters(in: stripRange, with: "")
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        return true
    }

    // MARK: - HR-03: One-shot thematic-break delete handlers

    /// HR-03 — Backspace on an empty line immediately below a horizontal rule.
    ///
    /// Trigger semantics: caret must be at the START of an EMPTY line (zero
    /// content chars, just the line terminator) and the PREVIOUS line must carry
    /// `.sidekickThematicBreak`. One Backspace at the START of that line deletes
    /// the whole rule in a single undoable step (shouldChangeText/
    /// replaceCharacters/didChangeText). If the caret's line is empty, the HR AND
    /// the empty line collapse ("...\n---\n\n..." → "...\n..."); if it has
    /// content, ONLY the HR is removed and the content rides up to where the HR
    /// was ("A\n---\nB" → "A\nB", N-01). The caret lands at the start of where
    /// the HR was; a second Backspace then merges the two paragraphs normally.
    ///
    /// Fires only at line start, so mid-line backspace stays a normal character
    /// delete and falls through.
    ///
    /// Returns true if the keystroke was consumed; false to fall through to the
    /// default delete handler.
    static func handleThematicBreakBackspace(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        guard let storage = textView.textStorage, storage.length > 0 else { return false }

        // Identify the caret's own line.
        let caretLine = nsBody.lineRange(for: selection)

        // Guard: caret's own line must be EMPTY (content length 0, i.e. only a
        // newline terminator or end-of-doc) AND caret must be at line start.
        var caretLineEnd = caretLine.location + caretLine.length
        if caretLineEnd > caretLine.location {
            let lastChar = nsBody.character(at: caretLineEnd - 1)
            if lastChar == 0x0A || lastChar == 0x0D { caretLineEnd -= 1 }
        }
        let contentLen = caretLineEnd - caretLine.location
        // Fire at the START of the line directly below an HR — empty or not.
        guard selection.location == caretLine.location else { return false }

        // Identify the PREVIOUS line.
        guard caretLine.location > 0 else { return false }
        let prevLineRange = nsBody.lineRange(for: NSRange(location: caretLine.location - 1, length: 0))

        // Guard: previous line must carry the HR attribute.
        guard prevLineRange.location < storage.length,
              storage.attribute(.sidekickThematicBreak,
                                at: prevLineRange.location,
                                effectiveRange: nil) != nil else { return false }

        // Empty caret line → collapse the HR AND the now-pointless empty line
        // ("...\n---\n\n..." → "...\n..."). Content caret line → delete ONLY the
        // HR line, keeping the content ("A\n---\nB" → "A\nB"); the content rides
        // up to where the HR was. One undo step either way.
        let editStart = prevLineRange.location
        let editEnd = (contentLen == 0)
            ? caretLine.location + caretLine.length   // HR line + the empty line
            : caretLine.location                      // HR line only
        let editRange = NSRange(location: editStart, length: editEnd - editStart)
        guard textView.shouldChangeText(in: editRange, replacementString: "") else { return false }
        textView.replaceCharacters(in: editRange, with: "")
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: prevLineRange.location, length: 0))
        return true
    }

    /// HR-03 — Forward-delete (fn+Delete) on an empty line immediately above a
    /// horizontal rule.
    ///
    /// Mirror of `handleThematicBreakBackspace`. Trigger: caret at the END of a
    /// line whose NEXT line carries `.sidekickThematicBreak`. One Forward-Delete
    /// removes the whole rule in one undoable step. If the caret's line is empty,
    /// the empty line AND the HR collapse ("...\n\n---\n..." → "...\n..."); if it
    /// has content, ONLY the HR is removed ("A\n---\nB" → "A\nB", N-01 mirror).
    /// The caret stays at its original position.
    ///
    /// Fires only at line end, so mid-line forward-delete stays a normal
    /// character delete and falls through.
    ///
    /// Returns true if the keystroke was consumed; false to fall through.
    static func handleThematicBreakForwardDelete(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        guard let storage = textView.textStorage, storage.length > 0 else { return false }

        // Identify the caret's own line.
        let caretLine = nsBody.lineRange(for: selection)

        // Guard: caret's own line must be EMPTY.
        var caretLineEnd = caretLine.location + caretLine.length
        if caretLineEnd > caretLine.location {
            let lastChar = nsBody.character(at: caretLineEnd - 1)
            if lastChar == 0x0A || lastChar == 0x0D { caretLineEnd -= 1 }
        }
        let contentLen = caretLineEnd - caretLine.location
        // Fire at the END of the line directly above an HR — empty or not. (For
        // an empty line, caretLineEnd == line start, so this still holds.)
        guard selection.location == caretLineEnd else { return false }

        // Identify the NEXT line.
        let nextLineStart = caretLine.location + caretLine.length
        guard nextLineStart < storage.length else { return false }
        let nextLineRange = nsBody.lineRange(for: NSRange(location: nextLineStart, length: 0))

        // Guard: next line must carry the HR attribute.
        guard storage.attribute(.sidekickThematicBreak,
                                at: nextLineRange.location,
                                effectiveRange: nil) != nil else { return false }

        // Empty caret line → collapse the empty line AND the HR
        // ("...\n\n---\n..." → "...\n..."). Content caret line → delete ONLY the
        // HR line, keeping the content ("A\n---\nB" → "A\nB"). One undo step; the
        // HR is after the caret, so the caret position is unchanged.
        let editStart = (contentLen == 0) ? caretLine.location : nextLineStart
        let editEnd = nextLineRange.location + nextLineRange.length
        let editRange = NSRange(location: editStart, length: editEnd - editStart)
        let originalLocation = selection.location
        guard textView.shouldChangeText(in: editRange, replacementString: "") else { return false }
        textView.replaceCharacters(in: editRange, with: "")
        textView.didChangeText()
        let clampedLocation = min(originalLocation, storage.length)
        textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
        return true
    }

    /// Enter continuation for bulleted-list lines (`- ` or `* `). Mirrors
    /// `handleChecklistReturn`: continue with `\n- ` (or `\n* `, preserving the
    /// original marker char) on a non-empty line; strip the prefix and exit
    /// when Enter is pressed on an otherwise-empty bullet line. Returns true
    /// when handled — caller (the editor coordinator) must NOT fall through
    /// to the default `insertNewline:` in that case.
    static func handleBulletReturn(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let lineRange = nsBody.lineRange(for: selection)
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > lineRange.location {
            let lastChar = nsBody.character(at: lineEnd - 1)
            if lastChar == 0x0A || lastChar == 0x0D {
                lineEnd -= 1
            }
        }
        let lineLen = lineEnd - lineRange.location
        guard lineLen >= 2 else { return false }
        let first = nsBody.character(at: lineRange.location)
        let second = nsBody.character(at: lineRange.location + 1)
        // Bullet prefix is `- ` or `* `, and must NOT be a checklist line
        // (checklist handling owns those — `- [ ] foo` etc.).
        guard (first == 0x2D /* - */ || first == 0x2A /* * */),
              second == 0x20 else { return false }
        if first == 0x2D, lineLen >= 6 {
            let third = nsBody.character(at: lineRange.location + 2)
            let fourth = nsBody.character(at: lineRange.location + 3)
            let fifth = nsBody.character(at: lineRange.location + 4)
            if third == 0x5B /* [ */,
               (fourth == 0x20 || fourth == 0x78 || fourth == 0x58),
               fifth == 0x5D /* ] */ {
                return false  // checklist — defer to handleChecklistReturn
            }
        }

        // Empty bullet line + caret at end of prefix → strip and exit.
        if lineLen == 2, selection.location == lineRange.location + 2 {
            let stripRange = NSRange(location: lineRange.location, length: 2)
            guard textView.shouldChangeText(in: stripRange, replacementString: "") else { return false }
            textView.replaceCharacters(in: stripRange, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        // Caret must sit past the prefix to trigger continuation.
        guard selection.location >= lineRange.location + 2 else { return false }

        let markerChar: String = first == 0x2D ? "-" : "*"
        let insertion = "\n\(markerChar) "
        guard textView.shouldChangeText(in: selection, replacementString: insertion) else { return false }
        textView.replaceCharacters(in: selection, with: insertion)
        textView.didChangeText()
        let newCaret = selection.location + (insertion as NSString).length
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        return true
    }

    /// Enter continuation for numbered-list lines (`<digits>+. `). Mirrors
    /// `handleBulletReturn`: continue with `\n<n+1>. ` on a non-empty line;
    /// strip the prefix and exit when Enter is pressed on an otherwise-empty
    /// numbered line. Subsequent lines are NOT renumbered — the user can
    /// re-toggle the list via the toolbar to clean up numbering if needed.
    static func handleNumberedReturn(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let lineRange = nsBody.lineRange(for: selection)
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > lineRange.location {
            let lastChar = nsBody.character(at: lineEnd - 1)
            if lastChar == 0x0A || lastChar == 0x0D {
                lineEnd -= 1
            }
        }
        let lineLen = lineEnd - lineRange.location
        guard lineLen >= 3 else { return false }

        // Scan leading digits.
        var digitCount = 0
        while digitCount < lineLen {
            let c = nsBody.character(at: lineRange.location + digitCount)
            guard c >= 0x30 /* 0 */, c <= 0x39 /* 9 */ else { break }
            digitCount += 1
        }
        guard digitCount > 0,
              lineLen >= digitCount + 2,
              nsBody.character(at: lineRange.location + digitCount) == 0x2E /* . */,
              nsBody.character(at: lineRange.location + digitCount + 1) == 0x20 else {
            return false
        }
        let prefixLen = digitCount + 2
        let digitsRange = NSRange(location: lineRange.location, length: digitCount)
        let digits = nsBody.substring(with: digitsRange)
        let currentNumber = Int(digits) ?? 0

        // Empty numbered line + caret at end of prefix → strip and exit.
        if lineLen == prefixLen, selection.location == lineRange.location + prefixLen {
            let stripRange = NSRange(location: lineRange.location, length: prefixLen)
            guard textView.shouldChangeText(in: stripRange, replacementString: "") else { return false }
            textView.replaceCharacters(in: stripRange, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        guard selection.location >= lineRange.location + prefixLen else { return false }

        let nextNumber = currentNumber + 1
        let insertion = "\n\(nextNumber). "
        guard textView.shouldChangeText(in: selection, replacementString: insertion) else { return false }
        textView.replaceCharacters(in: selection, with: insertion)
        textView.didChangeText()
        let newCaret = selection.location + (insertion as NSString).length
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        return true
    }

    /// Applies markdown wrap directly on an NSTextView using AppKit's edit
    /// sandwich: `shouldChangeText` → `replaceCharacters` → `didChangeText`.
    /// This registers the change on the text view's own `undoManager`
    /// automatically — no manual `UndoManager.registerUndo` is needed.
    ///
    /// Called from two paths (D-R-03):
    ///   1. `EditorPaneView.wrapSelection(prefix:suffix:)` — toolbar button taps.
    ///   2. `AppDelegate.formatBold(_:)` / `formatItalic(_:)` / `formatInlineCode(_:)`
    ///      / `formatLink(_:)` — menu actions (Plan 04 wires these).
    ///
    /// The edit is applied to the SELECTION range only (not the full body —
    /// RESEARCH Code Examples refinement). The cursor location returned by
    /// `applyMarkdownWrap` is computed against the full body and is used
    /// verbatim for `setSelectedRange`.
    ///
    /// Pattern source: NSTextView documentation (shouldChangeText /
    /// replaceCharacters / didChangeText) + christiantietze.de/posts/2022/09/
    /// undoable-text-changes (the sandwich is the canonical Apple pattern for
    /// programmatic edits that participate in the NSTextView undo stack).
    static func performWrap(prefix: String, suffix: String, in textView: NSTextView) {
        let body = textView.string
        let range = textView.selectedRange()

        // quick-260523-29t: arm-or-edit fork for empty selections on inline
        // formats. When the user fires Cmd+B (or any of the 5 inline shortcuts)
        // with NO selected text, we suppress marker insertion and instead arm
        // the next-typed character's style. This matches TextEdit / Pages /
        // Notes rich-text behavior. The fork takes the ARM path only when
        // ALL of:
        //   a. textView is a HybridTextView (state lives on the subclass)
        //   b. selection is caret-only (length 0)
        //   c. prefix maps to one of the 5 inline kinds (NOT link `[`)
        //   d. caret is NOT inside a fenced code block (F-05 inert)
        //   e. caret is NOT inside an existing same-kind pair (the existing
        //      universal toggle-off path in applyMarkdownWrap handles that
        //      case correctly — strip the markers — so we fall through)
        //
        // When ARM is taken, ZERO body mutation occurs: no shouldChangeText
        // sandwich, no push-token bump, no undo state. This is purely an
        // in-memory flag flip on the HybridTextView.
        if range.length == 0,
           let htv = textView as? HybridTextView,
           let requestedKind = inlineKind(forPrefix: prefix) {

            // (d) Fenced-code-block check (mirrors the F-05 branch in
            // applyMarkdownWrap at line 119-136).
            var insideFence = false
            for fence in MarkdownInlineParser.findFencedCodeBlocks(in: body) {
                let fenceContent = fence.contentRange
                let startInside = range.location >= fenceContent.location
                    && range.location <= fenceContent.location + fenceContent.length
                if startInside {
                    insideFence = true
                    break
                }
            }
            if insideFence {
                // Silent no-op — no body edit, no arm state set. F-05 parity.
                return
            }

            // (e) Same-kind enclosing-pair check — re-uses the universal
            // toggle-off detection. If the caret sits inside an existing pair
            // of the SAME kind, fall through to applyMarkdownWrap so the
            // pair is stripped (toggle-off). For different-kind pairs we
            // also fall through (the existing swap / nest logic owns it).
            let existingPairKind = activeInlineKind(body: body, selection: range)
            if existingPairKind == requestedKind {
                // Fall through to the strip path below.
            } else {
                // ARM path — no body mutation. Update state + publish + return.
                let newState = armedInlineKindsAfterArm(
                    current: (htv.armedInlineKinds, htv.armedInlineKindsOrder),
                    requestedKind: requestedKind
                )
                htv.armedInlineKinds = newState.set
                htv.armedInlineKindsOrder = newState.order
                htv.republishArmedKinds()
                return
            }
        }

        let (newBody, cursor) = applyMarkdownWrap(
            prefix: prefix,
            suffix: suffix,
            body: body,
            range: range
        )

        // Build the replacement for the SELECTION range only.
        let inserted: String
        if range.length == 0 {
            inserted = prefix + suffix
        } else {
            let selected = (body as NSString).substring(with: range)
            inserted = prefix + selected + suffix
        }

        // Classify the transformation by comparing `newBody` to what a pure
        // additive wrap of the selection would produce. Three outcomes:
        //   • additive  → newBody == selection-only insert of prefix+sel+suffix
        //   • strip     → non-additive AND body shrank by prefixLen+suffixLen
        //                 (same-kind toggle-off)
        //   • swap      → non-additive AND body-delta doesn't match strip
        //                 (different-kind inline swap, e.g. **x** → *x*)
        let prefixLen = (prefix as NSString).length
        let suffixLen = (suffix as NSString).length
        let bodyDelta = (body as NSString).length - (newBody as NSString).length
        let originalSelectedLength = range.length
        let expectedAdditiveBody = (body as NSString).replacingCharacters(in: range, with: inserted)
        let isAdditive = newBody == expectedAdditiveBody
        let didStripSameKind = !isAdditive && bodyDelta == prefixLen + suffixLen
        let didSwap = !isAdditive && !didStripSameKind

        // Selection restore:
        //   - strip, caret-only (length 0) → caret lands at returned cursor
        //   - strip, selection wraps markers → inner text is shorter by bodyDelta
        //   - strip, selection between markers → inner span length unchanged
        //   - additive wrap, non-empty selection (non-link) → re-select inner
        //     so repeated ⌘B toggles the same word cleanly
        //   - additive wrap, empty selection OR link → collapse to returned cursor
        //   - swap, non-empty selection → re-select the new inner text so ⌘B
        //     again toggles off cleanly; located by re-running the inline-pair
        //     detector on the new body at the returned cursor position
        //   - swap, caret-only → collapse to returned cursor
        let effectiveCursor: Int
        let newSelectionLength: Int
        if didStripSameKind {
            effectiveCursor = cursor
            if originalSelectedLength > 0 {
                let sel = (body as NSString).substring(with: range) as NSString
                let selWrapsMarkers = (sel.hasPrefix(prefix) && sel.hasSuffix(suffix))
                    || (prefix == "*" && sel.hasPrefix("_") && sel.hasSuffix("_"))
                newSelectionLength = selWrapsMarkers
                    ? originalSelectedLength - bodyDelta
                    : originalSelectedLength
            } else {
                newSelectionLength = 0
            }
        } else if didSwap && originalSelectedLength > 0 {
            // Locate the new pair by probing the new body at the returned
            // cursor — that position is guaranteed to be inside the new inner.
            let probe = NSRange(location: cursor, length: 0)
            if let newPair = findAnyEnclosingInlinePair(body: newBody, selection: probe) {
                effectiveCursor = newPair.inner.location
                newSelectionLength = newPair.inner.length
            } else {
                effectiveCursor = cursor
                newSelectionLength = 0
            }
        } else if isAdditive && originalSelectedLength > 0 && prefix != "[" {
            // Additive wrap of a real selection: re-select the newly-wrapped
            // inner text so repeated ⌘B toggles the same word cleanly. Link
            // (`[`) is excluded — that case wants the caret inside `()` ready
            // for URL entry (D-UX-01).
            effectiveCursor = range.location + prefixLen
            newSelectionLength = originalSelectedLength
        } else {
            effectiveCursor = cursor
            newSelectionLength = 0
        }

        // Additive → selection-only edit; strip or swap → paragraph-localized
        // replace. Inline pairs (bold/italic/code) cannot span paragraph
        // boundaries in CommonMark, so the paragraph containing the original
        // selection bounds the entire edit. Going wider (full-body) re-runs
        // the markdown reparse over every paragraph, which transiently re-
        // applies bodyParagraphStyle to H1 lines above before applyHeadings
        // restores h1ParagraphStyle — harmless in theory, but the round-trip
        // visibly nudged the text up one line height in practice.
        if isAdditive {
            guard textView.shouldChangeText(in: range, replacementString: inserted) else { return }
            textView.replaceCharacters(in: range, with: inserted)
            textView.didChangeText()
        } else {
            let nsBody = body as NSString
            let nsNewBody = newBody as NSString
            let paragraphRange = nsBody.paragraphRange(for: range)
            // Body delta is fully contained within this paragraph (strip/swap
            // never touches text outside the enclosing pair). Subtract from
            // the original paragraph length to get the new paragraph length.
            let bodyDeltaLen = nsBody.length - nsNewBody.length
            let newParagraphLength = paragraphRange.length - bodyDeltaLen
            let newParagraph = nsNewBody.substring(
                with: NSRange(location: paragraphRange.location, length: newParagraphLength)
            )
            guard textView.shouldChangeText(in: paragraphRange, replacementString: newParagraph) else { return }
            textView.replaceCharacters(in: paragraphRange, with: newParagraph)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: effectiveCursor, length: newSelectionLength))
    }

    /// Applies a line-prefix toggle (bulleted list) directly on an NSTextView,
    /// using the same edit-sandwich pattern as `performWrap`:
    /// `shouldChangeText` → `replaceCharacters` → `didChangeText`. Undo
    /// registers on `textView.undoManager` automatically (no manual
    /// `registerUndo` call).
    ///
    /// Called from two paths (mirrors `performWrap` — D-R-03):
    ///   1. `EditorPaneView.applyLinePrefix()` — toolbar button taps.
    ///      (Note: the toolbar path uses the $localBody mutation instead,
    ///      for the same SwiftUI-source-of-truth reason as wrapSelection.
    ///      Only the MENU path calls `performLinePrefix` directly.)
    ///   2. `AppDelegate.formatBulletedList(_:)` — ⌘⇧8 menu action.
    ///
    /// Edits only the line-block range (lineRange(for: selection)), not the
    /// full body. The caret/selection restore mirrors `performWrap`: for an
    /// empty selection on a single transformed line, the caret lands
    /// immediately after the inserted `"- "` so the user can start typing
    /// the bullet content. For multi-line or non-empty selection, the whole
    /// transformed block is re-selected so the next ⌘⇧8 can toggle it off.
    static func performLinePrefix(in textView: NSTextView) {
        let body = textView.string
        let range = textView.selectedRange()
        let (fullNewBody, _) = applyBulletedList(body: body, range: range)

        let nsBody = body as NSString
        let blockRange = nsBody.lineRange(for: range)

        // Extract the replacement block from fullNewBody at the same start
        // offset. blockRange.location is unchanged by the transform (the
        // edit is local to the block); the new block's length is the old
        // block's length plus the delta in total body length.
        let deltaLength = (fullNewBody as NSString).length - nsBody.length
        let newBlockLength = blockRange.length + deltaLength
        let newBlock = (fullNewBody as NSString).substring(
            with: NSRange(location: blockRange.location, length: newBlockLength)
        )

        // Edit sandwich — registers undo on textView.undoManager automatically.
        guard textView.shouldChangeText(in: blockRange, replacementString: newBlock) else { return }
        textView.replaceCharacters(in: blockRange, with: newBlock)
        textView.didChangeText()

        // Caret / selection restore:
        //   - Empty selection AND single-line result → caret AFTER the "- "
        //     (add mode) or at line start (strip mode). Detect by length
        //     delta: positive → we added "- " → caret at location + 2.
        //   - Otherwise → re-select the full transformed block.
        if range.length == 0, !newBlock.contains("\n") {
            let caretOffset = deltaLength > 0 ? 2 : 0
            textView.setSelectedRange(
                NSRange(location: blockRange.location + max(0, caretOffset), length: 0)
            )
        } else {
            textView.setSelectedRange(
                NSRange(location: blockRange.location, length: (newBlock as NSString).length)
            )
        }
    }

    /// Applies a heading-level toggle directly on an NSTextView. Mirrors
    /// `performLinePrefix` (D-R-03): same edit-sandwich pattern, same
    /// caret/selection restore semantics.
    ///
    /// Called from two paths:
    ///   1. `EditorPaneView.applyHeadingLevel(level:)` — toolbar dropdown.
    ///   2. `AppDelegate.formatHeading{1,2,3,Body}(_:)` — Format menu shortcuts.
    static func performHeadingLevel(in textView: NSTextView, level: Int?) {
        let body = textView.string
        let range = textView.selectedRange()
        let (fullNewBody, _) = applyHeadingLevel(body: body, range: range, level: level)

        let nsBody = body as NSString
        let blockRange = nsBody.lineRange(for: range)

        let deltaLength = (fullNewBody as NSString).length - nsBody.length
        let newBlockLength = blockRange.length + deltaLength
        let newBlock = (fullNewBody as NSString).substring(
            with: NSRange(location: blockRange.location, length: newBlockLength)
        )

        guard textView.shouldChangeText(in: blockRange, replacementString: newBlock) else { return }
        textView.replaceCharacters(in: blockRange, with: newBlock)
        textView.didChangeText()

        // Caret restore mirrors performLinePrefix:
        //   - Empty selection AND single-line result → caret AFTER the new
        //     heading prefix (or at line start if the level was stripped).
        //     Compute the new prefix length by scanning leading hashes on
        //     the new line — handles add (+N), strip (-N), and swap (Δ).
        //   - Otherwise → re-select the full transformed block.
        if range.length == 0, !newBlock.contains("\n") {
            let ns = newBlock as NSString
            var hashes = 0
            while hashes < ns.length, ns.character(at: hashes) == 0x23 {
                hashes += 1
            }
            let prefixLen: Int
            if hashes >= 1, hashes <= 6,
               hashes < ns.length, ns.character(at: hashes) == 0x20 {
                prefixLen = hashes + 1
            } else {
                prefixLen = 0
            }
            textView.setSelectedRange(
                NSRange(location: blockRange.location + prefixLen, length: 0)
            )
        } else {
            textView.setSelectedRange(
                NSRange(location: blockRange.location, length: (newBlock as NSString).length)
            )
        }
    }

    /// Applies a numbered-list toggle directly on an NSTextView. Mirrors
    /// `performLinePrefix` (D-R-03): same edit-sandwich pattern, same caret
    /// restore semantics. For empty selection on a single transformed line,
    /// the caret lands AFTER the inserted `"<n>. "` so the user can start
    /// typing immediately; for multi-line or non-empty selection, the whole
    /// block is re-selected so the next ⌘⇧7 can toggle off cleanly.
    static func performNumberedList(in textView: NSTextView) {
        let body = textView.string
        let range = textView.selectedRange()
        let (fullNewBody, _) = applyNumberedList(body: body, range: range)

        let nsBody = body as NSString
        let blockRange = nsBody.lineRange(for: range)

        let deltaLength = (fullNewBody as NSString).length - nsBody.length
        let newBlockLength = blockRange.length + deltaLength
        let newBlock = (fullNewBody as NSString).substring(
            with: NSRange(location: blockRange.location, length: newBlockLength)
        )

        guard textView.shouldChangeText(in: blockRange, replacementString: newBlock) else { return }
        textView.replaceCharacters(in: blockRange, with: newBlock)
        textView.didChangeText()

        // Caret restore: empty selection + single-line result → caret after
        // the new `<digits>. ` prefix (or at line start if stripped). Compute
        // prefix length on the resulting line by scanning leading digits.
        if range.length == 0, !newBlock.contains("\n") {
            let ns = newBlock as NSString
            var i = 0
            while i < ns.length, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39 {
                i += 1
            }
            let prefixLen: Int
            if i > 0, i + 1 < ns.length,
               ns.character(at: i) == 0x2E, ns.character(at: i + 1) == 0x20 {
                prefixLen = i + 2
            } else {
                prefixLen = 0
            }
            textView.setSelectedRange(
                NSRange(location: blockRange.location + prefixLen, length: 0)
            )
        } else {
            textView.setSelectedRange(
                NSRange(location: blockRange.location, length: (newBlock as NSString).length)
            )
        }
    }

    /// Applies a block-quote toggle directly on an NSTextView. Mirrors
    /// `performLinePrefix` exactly — `"> "` is a fixed 2-char prefix so the
    /// caret arithmetic matches the bulleted-list shape.
    static func performBlockQuote(in textView: NSTextView) {
        let body = textView.string
        let range = textView.selectedRange()
        let (fullNewBody, _) = applyBlockQuote(body: body, range: range)

        let nsBody = body as NSString
        let blockRange = nsBody.lineRange(for: range)

        let deltaLength = (fullNewBody as NSString).length - nsBody.length
        let newBlockLength = blockRange.length + deltaLength
        let newBlock = (fullNewBody as NSString).substring(
            with: NSRange(location: blockRange.location, length: newBlockLength)
        )

        guard textView.shouldChangeText(in: blockRange, replacementString: newBlock) else { return }
        textView.replaceCharacters(in: blockRange, with: newBlock)
        textView.didChangeText()

        if range.length == 0, !newBlock.contains("\n") {
            let caretOffset = deltaLength > 0 ? 2 : 0
            textView.setSelectedRange(
                NSRange(location: blockRange.location + max(0, caretOffset), length: 0)
            )
        } else {
            textView.setSelectedRange(
                NSRange(location: blockRange.location, length: (newBlock as NSString).length)
            )
        }
    }

    /// Enter handler for thematic-break lines. Defense-in-depth: production
    /// code paths can't reach this anymore because `HybridTextView.snapCaretOutOfHR`
    /// prevents the caret from landing on an HR line in the first place.
    /// The handler stays for direct programmatic invocations and unit-test
    /// coverage of the underlying invariant — "Enter on an HR line must not
    /// fall through to default `insertNewline:`, which would inherit
    /// `.sidekickThematicBreak` via typing attributes and stack hairlines."
    ///
    /// Branches on caret offset within the HR line:
    ///   • offset 0: escape UP — pure caret move to the line above (or
    ///     open a fresh `\n` at the doc-start case where there is none).
    ///   • offset > 0: escape DOWN — insert a `\n` AFTER the HR's trailing
    ///     `\n` (at `lineEnd`) and park the caret on the new blank line.
    ///     Safe from hairline stacking: the insertion is in a NEW paragraph
    ///     adjacent to the HR's `\n` (no TB attr), and the reparse only
    ///     re-applies `.sidekickThematicBreak` to the `---` range itself.
    ///
    /// Returns true when handled.
    static func handleThematicBreakReturn(in textView: NSTextView) -> Bool {
        let body = textView.string
        let nsBody = body as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        guard let storage = textView.textStorage, storage.length > 0 else { return false }

        let lineRange = nsBody.lineRange(for: selection)
        guard lineRange.length > 0,
              lineRange.location < storage.length,
              storage.attribute(.sidekickThematicBreak,
                                at: lineRange.location,
                                effectiveRange: nil) != nil else { return false }

        let offsetInLine = selection.location - lineRange.location

        // RIGHT EDGE (offset > 0): escape DOWN. Insert `\n` at lineEnd
        // (one past the HR's trailing `\n`, or at storage.length if the HR
        // is the final block with no trailing `\n`) and place the caret on
        // the new blank line.
        if offsetInLine > 0 {
            let lineEnd = lineRange.location + lineRange.length
            let editRange = NSRange(location: lineEnd, length: 0)
            guard textView.shouldChangeText(in: editRange, replacementString: "\n") else { return false }
            textView.replaceCharacters(in: editRange, with: "\n")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineEnd, length: 0))
            return true
        }

        // LEFT EDGE, doc-start HR: no separator line above. Open one with
        // a clean `\n` (no TB attrs via shouldChangeText sandwich →
        // typingAttributes path; at location 0 there is no preceding
        // TB-tagged char to inherit from) and place the caret on it.
        if lineRange.location == 0 {
            let editRange = NSRange(location: 0, length: 0)
            guard textView.shouldChangeText(in: editRange, replacementString: "\n") else { return false }
            textView.replaceCharacters(in: editRange, with: "\n")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return true
        }

        // LEFT EDGE, normal HR: pure caret move — no text mutation, no
        // shouldChangeText needed. Position `lineRange.location - 1` is
        // the `\n` of the line above; selecting that location places the
        // caret at the END of that line (which is the empty separator),
        // ready for typing.
        textView.setSelectedRange(NSRange(location: lineRange.location - 1, length: 0))
        return true
    }

    /// Inserts a markdown thematic break (`---`) on its own line below the
    /// caret line. One-shot insert — no toggle-off path.
    ///
    /// Insertion shape always sandwiches `---` between blank lines so the
    /// rendered hairline has breathing room above and below — matches the
    /// Bear / Typora / Notion convention (HR feels like a section break, not
    /// a divider squeezed against text). The leading blank line is NOT a
    /// parser requirement: `findThematicBreaks` accepts any line that is
    /// only dashes regardless of what's above it (the setext-H2
    /// disambiguation guard was intentionally removed — see parser comment).
    ///
    /// Edit-sandwich pattern matches `performBlockQuote`. Caret lands on a
    /// real empty line BELOW the inserted `---`. Each insertion always
    /// terminates with `\n\n` (hairline-line `\n` + new-blank-line `\n`) and
    /// the caret is set to the position right before that final `\n` —
    /// otherwise AppKit can render a past-end caret with upstream affinity
    /// at the end of the (visually empty) hairline line, which looks like
    /// the caret is sitting on the rule itself.
    static func performInsertThematicBreak(in textView: NSTextView) {
        let nsBody = textView.string as NSString
        let range = textView.selectedRange()

        // Bail when the caret is inside a fenced code block — inserting `---`
        // there would (a) be semantically wrong (HR inside code), and (b) the
        // leading `\n` we'd prepend would manufacture the blank-line precondition
        // for the parser's thematic-break match, drawing a hairline through code.
        // Silent `return` matches the existing toolbar bail convention in this
        // file (no NSBeep — see lines ~1530/1550).
        let fenceContentRanges = MarkdownInlineParser.findFencedCodeBlocks(in: textView.string)
            .map(\.contentRange)
        if fenceContentRanges.contains(where: { NSLocationInRange(range.location, $0) }) {
            return
        }

        let lineRange = nsBody.lineRange(for: range)
        let lineEnd = lineRange.location + lineRange.length
        let lineText = lineRange.length > 0 ? nsBody.substring(with: lineRange) : ""
        let lineHasContent = !lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let endsWithNewline = lineRange.length > 0 && nsBody.character(at: lineEnd - 1) == 0x0A

        // Build the insertion. For non-empty current lines we need a blank
        // line BEFORE `---` (parser disambiguates from setext-H2). All
        // variants end with `---\n\n` so there's a real empty line below
        // the rule for the caret to anchor on.
        let insertion: String
        if !lineHasContent {
            // Existing empty line above already serves as the separator.
            insertion = "---\n\n"
        } else if endsWithNewline {
            insertion = "\n---\n\n"
        } else {
            // Last line of doc, no trailing newline — prepend one to open
            // the blank-line separator above the rule.
            insertion = "\n\n---\n\n"
        }

        let editRange = NSRange(location: lineEnd, length: 0)
        guard textView.shouldChangeText(in: editRange, replacementString: insertion) else { return }
        textView.replaceCharacters(in: editRange, with: insertion)
        textView.didChangeText()

        // Place caret one before the trailing `\n` so it sits at the start of
        // the new empty line below the rule (a real character position, not a
        // past-end phantom — the latter renders unpredictably when the line
        // immediately above has all-hidden glyphs).
        let caretAfter = lineEnd + (insertion as NSString).length - 1
        textView.setSelectedRange(NSRange(location: caretAfter, length: 0))
    }
}

/// Single toolbar button — 28×28 hit target with rounded-rect background that
/// shows hover (subtle gray) and active (accent-tinted) states. Plain button
/// style so the background is fully under our control; borderless was leaving
/// the button feeling dead with no hover affordance, which hurt discoverability.
private struct FormatButton: View {
    let systemName: String
    let tooltip: String
    let accessibilityLabel: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(backgroundColor)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isActive { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }
}

/// "Aa" trigger button — the only control that lives on the toolbar bar
/// itself. Clicking it opens the formatting popover. Visual treatment
/// mirrors `FormatButton` (28pt height, 6pt corner, hover background) so
/// the toolbar reads as one button family — the only difference is the
/// glyph: a styled "Aa" text mark instead of an SF Symbol, matching Apple
/// Notes' custom mark.
private struct FormatPopoverTrigger: View {
    @Binding var isOpen: Bool

    @State private var isHovered = false

    var body: some View {
        Button(action: { isOpen.toggle() }) {
            Text("Aa")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(backgroundColor)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Formatting")
        .accessibilityLabel("Formatting")
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isOpen { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }
}

/// Apple Notes-style formatting panel. Two regions:
///   • Inline row: B / I / U / S — tapping applies wrap and KEEPS the
///     popover open so the user can stack inline formats. Strikethrough
///     and underline use `~~text~~` and `<u>text</u>` respectively (the
///     latter via HTML, since standard CommonMark has no underline syntax).
///   • Paragraph styles: Heading / Subheading / Body / Bulleted List /
///     Numbered List / Block Quote. Tap applies and CLOSES the popover —
///     these are mutually exclusive picks, not stackable toggles. Heading
///     levels show a leading checkmark when the caret's line matches; list
///     types currently never show a checkmark (active-state line-prefix
///     tracking is a follow-up — Apple Notes also doesn't track these
///     visually for non-heading rows).
///
/// Heading 3 is intentionally absent from the popover (parity with Apple
/// Notes' two-level Title/Heading-Subheading scheme — Title lives in its
/// own field above the toolbar, so the popover starts at H1). The ⌘⌥3
/// shortcut still fires `formatHeading3` via AppDelegate; this hides H3
/// from the visual surface only.
private struct FormattingPopoverView: View {
    let wrapSelection: (String, String) -> Void
    let applyLinePrefix: () -> Void
    let applyHeading: (Int?) -> Void
    let applyNumberedList: () -> Void
    let applyBlockQuote: () -> Void
    let applyChecklist: () -> Void
    let insertThematicBreak: () -> Void
    let activeInlineKind: FormattingToolbarView.InlineKind?
    let activeHeadingLevel: Int?
    let activeLinePrefix: FormattingToolbarView.LinePrefix?
    /// quick-260523-29t: armed inline kinds. OR-ed into each inline button's
    /// isActive so the toolbar reflects "armed for next-typed character" the
    /// same way it reflects "caret inside an existing pair".
    let armedInlineKinds: Set<FormattingToolbarView.InlineKind>
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inline row — popover dismisses after each tap so it doesn't
            // hide the text the user just formatted. Multi-format stacking
            // is still possible via repeated keyboard shortcuts (⌘B / ⌘I /
            // ⌘U / ⌘⇧X) which don't open the popover.
            HStack(spacing: 2) {
                FormatButton(
                    systemName: "bold",
                    tooltip: "Bold (⌘B)",
                    accessibilityLabel: "Bold",
                    isActive: activeInlineKind == .bold || armedInlineKinds.contains(.bold)
                ) { wrapSelection("**", "**"); dismiss() }

                FormatButton(
                    systemName: "italic",
                    tooltip: "Italic (⌘I)",
                    accessibilityLabel: "Italic",
                    isActive: activeInlineKind == .italic || armedInlineKinds.contains(.italic)
                ) { wrapSelection("*", "*"); dismiss() }

                FormatButton(
                    systemName: "underline",
                    tooltip: "Underline (⌘U)",
                    accessibilityLabel: "Underline",
                    isActive: activeInlineKind == .underline || armedInlineKinds.contains(.underline)
                ) { wrapSelection("<u>", "</u>"); dismiss() }

                FormatButton(
                    systemName: "strikethrough",
                    tooltip: "Strikethrough (⌘⇧X)",
                    accessibilityLabel: "Strikethrough",
                    isActive: activeInlineKind == .strikethrough || armedInlineKinds.contains(.strikethrough)
                ) { wrapSelection("~~", "~~"); dismiss() }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            // Paragraph styles — single pick, dismisses popover after tap.
            VStack(spacing: 2) {
                ParagraphStyleRow(
                    label: "Heading",
                    labelFont: .system(size: 17, weight: .semibold),
                    isActive: activeHeadingLevel == 1
                ) { applyHeading(1); dismiss() }

                ParagraphStyleRow(
                    label: "Subheading",
                    labelFont: .system(size: 15, weight: .semibold),
                    isActive: activeHeadingLevel == 2
                ) { applyHeading(2); dismiss() }

                ParagraphStyleRow(
                    label: "Body",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeHeadingLevel == nil
                ) { applyHeading(nil); dismiss() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            Divider()

            // List + quote types — visual marker baked into the row label
            // so the user sees what the prefix will look like.
            VStack(spacing: 2) {
                ParagraphStyleRow(
                    label: "•  Bulleted List",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .bullet
                ) { applyLinePrefix(); dismiss() }

                ParagraphStyleRow(
                    label: "1.  Numbered List",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .numbered
                ) { applyNumberedList(); dismiss() }

                ParagraphStyleRow(
                    label: "❘  Block Quote",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .blockquote
                ) { applyBlockQuote(); dismiss() }

                ParagraphStyleRow(
                    label: "□  Checklist",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: activeLinePrefix == .checklist
                ) { applyChecklist(); dismiss() }

                // One-shot insert — no toggle-off path (a thematic break has
                // no "active" state to highlight; clicking always emits one).
                ParagraphStyleRow(
                    label: "—  Horizontal Rule",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: false
                ) { insertThematicBreak(); dismiss() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 240)
    }
}

/// Single row in the paragraph-styles list. Leading 12pt slot reserved
/// for a checkmark (rendered always, opacity-toggled by `isActive`) so
/// active and inactive rows share a baseline — text doesn't shift when
/// the active state moves between rows.
private struct ParagraphStyleRow: View {
    let label: String
    let labelFont: Font
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .opacity(isActive ? 1 : 0)
                    .frame(width: 12)
                Text(label)
                    .font(labelFont)
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.07) : .clear)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
