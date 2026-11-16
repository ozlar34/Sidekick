/// `FormattingToolbarView` — NSTextView block-format commands: the `perform*` edit sandwiches for
/// line prefixes, headings, lists, blockquote, checklist and thematic break,
/// plus the checklist-marker click toggle.

import AppKit
import SwiftUI

extension FormattingToolbarView {

    /// Applies a checklist toggle directly on an NSTextView. Mirrors
    /// `performBlockQuote` exactly — same edit-sandwich pattern, same caret
    /// restore semantics.
    static func performChecklist(in textView: NSTextView) {
        if let editor = textView as? NoteTextView { editor.perform(.checklist); return }   // the new editor acts on its note document
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
        if let editor = textView as? NoteTextView { editor.perform(.bullet); return }   // the new editor acts on its note document
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
        if let editor = textView as? NoteTextView { editor.perform(.heading(level)); return }   // the new editor acts on its note document
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
        if let editor = textView as? NoteTextView { editor.perform(.numbered); return }   // the new editor acts on its note document
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
        if let editor = textView as? NoteTextView { editor.perform(.quote); return }   // the new editor acts on its note document
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
        if let editor = textView as? NoteTextView { editor.perform(.rule); return }   // the new editor acts on its note document
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
