/// NSViewRepresentable wrapping the Sidekick hybrid markdown editor.
///
/// Owns the four-piece TextKit 1 assembly:
///   MarkdownTextStorage → MarkdownLayoutManager → NSTextContainer → NSTextView
/// Exposes a SwiftUI-visible @Binding var text: String that is the single
/// source of truth for the underlying markdown bytes. The Coordinator
/// bridges NSTextViewDelegate.textDidChange → binding.text, with an
/// infinite-loop guard (only write if values differ).
///
/// Placement: used by EditorPaneView.body's non-preview branch as a
/// drop-in replacement for TextEditor(text: $localBody). The SwiftUI
/// "Start writing..." overlay stays at the EditorPaneView level
/// (D-ES-04) because `text.isEmpty` is still observable from SwiftUI.
///
/// Pattern source: ResizeHandleView.swift (NSViewRepresentable + final-class
/// AppKit wrapper), FormattingToolbarView.swift (NSTextView edit-sandwich —
/// we don't re-implement but must not break it).
/// CONTEXT reference: .planning/phases/09-hybrid-editor-foundation/09-CONTEXT.md
///   D-ES-01, D-ES-03, D-ES-04, D-ST-01, D-ST-02.
import AppKit
import SwiftUI

/// NSTextView subclass that floors its frame height at the enclosing scroll
/// view's clip-view height. Without this, a short note's text view ends at
/// content height, leaving a "dead zone" below — clicks in that empty area
/// fall outside the text view's frame and never reach it. With the floor in
/// place, NSTextView's built-in "click below the last glyph → caret at end
/// of document" behavior covers the empty area for free, no mouseDown
/// override required.
///
/// Two paths feed the height update:
///   1. setConstrainedFrameSize — invoked by the layout manager after every
///      text edit. Flooring `desiredSize.height` at clip-view height makes
///      every layout-driven resize respect the floor.
///   2. clipFrameChanged — invoked when the scroll view (and thus the clip
///      view) resizes, e.g. window resize. Layout doesn't re-fire on a
///      height-only resize, so we re-floor explicitly here.
///
/// `widthTracksTextView` + `autoresizingMask = .width` continue to handle
/// width tracking; we only own the vertical floor.
/// Note: not `final` so test files can subclass with a local UndoManager
/// (windowless NSTextViews have no undoManager via the responder chain).
/// See `TestableHybridTextView` in ArmedInlineFormatTests.swift. Production
/// code never subclasses HybridTextView — there is exactly one instance
/// created in `HybridEditorView.makeNSView`.
class HybridTextView: NSTextView {
    // MARK: - Armed inline-format state (quick-260523-29t)
    //
    // "Hide markers on empty selection" UX: Cmd+B with caret-only selection
    // does NOT write `****` into the body; it arms the next-typed character's
    // style. State lives on the text view (the unique focused-editor source
    // of truth) and is mirrored upward through the weak `hybridController`
    // back-pointer so the toolbar can OR arming into its `isActive` highlight.
    //
    // Design Note (clear-on-consumption vs persist-until-cancel):
    //   The locked decisions hedged between these two behaviors. We CLEAR on
    //   consumption because the user-visible behavior is identical: after the
    //   first typed char, the caret sits between char and suffix — i.e. INSIDE
    //   an existing inline pair. The toolbar's `findAnyEnclosingInlinePair`
    //   path keeps the button highlighted as long as the caret stays inside.
    //   Subsequent typed chars naturally extend the pair via vanilla NSTextView
    //   insertion. On caret-move-out the inline-pair detector reports
    //   "not in a pair" and the button de-highlights. Strictly less state to
    //   track; revisit only if real UAT proves the simpler version feels wrong.

    /// Set of armed inline kinds. Empty when no Cmd+B/I/U/etc has been
    /// pressed with an empty selection (the default state).
    var armedInlineKinds: Set<FormattingToolbarView.InlineKind> = []

    /// Order of arming (innermost / first-armed → outermost / last-armed).
    /// Drives `composeArmedWrap`'s reading-order output. Kept in lockstep
    /// with `armedInlineKinds` by `FormattingToolbarView.armedInlineKindsAfterArm`.
    var armedInlineKindsOrder: [FormattingToolbarView.InlineKind] = []

    /// Weak back-pointer to the controller so the text view can republish
    /// arming changes upward. Set once in `HybridEditorView.makeNSView` right
    /// after `controller.textView = textView`. Weak to avoid the retain cycle
    /// (controller owns view-lifetime; we don't want the text view to keep
    /// the controller alive past its scope).
    weak var hybridController: HybridEditorController?

    /// One-shot flag — set to true immediately before a programmatic
    /// `setSelectedRange` call that participates in consumption-on-type, so
    /// the selection-change cancel branch in `setSelectedRanges` skips clearing
    /// the armed set on THAT specific call. AppKit fires selection-change as
    /// a side-effect of `replaceCharacters` + `setSelectedRange`, which would
    /// otherwise clear the armed set BEFORE consumption finishes.
    private var suppressArmedClearOnNextSelectionChange: Bool = false

