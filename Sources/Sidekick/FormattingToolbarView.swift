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
                        activeInlineKind: activeInlineKind,
                        activeHeadingLevel: activeHeadingLevel,
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
                isActive: false
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
    let activeInlineKind: FormattingToolbarView.InlineKind?
    let activeHeadingLevel: Int?
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
                    isActive: activeInlineKind == .bold
                ) { wrapSelection("**", "**"); dismiss() }

                FormatButton(
                    systemName: "italic",
                    tooltip: "Italic (⌘I)",
                    accessibilityLabel: "Italic",
                    isActive: activeInlineKind == .italic
                ) { wrapSelection("*", "*"); dismiss() }

                FormatButton(
                    systemName: "underline",
                    tooltip: "Underline (⌘U)",
                    accessibilityLabel: "Underline",
                    isActive: false
                ) { wrapSelection("<u>", "</u>"); dismiss() }

                FormatButton(
                    systemName: "strikethrough",
                    tooltip: "Strikethrough (⌘⇧X)",
                    accessibilityLabel: "Strikethrough",
                    isActive: false
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
                    isActive: false
                ) { applyLinePrefix(); dismiss() }

                ParagraphStyleRow(
                    label: "1.  Numbered List",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: false
                ) { applyNumberedList(); dismiss() }

                ParagraphStyleRow(
                    label: "❘  Block Quote",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: false
                ) { applyBlockQuote(); dismiss() }

                ParagraphStyleRow(
                    label: "◯  Checklist",
                    labelFont: .system(size: 13, weight: .regular),
                    isActive: false
                ) { applyChecklist(); dismiss() }
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
                    .foregroundColor(.primary)
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
