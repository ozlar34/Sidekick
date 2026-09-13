/// `FormattingToolbarView` — Return / Backspace / forward-delete handlers for checklist, bullet,
/// numbered and thematic-break lines, and the shared `lineContentEnd` helper.

import AppKit
import SwiftUI

extension FormattingToolbarView {

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
        let lineEnd = lineContentEnd(lineRange, in: nsBody)
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
        let lineEnd = lineContentEnd(lineRange, in: nsBody)
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
        let lineEnd = lineContentEnd(lineRange, in: nsBody)
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
        let caretLineEnd = lineContentEnd(caretLine, in: nsBody)
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
        let caretLineEnd = lineContentEnd(caretLine, in: nsBody)
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
        let lineEnd = lineContentEnd(lineRange, in: nsBody)
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
        let lineEnd = lineContentEnd(lineRange, in: nsBody)
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

    /// End of `lineRange`'s content, excluding its terminator (`\n`, `\r` or `\r\n`).
    static func lineContentEnd(_ lineRange: NSRange, in ns: NSString) -> Int {
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: lineRange.location, length: 0))
        return contentsEnd
    }
}
