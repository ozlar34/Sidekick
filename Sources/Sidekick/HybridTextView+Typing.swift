/// `HybridTextView` text-insertion path: the `insertText` override that
/// applies armed inline formatting, and the two typed triggers that convert
/// a line into a thematic break (trailing-HR escape, `/hr` + `/divider`).

import AppKit
import SwiftUI

extension HybridTextView {

    /// F-07: defense against macOS Character Viewer (emoji picker) handing us
    /// a stale `replacementRange` after our nonactivating panel briefly loses
    /// input-target status. Per FB13789916, the picker can capture a range at
    /// invocation time that no longer matches the textView's selection by the
    /// time the user picks an emoji and the picker fires `insertText:`. Honoring
    /// the stale range causes the next typed character to replace the just-
    /// inserted emoji. When we are NOT in active marked-text composition (so
    /// no IME composition is in flight) and the picker's range disagrees with
    /// our current selection, fall back to inserting at the current selection
    /// (`NSNotFound` per NSTextInputClient docs).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        var range = replacementRange
        if !hasMarkedText(),
           range.location != NSNotFound,
           !NSEqualRanges(range, selectedRange()) {
            range = NSRange(location: NSNotFound, length: 0)
        }

        // quick-260523-29t: armed-inline consumption-on-type. Layers BENEATH
        // the F-07 range fix so the consumption uses the sanitized range.
        // Only fires when ALL of:
        //   a. there is an armed inline kind
        //   b. no IME composition is in flight (hasMarkedText() == false)
        //   c. input is a printable, non-control single-character or longer
        //      run of printables (filters out Tab, Enter, etc.)
        //   d. caret is NOT inside a fenced code block (defensive — arming
        //      was already gated, but caret could have moved INTO a fence
        //      while armed and BEFORE the selection-cancel cleared it; F-05
        //      intent says drop consumption AND clear)
        // When consumption fires, the wrap is built from `composeArmedWrap`,
        // applied via the standard shouldChangeText/replaceCharacters/
        // didChangeText sandwich (single undo step), the caret is placed
        // between the typed char and the closing suffix, and armed state
        // is cleared (Design Note in HybridTextView.swift).
        if !armedInlineKinds.isEmpty, !hasMarkedText() {
            let effective: String
            if let s = string as? String {
                effective = s
            } else if let a = string as? NSAttributedString {
                effective = a.string
            } else {
                effective = ""
            }

            let isPrintable = !effective.isEmpty && effective.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }

