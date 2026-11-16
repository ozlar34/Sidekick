/// `FormattingToolbarView` — applyMarkdownWrap, InlineKind + active/armed inline-kind detection,
/// the enclosing-pair finder, and `performWrap` (the NSTextView inline wrap).

import AppKit
import SwiftUI

extension FormattingToolbarView {

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
        if let editor = textView as? NoteTextView {   // the new editor acts on its note document; a link asks for its address in a field
            switch prefix {
            case "**": editor.perform(.bold)
            case "*": editor.perform(.italic)
            case "<u>": editor.perform(.underline)
            case "~~": editor.perform(.strikethrough)
            case "`": editor.perform(.code)
            case "[": editor.beginLinkEdit()
            default: break
            }
            return
        }
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
}