    /// Republish armed kinds upward. Coalesced (skip write when value
    /// unchanged) for the same SwiftUI re-render reason as the other
    /// HybridEditorController publishers.
    func republishArmedKinds() {
        guard let c = hybridController else { return }
        if c.armedInlineKinds != armedInlineKinds {
            c.armedInlineKinds = armedInlineKinds
        }
    }

    /// Click-to-toggle for GFM task-list checkboxes. When the user clicks on
    /// the substituted ◯/◉ glyph (the leading `-` char of a task-list line),
    /// flip the state byte (` ` ↔ `x`) instead of moving the caret. Anywhere
    /// else, fall through to NSTextView's default cursor placement.
    ///
    /// Hit detection uses `glyphIndex(for:in:fractionOfDistanceThroughGlyph:)`:
    /// only treat as a hit if `fraction < 1.0` (the click landed inside the
    /// glyph rect, not past its trailing edge — past-the-edge hits should
    /// place the caret like normal). F-09: also assert the click x sits at
    /// or past the glyph's left edge — `glyphIndex(for:)` snaps clicks in
    /// the leading-indent zone (before the line's first glyph) to glyph 0
    /// with fraction 0, which would otherwise toggle on margin clicks.
    override func mouseDown(with event: NSEvent) {
        if let lm = layoutManager,
           let tc = textContainer,
           let storage = textStorage {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let textPoint = NSPoint(
                x: viewPoint.x - textContainerOrigin.x,
                y: viewPoint.y - textContainerOrigin.y
            )
            var fraction: CGFloat = 0
            let glyphIdx = lm.glyphIndex(
                for: textPoint,
                in: tc,
                fractionOfDistanceThroughGlyph: &fraction
            )
            if fraction < 1.0 {
                let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
                if charIdx >= 0,
                   charIdx < storage.length,
                   storage.attribute(.sidekickChecklistMarker,
                                     at: charIdx,
                                     effectiveRange: nil) != nil {
                    let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                    let glyphLocation = lm.location(forGlyphAt: glyphIdx)
                    let markerFont = (storage.attribute(.font, at: charIdx, effectiveRange: nil) as? NSFont)
                        ?? NSFont.systemFont(ofSize: 15)
                    // Shared geometry with MarkdownLayoutManager.drawBackground so
                    // the tap zone always tracks the painted square.
                    let squareRect = MarkdownLayoutManager.checklistSquareRect(
                        lineFragmentRect: lineRect,
                        glyphLocation: glyphLocation,
                        markerFont: markerFont
                    )
                    // UI-SPEC: minimum 20×20pt tap zone centered on the drawn square.
                    let squareSide: CGFloat = 11
                    let tapZone = squareRect.insetBy(dx: -(20 - squareSide) / 2, dy: -(20 - squareSide) / 2)
                    if tapZone.contains(textPoint) {
                        if FormattingToolbarView.toggleChecklistState(at: charIdx, in: self) {
                            return
                        }
                    }
                }
            }
        }
        super.mouseDown(with: event)
        // Divider click-leak rescue: the setSelectedRanges HR snap has a
        // same-line exemption that the mouse path slips through — the click's
        // intermediate `stillSelecting` pass parks the caret on the HR line, so
        // the final pass sees "same line" and declines to snap, stranding the
        // caret on the uninhabitable rule. Resolve it here at the click site.
        relocateCaretOffHRAfterClick(event)
    }

    /// After a plain click resolves onto an uninhabitable HR line, move the
    /// caret to the nearest inhabitable neighbor — top half of the divider →
    /// end of the line above, bottom half → start of the line below. No-op when
    /// the click did not land on an HR line, produced a range selection, or the
    /// HR is the whole document. The neighbor decision is delegated to the
    /// unit-tested `hrCaretRelocationTarget`; only the top/bottom-half geometry
    /// lives here.
    private func relocateCaretOffHRAfterClick(_ event: NSEvent) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        // Which half of the clicked line fragment did the click land in? The
        // click resolved onto the HR line, so its glyph fragment IS that line.
        let glyphIdx = lm.glyphIndex(for: textPoint, in: tc)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let clickInBottomHalf = textPoint.y >= lineRect.midY

