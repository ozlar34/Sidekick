import AppKit
import SwiftUI

/// Markdown formatting toolbar shown below the TextEditor in edit mode.
/// Buttons call the `wrapSelection` closure (provided by EditorPaneView)
/// which bridges to NSTextView. All string manipulation logic is
/// extracted into `applyMarkdownWrap` (pure, unit-testable — no AppKit).
struct FormattingToolbarView: View {
    let wrapSelection: (String, String) -> Void
    let applyLinePrefix: () -> Void
    /// Set when the caret is inside a bold / italic / code span. Drives the
    /// active-state highlight on the corresponding button. Defaults to nil so
    /// existing call sites (tests, previews, menu-only invocations) compile
    /// without change. Populated by EditorPaneView from
    /// HybridEditorController.activeInlineKind.
    var activeInlineKind: InlineKind? = nil

    var body: some View {
        HStack(spacing: 2) {
            FormatButton(
                systemName: "bold",
                tooltip: "Bold (⌘B)",
                accessibilityLabel: "Bold",
                isActive: activeInlineKind == .bold
            ) { wrapSelection("**", "**") }

            FormatButton(
                systemName: "italic",
                tooltip: "Italic (⌘I)",
                accessibilityLabel: "Italic",
                isActive: activeInlineKind == .italic
            ) { wrapSelection("*", "*") }

            FormatButton(
                systemName: "chevron.left.forwardslash.chevron.right",
                tooltip: "Inline code (⌘⌥C)",
                accessibilityLabel: "Inline code",
                isActive: activeInlineKind == .code
            ) { wrapSelection("`", "`") }

            FormatButton(
                systemName: "link",
                tooltip: "Link (⌘K)",
                accessibilityLabel: "Link",
                isActive: false
            ) { wrapSelection("[", "]()") }

            FormatButton(
                systemName: "list.bullet",
                tooltip: "Bulleted list (⌘⇧8)",
                accessibilityLabel: "Bulleted list",
                isActive: false
            ) { applyLinePrefix() }

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

        // MARK: Universal toggle-off / swap
        // The hybrid editor hides `**`/`*`/`` ` `` glyphs as zero-width, so the
        // caret/selection can land in subtly different byte positions for the
        // same visual click. Instead of case-matching on selection shape, ask
        // the parser: "is there an inline-kind pair on this line that the
        // selection overlaps or contains?" — if yes, transform it.
        //
        // Transform rules for inline formats (bold/italic/code):
        //   • same kind  → strip markers (toggle off).
        //   • different kind → swap: replace the pair's markers with the
        //     requested ones, keep inner text. Inline formats are mutually
        //     exclusive at toggle time (no composed ***bold-italic***).
        // Link (`prefix == "["`) intentionally skips this branch — ⌘K over
        // bold text should wrap the whole thing as a link, not strip it.
        let requestedKind: InlineKind? = inlineKind(forPrefix: prefix)
        if let kind = requestedKind,
           let pair = findAnyEnclosingInlinePair(body: body, selection: safeRange) {
            let innerText = nsBody.substring(with: pair.inner)
            if pair.kind == kind {
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
    internal enum InlineKind { case bold, italic, code }

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
        default:   return nil
        }
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

        // Additive → selection-only edit; strip or swap → full-body replace
        // (both alter bytes outside the original selection range).
        if isAdditive {
            guard textView.shouldChangeText(in: range, replacementString: inserted) else { return }
            textView.replaceCharacters(in: range, with: inserted)
            textView.didChangeText()
        } else {
            let fullRange = NSRange(location: 0, length: (body as NSString).length)
            guard textView.shouldChangeText(in: fullRange, replacementString: newBody) else { return }
            textView.replaceCharacters(in: fullRange, with: newBody)
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
                    RoundedRectangle(cornerRadius: 5)
                        .fill(backgroundColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
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