            if isPrintable {
                // F-05 defense: drop consumption if caret is now inside a
                // fenced code block, AND clear armed state.
                let editRange: NSRange = (range.location == NSNotFound) ? selectedRange() : range
                let body = self.string
                var insideFence = false
                for fence in MarkdownInlineParser.findFencedCodeBlocks(in: body) {
                    let fenceContent = fence.contentRange
                    let editEnd = editRange.location + editRange.length
                    let startInside = editRange.location >= fenceContent.location
                        && editRange.location <= fenceContent.location + fenceContent.length
                    let endInside = editEnd >= fenceContent.location
                        && editEnd <= fenceContent.location + fenceContent.length
                    if startInside || endInside {
                        insideFence = true
                        break
                    }
                }

                if insideFence {
                    armedInlineKinds.removeAll()
                    armedInlineKindsOrder.removeAll()
                    republishArmedKinds()
                    super.insertText(string, replacementRange: range)
                    return
                }

                let (p, s) = FormattingToolbarView.composeArmedWrap(
                    order: armedInlineKindsOrder
                )
                let replacement = p + effective + s
                guard shouldChangeText(in: editRange, replacementString: replacement) else {
                    return
                }
                replaceCharacters(in: editRange, with: replacement)
                didChangeText()

                let caretLoc = editRange.location
                    + (p as NSString).length
                    + (effective as NSString).length
                // Suppress the side-effect selection-change cancel — the
                // selection move below is OUR programmatic caret placement,
                // not user navigation.
                suppressArmedClearOnNextSelectionChange = true
                setSelectedRange(NSRange(location: caretLoc, length: 0))

                // Clear armed state per Design Note (clear-on-consumption).
                armedInlineKinds.removeAll()
                armedInlineKindsOrder.removeAll()
                republishArmedKinds()
                return
            }
        }

        super.insertText(string, replacementRange: range)
        // WR-02: skip the post-insert HR helpers during active IME composition —
        // partial candidates must not trigger slash-convert or trailing-HR escape.
        // Mirrors the `!hasMarkedText()` discipline the armed-inline path enforces above.
        guard !hasMarkedText() else { return }
        // HR-04: Check for `/hr` / `/divider` quick-insert BEFORE the trailing-
        // HR escape — a completed slash trigger is not an HR line, so the escape
        // would not fire anyway, but returning early avoids the attribute probe.
        if handleSlashQuickInsertIfNeeded() { return }
        // HR-01: After super runs the reparse, ensure any freshly-typed trailing
        // HR has an editable line below it so the caret never gets stranded above
        // the rule. Mirrors the always-trailing-blank-line guarantee that
        // performInsertThematicBreak already provides for the toolbar path.
        escapeTypedTrailingHRIfNeeded()
    }

    // MARK: - HR-01: Typed-trailing-HR escape

    /// Appends a `\n` below a freshly-typed trailing thematic-break line so
    /// the caret always has an editable home below the rule.
    ///
    /// HR-01 parity with `performInsertThematicBreak`: the toolbar insertion
    /// routine always ends with `\n\n` (blank line below the rule + one more
    /// `\n`), guaranteeing a real editable line below every toolbar-inserted
    /// HR. The TYPED path (user types `---`, `***`, or `___` as the last line
    /// of a note) did not have this guarantee — after the third character the
    /// reparse fires and the line becomes a hairline, but with no `\n` below
    /// it the snap logic and AppKit both see "HR is the final block; nowhere
    /// to go below", and the caret effectively gets trapped above the rule.
    ///
    /// This helper detects the condition post-insert and appends a single `\n`
    /// via the standard shouldChangeText/didChangeText sandwich (undo-safe,
    /// single step) then parks the caret at the start of the new empty line.
    ///
    /// Guards (all must pass):
    ///   • `textStorage` exists and is non-empty
    ///   • zero-length selection (caret only)
    ///   • caret's line carries `.sidekickThematicBreak`
    ///   • that line is the final block (lineEnd == storage.length) — the HR
    ///     has no `\n` below it yet
    private func escapeTypedTrailingHRIfNeeded() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }

        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: sel)
        guard lineRange.length > 0 else { return }

        // Check the line carries .sidekickThematicBreak.
        guard storage.attribute(.sidekickThematicBreak,
                                at: lineRange.location,
                                effectiveRange: nil) != nil else { return }

        let lineEnd = lineRange.location + lineRange.length
        // Only fire when this HR is the FINAL block with no trailing `\n`.
        // If `lineEnd < storage.length` there is already content (or at least
        // a `\n`) below — the escape is not needed and must not fire.
        guard lineEnd == storage.length else { return }
        // Double-check: the line must NOT already end with a line terminator
        // (which would mean there IS a line below and `lineEnd == storage.length`
        // was a coincidence of the trailing-newline inclusive lineRange).
        guard FormattingToolbarView.lineContentEnd(lineRange, in: ns) == lineEnd else { return }

        appendLineBelowTrailingHR()
    }

    /// Appends a single `\n` at the end of the document via the undo-safe
    /// shouldChangeText/replaceCharacters/didChangeText sandwich, then parks
    /// the caret at the start of the new empty line below a trailing divider.
    /// Shared by the HR-01 typed escape above and by `moveRight`/`moveDown`
    /// when a note already ends in a divider (A3).
    // Internal (not private): also called from HybridTextView+CaretMovement.swift.
    func appendLineBelowTrailingHR() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let relayoutStart = lineStartAboveHRRun(containing: storage.length - 1)
        let editRange = NSRange(location: storage.length, length: 0)
        guard shouldChangeText(in: editRange, replacementString: "\n") else { return }
        replaceCharacters(in: editRange, with: "\n")
        didChangeText()
        // AppKit layout quirk: after an incremental edit next to a divider,
        // the line above keeps a stale layout, and AppKit's own Left/Right on
        // it jump to the line's ends (Left 3 → 0, Right 0 → 3 in `one\n---`).
        // A fresh glyph and layout pass over that line and the divider run
        // clears it. The full repaint is needed too: the old hairline was drawn
        // on the line above, and a range-based display invalidation (computed
        // before the lazy relayout) leaves it on screen. A divider typed
        // mid-note has the same quirk and is not covered here (open follow-up).
        if let layoutManager {
            let relayoutRange = NSRange(location: relayoutStart, length: storage.length - relayoutStart)
            layoutManager.invalidateGlyphs(forCharacterRange: relayoutRange, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: relayoutRange, actualCharacterRange: nil)
            needsDisplay = true
        }
        // Park the caret at the start of the new empty line.
        setSelectedRange(NSRange(location: storage.length, length: 0))
    }

    // MARK: - HR-04: `/hr` + `/divider` quick-insert

    /// Detects when the user has typed `/hr` or `/divider` as the sole
    /// content of a line (exact-match, caret at end) and converts it to a
    /// thematic break by reusing the canonical `performInsertThematicBreak`
    /// routine.
    ///
    /// HR-04 affordance: mirrors how Markdown editors auto-convert `- ` to a
    /// bullet — an inline auto-convert trigger that fires on an exact
    /// line-level match. Both `/hr` and `/divider` are supported for
    /// discoverability. The implementation delegates entirely to
    /// `FormattingToolbarView.performInsertThematicBreak(in:)` so the
    /// inserted rule has identical breathing-room and caret-placement
    /// behavior to the toolbar button — single source of truth.
    ///
    /// Guards (all must pass):
    ///   • `textStorage` exists
    ///   • zero-length selection (caret only)
    ///   • line content (stripped of trailing newline) is exactly "/hr" or "/divider"
    ///   • caret is at the end of the stripped content (full-line-exact match)
    ///
    /// Returns `true` when the quick-insert fired (caller should `return`
    /// immediately to skip the trailing-HR escape, which does not apply).
    @discardableResult
    private func handleSlashQuickInsertIfNeeded() -> Bool {
        guard let storage = textStorage else { return false }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }

        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: sel)
        guard lineRange.length > 0 else { return false }

        // Strip any trailing line terminator to get the visible content of the line.
        let contentLength = FormattingToolbarView.lineContentEnd(lineRange, in: ns) - lineRange.location
        guard contentLength > 0 else { return false }
        let lineContent = ns.substring(with: NSRange(location: lineRange.location, length: contentLength))

        // Exact-match check — caret must be at the end of the content.
        guard lineContent == "/hr" || lineContent == "/divider" else { return false }
        guard sel.location == lineRange.location + contentLength else { return false }

        // WR-01: never quick-insert inside a fenced code block. performInsertThematicBreak
        // has its own fence guard and bails — but only AFTER we'd have deleted the trigger,
        // silently eating the user's literal `/hr`. Bail here, before any mutation, so the
        // typed text stays as source inside the fence.
        let fenceContentRanges = MarkdownInlineParser.findFencedCodeBlocks(in: storage.string).map(\.contentRange)
        if fenceContentRanges.contains(where: { NSLocationInRange(sel.location, $0) }) { return false }

        // Delete the slash trigger first so performInsertThematicBreak starts
        // from a clean empty line (it already handles the case where the
        // current line is empty — it uses the existing blank line as its
        // leading separator).
        let cmdRange = NSRange(location: lineRange.location, length: contentLength)
        guard shouldChangeText(in: cmdRange, replacementString: "") else { return false }
        replaceCharacters(in: cmdRange, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location, length: 0))

        // Delegate to the canonical HR insertion routine (single source of
        // truth for HR insertion — same as the toolbar button).
        FormattingToolbarView.performInsertThematicBreak(in: self)
        return true
    }
}