        if let dest = hrCaretRelocationTarget(caret: sel.location, clickInBottomHalf: clickInBottomHalf) {
            setSelectedRange(NSRange(location: dest, length: 0))
        }
    }

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
        // is cleared (Design Note above).
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
        // Double-check: the line must NOT already end with `\n` (which would
        // mean there IS a line below and `lineEnd == storage.length` was a
        // coincidence of the trailing-newline inclusive lineRange).
        let lastChar = ns.character(at: lineEnd - 1)
        guard lastChar != 0x0A && lastChar != 0x0D else { return }

        // Append a single `\n` at the end of the document via the undo-safe
        // shouldChangeText/replaceCharacters/didChangeText sandwich.
        let editRange = NSRange(location: storage.length, length: 0)
        guard shouldChangeText(in: editRange, replacementString: "\n") else { return }
        replaceCharacters(in: editRange, with: "\n")
        didChangeText()
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

        // Strip any trailing newline to get the visible content of the line.
        var contentLength = lineRange.length
        if contentLength > 0 {
            let lastChar = ns.character(at: lineRange.location + contentLength - 1)
            if lastChar == 0x0A || lastChar == 0x0D { contentLength -= 1 }
        }
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

    override func setConstrainedFrameSize(_ desiredSize: NSSize) {
        var size = desiredSize
        if let clipHeight = enclosingScrollView?.contentView.bounds.height {
            size.height = max(size.height, clipHeight)
        }
        super.setConstrainedFrameSize(size)
    }

    /// Compute the position to snap a caret to when `target` lands on a
    /// thematic-break line. Returns `nil` if no snap is needed (target is
    /// not on an HR line, or the line is the entire document so there is
    /// nowhere to go).
    ///
    /// HR lines are uninhabitable by design: the dash glyphs are zero-width
    /// (`.sidekickHiddenMarker` ORs `.null` into the glyph property), so
    /// every caret position INSIDE the line collapses to a single visual
    /// point. Letting the caret rest there produces a misleading position
    /// — natural NSTextView puts it at x=0 (left edge), older overrides
    /// shifted it to the right edge of the hairline; both lie about where
    /// the next typed character will visually land. Pushing the caret to
    /// the line above or below keeps user mental model coherent (matches
    /// Bear / iA Writer).
    ///
    /// Direction inferred from `previous`:
    ///   * `target > previous` → caret moving forward, snap DOWN to the
    ///     start of the line below HR.
    ///   * `target ≤ previous` → moving backward, snap UP to the end of
    ///     the line above HR.
    /// If only one neighbor exists, that wins regardless of direction.
    /// If neither exists (HR is the whole document), return `nil` and
    /// leave the caret alone — degenerate case, no good answer.
    private func snapCaretOutOfHR(target: Int, previous: Int) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, target >= 0, target <= n else { return nil }

        // lineRange wants an index INSIDE the string. Clamp at n-1 for
        // the end-of-doc case where target == n (one past last char).
        let probeLoc = min(target, n - 1)
        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: probeLoc, length: 0))
        guard lineRange.length > 0 else { return nil }

        var foundHR = false
        storage.enumerateAttribute(
            .sidekickThematicBreak,
            in: lineRange,
            options: []
        ) { value, _, stop in
            if (value as? Bool) == true {
                foundHR = true
                stop.pointee = true
            }
        }
        guard foundHR else { return nil }

        // Same-line exemption: if `previous` was on the SAME line as
        // `target`, the user is moving within the line (typing, or
        // intra-line navigation that landed on a freshly-converted HR).
        // Don't snap — they haven't crossed a line boundary, and yanking
        // them off the line they just typed on would be jarring. Snap
        // only takes effect when caret crosses a line boundary INTO HR
        // (arrow keys, clicks from another line, etc.).
        let prevProbe = min(max(previous, 0), n - 1)
        if prevProbe >= 0 {
            let prevLineRange = ns.lineRange(for: NSRange(location: prevProbe, length: 0))
            if NSEqualRanges(prevLineRange, lineRange) {
                return nil
            }
        }

        return hrNeighborLocation(hrLineRange: lineRange, preferBelow: target > previous)
    }

    /// Nearest inhabitable neighbor location for a caret leaving an HR line.
    /// `preferBelow` breaks the tie when both neighbors exist — the keyboard
    /// rescue passes direction-of-motion (`target > previous`), the mouse
    /// rescue passes which half of the divider was clicked. Returns the start
    /// of the line below (`belowLoc`) or the end of the line above (`aboveLoc`);
    /// `nil` only when the HR line is the entire document (nowhere to go).
    private func hrNeighborLocation(hrLineRange lineRange: NSRange, preferBelow: Bool) -> Int? {
        guard let storage = textStorage, lineRange.length > 0 else { return nil }
        let ns = storage.string as NSString
        let hasAbove = lineRange.location > 0
        let lineEndsWithNewline =
            ns.character(at: lineRange.location + lineRange.length - 1) == 0x0A
        let hasBelow = lineEndsWithNewline

        let aboveLoc = lineRange.location - 1
        let belowLoc = lineRange.location + lineRange.length

        if !hasAbove && !hasBelow { return nil }
        if !hasAbove { return belowLoc }
        if !hasBelow { return aboveLoc }
        return preferBelow ? belowLoc : aboveLoc
    }

    /// Click-path counterpart to `snapCaretOutOfHR`: given a caret that a mouse
    /// click resolved onto an HR line, return where it should go instead. The
    /// neighbor is chosen by which half of the divider was clicked — top half
    /// (`clickInBottomHalf == false`) → end of the line above; bottom half →
    /// start of the line below. Returns `nil` when the caret is not on an HR
    /// line or the HR is the whole document.
    ///
    /// Split out (and left `internal`) from `mouseDown` so the neighbor
    /// decision is unit-testable without synthesizing an AppKit mouse-tracking
    /// loop — only the geometry that computes `clickInBottomHalf` needs live
    /// verification.
    func hrCaretRelocationTarget(caret: Int, clickInBottomHalf: Bool) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, caret >= 0, caret <= n else { return nil }

        let probeLoc = min(caret, n - 1)
        let ns = storage.string as NSString
        let hrLineRange = ns.lineRange(for: NSRange(location: probeLoc, length: 0))
        guard hrLineRange.location < n,
              storage.attribute(.sidekickThematicBreak,
                                at: hrLineRange.location,
                                effectiveRange: nil) != nil else { return nil }

        return hrNeighborLocation(hrLineRange: hrLineRange, preferBelow: clickInBottomHalf)
    }

    /// Compute the position to snap a caret to when `target` lands in the
    /// "gap" of a GFM task-list prefix (`- [ ] ` / `- [x] `). The 6-char
    /// prefix is an atomic block: the caret may rest at line start (offset 0,
    /// before the checkbox) or at content start (offset 6), never on the
    /// interior offsets 1…5. Letting it rest in the gap lets the user type
    /// into — and thereby break — the checkbox syntax, and strands Enter (the
    /// continuation handler only fires from content start). Returns `nil` when
    /// no snap is needed.
    ///
    /// Gated on the rendered `.sidekickChecklistMarker` attribute so the snap
    /// fires only where a checkbox is actually drawn — a plain line that merely
    /// begins with the `- [ ] ` characters but did not parse as a task list
    /// carries no marker and is left freely editable.
    ///
    /// Direction inferred from `previous` (mirrors `snapCaretOutOfHR`):
    ///   * `target > previous` → moving forward, snap to content start (line+6)
    ///   * `target ≤ previous` → moving backward, snap to line start (line+0)
    private func snapCaretOutOfChecklistGap(target: Int, previous: Int) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, target >= 0, target <= n else { return nil }

        let probeLoc = min(target, n - 1)
        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: probeLoc, length: 0))
        guard lineRange.length >= 6,
              storage.attribute(.sidekickChecklistMarker,
                                at: lineRange.location,
                                effectiveRange: nil) != nil else { return nil }

        // Gap = strictly between line start and content start (offsets 1…5).
        let contentStart = lineRange.location + 6
        guard target > lineRange.location, target < contentStart else { return nil }

        return target > previous ? contentStart : lineRange.location
    }

    /// Compute the position to snap a caret to when `target` lands strictly
    /// INSIDE a collapsed link-chip run — a bare URL, or a `[url](url)` chip
    /// whose characters all carry `.sidekickHiddenMarker` and render as a
    /// single pill. The chip is atomic: the caret may rest just before the run
    /// (its leading edge) or just after it, never on the hidden interior where
    /// the pill collapses every offset to one visual point. Returns `nil` when
    /// no snap applies.
    ///
    /// Detection is attribute-based (no re-parse): the caret must sit inside a
    /// `.sidekickHiddenMarker` run whose extent also carries a
    /// `.sidekickLinkChip` anchor — a combination unique to rendered link
    /// chips, so heading / list / emphasis hidden markers are left untouched.
    ///
    /// Direction mirrors `snapCaretOutOfHR`: forward → run end, backward → run
    /// start.
    private func snapCaretOutOfLinkChip(target: Int, previous: Int) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, target > 0, target < n else { return nil }

        // Must be strictly inside a hidden run. Use `longestEffectiveRange` so
        // the run spans the WHOLE URL by the hidden attribute's value alone —
        // the chip anchor char carries extra attributes (.link, .toolTip, …)
        // and would otherwise cut the plain `effectiveRange` short, hiding the
        // anchor from the chip check below.
        var runRange = NSRange(location: NSNotFound, length: 0)
        guard storage.attribute(.sidekickHiddenMarker,
                                at: target,
                                longestEffectiveRange: &runRange,
                                in: NSRange(location: 0, length: n)) != nil else { return nil }

        // `.sidekickHiddenMarker` is stored with the SAME value (`true`) for
        // every hidden construct, so `longestEffectiveRange` cannot tell a link
        // chip apart from an immediately-preceding hidden prefix on the same
        // line: a blockquote `> ` or heading `# ` whose content is itself a bare
        // URL coalesces into one run spanning [prefix start … URL end]. Anchor
        // the chip's leading edge on the `.sidekickLinkChip` char (the URL's
        // first character) instead of the merged run's start, so the prefix is
        // never mistaken for chip interior (which would trap the caret in the
        // prefix and teleport it past the whole URL).
        var chipStart = NSNotFound
        storage.enumerateAttribute(.sidekickLinkChip, in: runRange, options: []) { value, range, stop in
            if value != nil { chipStart = range.location; stop.pointee = true }
        }
        guard chipStart != NSNotFound else { return nil }

        // Snap only when strictly inside the chip. Both the leading edge
        // (`chipStart`, just before the pill) and the trailing edge (`runEnd`,
        // just after) are valid resting spots. A caret at or before `chipStart`
        // sits in the hidden prefix — not our concern here, leave it alone.
        guard target > chipStart else { return nil }

        let runEnd = runRange.location + runRange.length
        return target > previous ? runEnd : chipStart
    }

    /// Selection-change funnel — every keyboard, mouse, and programmatic
    /// selection change reaches this override.
    ///
    /// Two responsibilities:
    ///   1. quick-260523-29t armed-inline cancel: any non-still-selecting
    ///      change clears the armed set, UNLESS the one-shot
    ///      `suppressArmedClearOnNextSelectionChange` flag is set (which
    ///      `insertText` raises around its own programmatic caret-placement
    ///      call). `stillSelecting == true` is a drag-in-progress — don't
    ///      clear arming mid-drag; AppKit fires a final `stillSelecting ==
    ///      false` when the drag ends and THAT clears.
    ///   2. HR-line caret-skip: when the proposed selection is a single
    ///      zero-length caret landing on a thematic-break line, redirect
    ///      it to the nearest non-HR neighbor before passing to super.
    ///      Range selections (length > 0) are left alone so a user can
    ///      shift-select across an HR.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        if !stillSelecting {
            if suppressArmedClearOnNextSelectionChange {
                suppressArmedClearOnNextSelectionChange = false
            } else if !armedInlineKinds.isEmpty {
                armedInlineKinds.removeAll()
                armedInlineKindsOrder.removeAll()
                republishArmedKinds()
            }
        }

        var effectiveRanges = ranges
        if !stillSelecting,
           ranges.count == 1,
           let proposed = ranges.first?.rangeValue,
           proposed.length == 0 {
            let previous = selectedRange().location
            // Three hidden-region caret rescues, mutually exclusive by
            // construction (a zero-length caret can sit on at most one of: an
            // HR line, a checklist prefix gap, a collapsed link-chip interior).
            // First non-nil wins.
            if let snapped = snapCaretOutOfHR(target: proposed.location, previous: previous)
                ?? snapCaretOutOfChecklistGap(target: proposed.location, previous: previous)
                ?? snapCaretOutOfLinkChip(target: proposed.location, previous: previous) {
                effectiveRanges = [NSValue(range: NSRange(location: snapped, length: 0))]
            }
        }

        super.setSelectedRanges(effectiveRanges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clipView = enclosingScrollView?.contentView else { return }
        // Remove first to avoid stacking observers if the view re-mounts
        // (e.g. SwiftUI tearing down and recreating the NSViewRepresentable).
        NotificationCenter.default.removeObserver(
            self, name: NSView.frameDidChangeNotification, object: clipView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification, object: clipView
        )
        clipView.postsFrameChangedNotifications = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipFrameChanged() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? used.height
        let insetY = textContainerInset.height * 2
        let target = max(used.height + insetY, clipHeight)
        if abs(frame.height - target) > 0.5 {
            var f = frame
            f.size.height = target
            frame = f
        }
    }
}

struct HybridEditorView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: HybridEditorController   // NEW (D-TB-02)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 1. Storage + layout manager + container + text view — four-piece
        //    TextKit 1 assembly. ORDER MATTERS: storage first, layout manager
        //    added to storage, container added to layout manager, text view
        //    created with that container.
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        // Scroll view wrapper created first so we can size the text view to match.
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        // NSTextView hosted in NSScrollView needs Apple's full sizing contract:
        // initial non-zero frame + min/max size + isVerticallyResizable. Without
        // these, the text view stays 0×0, clicks never land on it, and typing
        // never reaches the storage. (This is distinct from the .zero frame
        // that works for standalone NSTextView instances.)
        let textView = HybridTextView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 0),
            textContainer: container
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        // F-07: NSTextView's automatic text mutations (smart quotes, dash
        // substitution, autocorrect, link detection, inline completion) inject
        // synthetic key events that delete recently-typed characters. After
        // a paste:-driven emoji insertion (which is how the macOS Character
        // Viewer commits picks), autocorrect fires a synthetic deleteBackward:
        // ~1.4s later, removing whatever ASCII char the user just typed
        // adjacent to the emoji. A markdown notes editor wants none of these
        // mutations — they conflict with markdown syntax (smart quotes break
        // raw ", dash subs break --, text replacements rewrite snippets).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 14)       // P7-PAD-01 (CONTEXT Claude's Discretion — recommended)
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        // Absolute line-height clamp instead of lineHeightMultiple. AppKit
        // derives the insertion-point height from the layout fragment height,
        // and on macOS 14+ uses NSTextInsertionIndicator (a sibling subview)
        // so the legacy drawInsertionPoint(in:color:turnedOn:) override is
        // bypassed. Setting min == max forces a fixed pixel line box regardless
        // of font metrics so the caret stays in proportion to the rendered
        // glyph height. paragraphSpacing adds breathing room between bullets
        // and paragraphs without growing the line box (and thus the caret).
        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.minimumLineHeight = 20
        defaultStyle.maximumLineHeight = 20
        defaultStyle.paragraphSpacing = 1
        textView.defaultParagraphStyle = defaultStyle
        // Explicit dynamic text color — NSColor.textColor adapts to light/dark
        // appearance, matching the old TextEditor + SwiftUI .primary behavior.
        textView.textColor = NSColor.textColor
        textView.insertionPointColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        // Drop NSUnderlineStyle.single from the default linkTextAttributes
        // (kept linkColor + pointingHand) so link-chip pills don't get an
        // auto-underline rendered at the control-glyph baseline. The
        // [label](url) styled-label path applies its own explicit storage
        // underline in MarkdownTextStorage.applyLinks, so dropping the
        // temp-attribute default doesn't affect it.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        controller.textView = textView   // NEW (D-TB-02) — publish upward once
        // quick-260523-29t: weak back-pointer so HybridTextView can republish
        // armedInlineKinds upward without a retain cycle.
        textView.hybridController = controller

        // Seed initial text. replaceCharacters triggers processEditing which
        // applies the initial attribute pass.
        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }

        // Seed caret typing attributes for the initial selection — programmatic
        // seeding does not fire textViewDidChangeSelection, so call directly.
        context.coordinator.updateCaretTypingAttributes(in: textView)
        // Same reason: seed the toolbar's active-format highlight for the
        // initial caret position so a freshly-mounted note with the caret
        // already inside formatted text shows the correct active button.
        context.coordinator.updateActiveInlineKind(in: textView)
        context.coordinator.updateActiveHeadingLevel(in: textView)
        context.coordinator.updateActiveLinePrefix(in: textView)

        scrollView.documentView = textView
        return scrollView
    }

    /// Outcome of the EDIT-02 `updateNSView` binding-push decision.
    ///
    /// Extracted as a named type so the guard's branching logic is unit-testable
    /// without mounting the full `NSViewRepresentable` (IN-02). `updateNSView`
    /// itself just switches on the result.
    enum BindingPushDecision: Equatable {
        /// Binding value already equals the text view string — nothing to do.
        case noChange
        /// Incoming `text` differs from the text view, but no genuine external
        /// push has occurred (tokens equal) — this is a reflexive echo of user
        /// typing. Skip the undo-corrupting bare-storage replace.
        case reflexiveEcho
        /// A genuine external push (note switch / reload-from-disk) raised the
        /// token. Apply the bare-storage replace and record the token.
        case applyExternalPush
    }

    /// Pure decision function for the EDIT-02 binding-push guard.
    ///
    /// Classification is by EXPLICIT PUSH TOKEN, never by string value:
    ///   - currentString == incomingText               -> noChange
    ///   - currentToken != lastConsumedToken           -> applyExternalPush
    ///   - otherwise (token unchanged, strings differ) -> reflexiveEcho
    ///
    /// Why token, not string (history): the WR-01 fix tried to distinguish
    /// echo vs push by comparing `incomingText` against a remembered string. A
    /// single-shot variant of that (commit 79f0f3b) cleared the remembered
    /// string on the first echo, so every later reflexive echo of normal
    /// typing was misclassified as an external push -> bare-storage replace ->
    /// corrupted undo stack -> Cmd+Z wiped the whole note. An explicit push
    /// token cannot be fooled by value collisions in EITHER direction.
    static func bindingPushDecision(
        currentString: String,
        incomingText: String,
        currentToken: Int,
        lastConsumedToken: Int
    ) -> BindingPushDecision {
        guard currentString != incomingText else { return .noChange }
        if currentToken != lastConsumedToken {
            return .applyExternalPush
        }
        return .reflexiveEcho
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage as? MarkdownTextStorage else { return }

        // External binding-push guard (EDIT-02).
        //
        // Classification is token-based: EditorPaneView bumps
        // `controller.externalPushToken` at each genuine external-push site
        // (note switch, reload-from-disk). updateNSView compares that token
        // against the value this Coordinator last consumed — an advance means
        // a real external push; an unchanged token means any binding change
        // reaching here is a reflexive echo of user typing.
        //
        // Why token, not string value: a bare `storage.replaceCharacters`
        // bypasses the shouldChangeText/didChangeText sandwich and corrupts
        // NSTextView's undo coalescing, so it must fire ONLY for genuine
        // external pushes. The WR-01 single-shot string sentinel could be
        // fooled by value collisions in both directions (see
        // `bindingPushDecision`); an explicit push token cannot.
        //
        // The branching itself lives in `bindingPushDecision` (a pure
        // function) so it can be unit-tested without mounting the
        // NSViewRepresentable.
        switch Self.bindingPushDecision(
            currentString: textView.string,
            incomingText: text,
            currentToken: controller.externalPushToken,
            lastConsumedToken: context.coordinator.lastConsumedPushToken
        ) {
        case .noChange:
            break
        case .reflexiveEcho:
            // Reflexive echo of user typing — the SwiftUI binding caught up
            // to what the Coordinator pushed in textDidChange. A bare-storage
            // replace here bypasses the shouldChangeText/didChangeText
            // sandwich and corrupts the NSTextView undo stack (EDIT-02).
            // No token advanced -> skip. No state to clear.
            break
        case .applyExternalPush:
            // Genuine external push — note switch or reload-from-disk bumped
            // the token. Apply the bare-storage replace (intentionally NOT
            // registered on the undo stack — this content did not come from a
            // user keystroke), then record the token so a follow-up reflexive
            // echo of this same value is not re-applied.
            storage.beginEditing()
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.replaceCharacters(in: fullRange, with: text)
            storage.endEditing()
            // processEditing fires inside endEditing → attributes reapplied.
            context.coordinator.lastConsumedPushToken = controller.externalPushToken
        }
    }

    // MARK: - Coordinator (NSTextViewDelegate bridge)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HybridEditorView
        weak var textView: NSTextView?
        /// The value of `controller.externalPushToken` this Coordinator has
        /// already applied. updateNSView treats `controller.externalPushToken
        /// != lastConsumedPushToken` as a genuine external push. Initialized
        /// to match the controller's starting token in `init` so the first
        /// updateNSView after mount is not misread as a push.
        var lastConsumedPushToken: Int

        init(_ parent: HybridEditorView) {
            self.parent = parent
            // Seed the last-consumed token to the controller's current value
            // so the first updateNSView after mount is treated as an echo /
            // no-op, not a push (makeNSView already seeds the initial text).
            // `controller` is @MainActor-isolated and makeCoordinator() — the
            // sole caller — runs on the main actor, so the read is safe.
            self.lastConsumedPushToken = MainActor.assumeIsolated {
                parent.controller.externalPushToken
            }
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Infinite-loop guard — only push up if the binding value is stale.
            // No per-keystroke string snapshot is needed: the EDIT-02 echo
            // guard is now purely token-based (see `bindingPushDecision`).
            if parent.text != tv.string {
                parent.text = tv.string
            }
            // Text edits can change which inline pair encloses the caret
            // without the selection itself moving (e.g. typing the closing
            // `*` of an italic pair around the caret). Refresh here too.
            updateActiveInlineKind(in: tv)
            // Same reason for headings: typing/deleting a leading `#` flips
            // the line in/out of heading state without selection movement.
            updateActiveHeadingLevel(in: tv)
            // Same reason for line prefixes: typing/deleting a `- ` prefix
            // flips the line in/out of bullet/numbered/checklist/blockquote
            // state without the selection moving.
            updateActiveLinePrefix(in: tv)
        }

        /// Caret typing attributes are sticky after edits — when the user
        /// presses Enter from line 1 (H1) into line 2, AppKit carries the
        /// H1 typing attrs forward, so the caret on line 2 stays tall even
        /// though the line 2 text will render at body 14pt. Refresh on every
        /// selection change so the caret height matches what the next typed
        /// character will be: H1 on the first line, body 14pt elsewhere.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            updateCaretTypingAttributes(in: tv)
            updateActiveInlineKind(in: tv)
            updateActiveHeadingLevel(in: tv)
            updateActiveLinePrefix(in: tv)
        }

        /// Recompute which inline pair (bold / italic / code) currently
        /// encloses the selection and publish it to the controller so the
        /// toolbar can highlight the matching button. Only writes when the
        /// value actually changes — `@Published` fires objectWillChange even
        /// on identical writes, which would re-render EditorPaneView on
        /// every keystroke unnecessarily.
        ///
        /// `MainActor.assumeIsolated` because NSTextViewDelegate methods are
        /// documented main-thread-only but their Swift signatures are not
        /// `@MainActor` annotated, while `HybridEditorController` is —
        /// without the assertion the controller property writes flag a
        /// concurrency diagnostic.
        func updateActiveInlineKind(in tv: NSTextView) {
            let kind = FormattingToolbarView.activeInlineKind(
                body: tv.string,
                selection: tv.selectedRange()
            )
            MainActor.assumeIsolated {
                if parent.controller.activeInlineKind != kind {
                    parent.controller.activeInlineKind = kind
                }
            }
        }

        /// Recompute the heading level of the line containing the caret
        /// and publish it to the controller. Single-line scan over the
        /// `^#{1,6} ` prefix — cheaper than re-running the full parser
        /// for what is purely a UI hint. Coalesces identical writes for
        /// the same reason as `updateActiveInlineKind`.
        /// Recompute the line-prefix block format (bullet / numbered /
        /// checklist / blockquote) of the line containing the caret and
        /// publish to the controller. Coalesces identical writes for the
        /// same reason as `updateActiveInlineKind`.
        func updateActiveLinePrefix(in tv: NSTextView) {
            let prefix = FormattingToolbarView.activeLinePrefix(
                body: tv.string,
                selection: tv.selectedRange()
            )
            MainActor.assumeIsolated {
                if parent.controller.activeLinePrefix != prefix {
                    parent.controller.activeLinePrefix = prefix
                }
            }
        }

        func updateActiveHeadingLevel(in tv: NSTextView) {
            let nsBody = tv.string as NSString
            let selection = tv.selectedRange()
            let probe = NSRange(location: min(selection.location, nsBody.length), length: 0)
            let lineRange = nsBody.lineRange(for: probe)
            let lineNS = nsBody.substring(with: lineRange) as NSString

            var hashes = 0
            while hashes < lineNS.length, lineNS.character(at: hashes) == 0x23 {
                hashes += 1
            }
            let level: Int?
            if hashes >= 1, hashes <= 6,
               hashes < lineNS.length, lineNS.character(at: hashes) == 0x20 {
                // Cap display at 3 — toolbar dropdown only offers H1–H3.
                level = min(hashes, 3)
            } else {
                level = nil
            }
            MainActor.assumeIsolated {
                if parent.controller.activeHeadingLevel != level {
                    parent.controller.activeHeadingLevel = level
                }
            }
        }

        func updateCaretTypingAttributes(in tv: NSTextView) {
            // Body editor is uniformly body-styled now that title lives in
            // its own field. Pin font + paragraph style so the caret on an
            // empty doc reserves the body line box (18pt) instead of falling
            // back to defaultParagraphStyle metrics.
            var attrs = tv.typingAttributes
            attrs[.font] = NSFont.systemFont(ofSize: 15, weight: .regular)
            attrs[.paragraphStyle] = MarkdownTextStorage.bodyParagraphStyle
            tv.typingAttributes = attrs
        }

        /// Enter continuation for list-style lines. Order matters: checklist
        /// is a superset of the bullet prefix (`- [ ] foo` starts with `- `),
        /// so the checklist handler runs first and only returns true when the
        /// line really is a task-list line. Bullet and numbered handlers
        /// follow. Each returns true when it handled the Enter — caller stops
        /// the default `insertNewline:` from firing in that case. Other
        /// `doCommandBy` selectors (insert tab, delete forward, etc.) fall
        /// through to NSTextView's default behavior.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if FormattingToolbarView.handleThematicBreakReturn(in: textView) { return true }
                if FormattingToolbarView.handleChecklistReturn(in: textView) { return true }
                if FormattingToolbarView.handleBulletReturn(in: textView) { return true }
                if FormattingToolbarView.handleNumberedReturn(in: textView) { return true }
                return false
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if FormattingToolbarView.handleThematicBreakBackspace(in: textView) { return true }   // HR-03: one-shot HR delete from adjacent empty line
                if FormattingToolbarView.handleAtomicMarkerBackspace(in: textView) { return true }    // quick-260524-0ia: atomic inline-format marker pair delete
                if FormattingToolbarView.handleChecklistBackspace(in: textView) { return true }
            }
            if commandSelector == #selector(NSResponder.deleteForward(_:)) {
                if FormattingToolbarView.handleThematicBreakForwardDelete(in: textView) { return true } // HR-03: one-shot HR delete from adjacent empty line
                if FormattingToolbarView.handleAtomicMarkerForwardDelete(in: textView) { return true } // quick-260524-0ia: atomic inline-format marker pair delete
                if FormattingToolbarView.handleChecklistForwardDelete(in: textView) { return true }
            }
            // Shift-Tab at body offset 0 → return focus to the title field
            // (counterpart to title→body Tab in EditorPaneView). Anywhere else
            // in the body, fall through to NSTextView's default backtab.
            if commandSelector == #selector(NSResponder.insertBacktab(_:)),
               textView.selectedRange().location == 0,
               textView.selectedRange().length == 0 {
                if let callback = parent.controller.onShiftTabAtBodyStart {
                    callback()
                    return true
                }
            }
            return false
        }

        /// PRIMARY PATH — NSTextViewDelegate method invoked when the user clicks on a
        /// character that carries the `.link` attribute. Returning true = we handled
        /// it; returning false = fall through to NSTextView's default behavior
        /// (cursor placement on plain click, per Apple AppKit docs when the delegate
        /// method IS implemented). Per 10-CONTEXT.md D-LC-01.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // D-LC-01: ⌘-click opens; plain click falls through to default cursor positioning
            guard NSEvent.modifierFlags.contains(.command) else {
                return false   // Let NSTextView do default cursor positioning on plain click
            }
            // AppKit's clickedOnLink delivers `link` as Any — usually URL, sometimes String
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            if let url {
                // D-LC-02: dispatch link URL via NSWorkspace (hybrid editor owns this path; prior preview consumer was removed in Phase 11).
                // All schemes pass through (http/https/mailto/file/custom);
                // no whitelist, no confirm sheet.
                NSWorkspace.shared.open(url)
            }
            return true   // ⌘-click handled (or no-op'd on nil URL)
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    @Previewable @State var text = ""
    let controller = HybridEditorController()
    return HybridEditorView(text: $text, controller: controller)
        .frame(width: 400, height: 500)
}

#Preview("Mixed formatting") {
    @Previewable @State var text = """
# Heading Example
This is **bold text** and *italic text* with `inline code`.
- Bullet point one
- Bullet point two
A [link example](https://example.com) ends this preview.
"""
    let controller = HybridEditorController()
    return HybridEditorView(text: $text, controller: controller)
        .frame(width: 400, height: 500)
}
