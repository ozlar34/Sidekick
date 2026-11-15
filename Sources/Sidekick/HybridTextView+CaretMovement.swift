/// `HybridTextView` plain caret movement: the snap-rescue chain
/// (`correctedCaretTarget`) plus the AppKit overrides that consume it for a
/// zero-length caret — `setSelectedRanges` and the four unmodified arrow
/// keys. The per-region geometry these call into lives in
/// HybridTextView+CaretSnapping.swift; the shift-arrow variants live in
/// HybridTextView+SelectionExtension.swift.

import AppKit
import SwiftUI

extension HybridTextView {


    /// Shared cheap-gate + five-helper snap-rescue chain for a proposed
    /// zero-length caret `target`, given the location it's moving `direction`
    /// from `previous`. Returns `nil` when `target` isn't near a managed
    /// region (HR line, checklist marker, hidden-marker run) — the cheap
    /// gate below gets checked FIRST so the common case (plain text, far
    /// from any managed region) never pays for the five-helper chain — or
    /// when it is near one but none of the five rescues wants to correct it.
    ///
    /// Factored out of `setSelectedRanges` (quick-260523 caret-skip logic)
    /// so `moveLeft`/`moveRight` below can reuse the exact same rescue chain
    /// against a caller-computed naive target, instead of trusting AppKit's
    /// own layout-based stepping near these regions (see the overrides'
    /// doc comments for why that stepping is unreliable there). [11] Cheap
    /// gate before the five rescues: each recomputes lineRange and the HR
    /// rescue enumerates the whole line, so running all five on every caret
    /// move is wasteful. A zero-length caret only needs a rescue when it's
    /// near a managed region — an HR or checklist line (both markers
    /// anchored at line start) or a collapsed hidden-marker run at the
    /// caret. Otherwise skip the chain entirely.
    ///
    /// Two SOURCE-side extensions to the cheap gate (ticket 08), on top of
    /// the original naive-DESTINATION-only checks above: the naive-only gate
    /// missed cases where `naive` itself is already the correct resting spot
    /// (a hidden-marker run's own boundary, or a line-terminator position
    /// immediately before a managed line) but the SOURCE (`previous`) sits on
    /// or adjacent to a managed construct — so falling through to
    /// `super`'s own glyph-based stepping from that source is unreliable
    /// (empirically: it can bounce backward, or jump an extra managed line
    /// in one step):
    ///   - `previous` itself sits inside/on a `.sidekickHiddenMarker` run
    ///     (closes the right-bounce mechanism: caret ON a hidden marker,
    ///     one naive step lands cleanly past it, but the gate only ever
    ///     looked at the destination).
    ///   - `naive` lands exactly inside the terminator run of ITS OWN
    ///     current line, and the FOLLOWING line is a thematic-break/
    ///     checklist line (closes the shift-extend-overshoot mechanism:
    ///     NSString's line-terminator convention attaches the terminator to
    ///     the line it ends, so the last naive step before crossing into a
    ///     managed line never itself lands on that managed line's own
    ///     lineStart — it needs exactly one line of lookahead).
    /// In both cases `naive` needs no correction — the five rescues below
    /// correctly decline (none of them owns a strictly-interior target) —
    /// so when the chain returns `nil` but one of these two SOURCE-side
    /// conditions (and NOT a destination-managed hit — see the
    /// `!destinationManaged` guard below, which structurally enforces that
    /// these two paths never overlap) is what made the region "managed,"
    /// `naive` is trusted directly instead of falling through to `super`.
    ///
    /// Both extensions are gated behind `naiveIsVerifiedStep`, a flag the
    /// CALLER supplies (never inferred here) rather than left implicit,
    /// matching this codebase's "caller supplies explicit direction/context"
    /// convention (see ticket 02's refactor of the snap-rescue helpers'
    /// `direction` parameter). They are sound ONLY when `naive` is a real,
    /// verified one-raw-character step — true for the four horizontal
    /// callers (`moveLeft`/`moveRight`/their `…AndModifySelection`
    /// variants), where a single character index really is one step away.
    /// They are UNSOUND for the two vertical callers (`moveUp`/`moveDown`/
    /// their `…AndModifySelection` variants): their own doc comments already
    /// describe the naive same-column step as merely a GUESS, "precise
    /// enough only to detect a managed region," meant to be discarded in
    /// favor of `super`'s real glyph-based vertical stepping whenever the
    /// destination isn't managed. Trusting that guess directly (as the
    /// fallback below does for a verified step) would land the caret at a
    /// visually wrong column whenever the adjacent line's real glyph-x-
    /// position column differs from the raw-character-count column — true
    /// of almost any two differently-styled or differently-worded lines in
    /// this editor's proportional font. So `naiveIsVerifiedStep: false`
    /// (passed by `moveUp`/`moveDown`/their modify-selection variants) skips
    /// computing both extensions entirely — `nearManagedRegion` for those
    /// callers is exactly `destinationManaged`, identical to this function's
    /// pre-ticket-08 behavior.
    // Internal (not private): also called from stepExtension in
    // HybridTextView+SelectionExtension.swift.
    func correctedCaretTarget(
        fromNaive naive: Int,
        previous: Int,
        direction: CaretSnapDirection,
        naiveIsVerifiedStep: Bool
    ) -> Int? {
        guard let storage = textStorage, storage.length > 0,
              naive >= 0, naive <= storage.length else { return nil }
        let n = storage.length
        let ns = storage.string as NSString
        let probe = min(max(naive, 0), n - 1)
        let lineStart = ns.lineRange(for: NSRange(location: probe, length: 0)).location
        let destinationManaged =
            storage.attribute(.sidekickThematicBreak, at: lineStart, effectiveRange: nil) != nil
            || storage.attribute(.sidekickChecklistMarker, at: lineStart, effectiveRange: nil) != nil
            || (naive < n
                && storage.attribute(.sidekickHiddenMarker, at: probe, effectiveRange: nil) != nil)

        var sourceOnHiddenMarker = false
        var naiveAtManagedLineLookahead = false
        if naiveIsVerifiedStep {
            // SOURCE-side extension 1: `previous` sits inside/on a
            // hidden-marker run (e.g. a caret resting ON an italic `*`/bold
            // `**` marker char).
            sourceOnHiddenMarker =
                previous >= 0 && previous < n
                && storage.attribute(.sidekickHiddenMarker, at: previous, effectiveRange: nil) != nil

            // SOURCE-side extension 2: `naive` lands inside the terminator
            // run of its own current line, and the line immediately
            // following that terminator is a managed (thematic-break/
            // checklist) line.
            if naive < n {
                var thisLineEnd = 0, thisContentsEnd = 0
                ns.getLineStart(nil, end: &thisLineEnd, contentsEnd: &thisContentsEnd,
                                 for: NSRange(location: naive, length: 0))
                if naive >= thisContentsEnd, thisLineEnd < n {
                    naiveAtManagedLineLookahead =
                        storage.attribute(.sidekickThematicBreak, at: thisLineEnd, effectiveRange: nil) != nil
                        || storage.attribute(.sidekickChecklistMarker, at: thisLineEnd, effectiveRange: nil) != nil
                }
            }
        }

        let nearManagedRegion = destinationManaged || sourceOnHiddenMarker || naiveAtManagedLineLookahead
        guard nearManagedRegion else { return nil }
        // Five hidden-region caret rescues. The first four are mutually
        // exclusive by construction (a zero-length caret can sit on at
        // most one of: an HR line, a checklist prefix gap, a collapsed
        // link-chip interior, or a styled-link hidden tail); the fifth,
        // generic rescue explicitly excludes any run those four already
        // own (including an intentional decline), so it only ever fires
        // on a leftover `.sidekickHiddenMarker` run — bold, strikethrough,
        // underline, or any other future marker pair. First non-nil wins.
        if let rescued = snapCaretOutOfHR(target: naive, previous: previous, direction: direction)
            ?? snapCaretOutOfChecklistGap(target: naive, direction: direction)
            ?? snapCaretOutOfLinkChip(target: naive, direction: direction)
            ?? snapCaretOutOfLinkTail(target: naive, direction: direction)
            ?? snapCaretOutOfHiddenMarkerRun(target: naive, direction: direction) {
            return rescued
        }
        // None of the five rescues wanted to correct `naive` — expected
        // when `naive` is already a valid resting spot (a run boundary, or
        // a terminator position immediately before a managed line). If a
        // SOURCE-side condition — and ONLY a source-side condition, never
        // together with a destination-managed hit (`!destinationManaged`) —
        // is what flagged this region as managed, trust `naive` directly
        // rather than falling through to `super` (see the two extensions
        // documented above this function). `sourceOnHiddenMarker`/
        // `naiveAtManagedLineLookahead` are already unconditionally `false`
        // when `naiveIsVerifiedStep` is `false`, so this never fires for an
        // unverified (vertical) naive guess.
        guard !destinationManaged, sourceOnHiddenMarker || naiveAtManagedLineLookahead else { return nil }
        return naive
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
           proposed.length == 0,
           let storage = textStorage,
           storage.length > 0 {
            let previous = selectedRange().location
            let direction: CaretSnapDirection = proposed.location > previous ? .forward : .backward
            // `naiveIsVerifiedStep: false` — `proposed.location` here is an
            // arbitrary jump (a click, a programmatic selection), not a
            // one-raw-character step from `previous`; `previous` is merely
            // wherever the caret used to be, unrelated to this move's
            // distance. The two ticket-08 SOURCE-side conditions assume a
            // true one-character relationship between `previous` and
            // `naive`, which doesn't hold here, so they stay disabled
            // (matches this override's pre-ticket-08 behavior exactly).
            if let snapped = correctedCaretTarget(fromNaive: proposed.location, previous: previous, direction: direction, naiveIsVerifiedStep: false) {
                effectiveRanges = [NSValue(range: NSRange(location: snapped, length: 0))]
            }
        }

        super.setSelectedRanges(effectiveRanges, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// Scope note (covers 8 overrides — `moveLeft`/`moveRight`/`moveUp`/
    /// `moveDown` below in this file, and their `…AndModifySelection` variants
    /// in HybridTextView+SelectionExtension.swift):
    ///   - Covers exactly caret/selection movement near an HR/hidden-marker
    ///     boundary for these 8 selectors. Nothing else.
    ///   - Deliberately NOT covered/verified: word-jump (`moveWordLeft:`/
    ///     `moveWordRight:`, Option+Arrow) and line/paragraph/document jump
    ///     (`moveToBeginningOfLine:`/`moveToEndOfLine:`/
    ///     `moveToBeginningOfParagraph:`/`moveToEndOfParagraph:`/
    ///     `moveToBeginningOfDocument:`/`moveToEndOfDocument:`, Cmd+Arrow/
    ///     Home/End) and their modify-selection variants — plausibly share
    ///     the same root cause but were never tested; a future bug report
    ///     there is not necessarily a regression of this fix.
    ///   - `performWrap`/`applyMarkdownWrap` in `FormattingToolbarView.swift`
    ///     was investigated and ruled out as not independently buggy — given
    ///     a correct selection it produces correct output every time; the
    ///     divider-corruption symptom traced to the shift-extend overshoot
    ///     this ticket (08) fixes, not to the wrap logic.
    ///
    /// Override of `NSResponder.moveRight(_:)` — fired by the Right arrow key.
    ///
    /// AppKit's own layout-based caret stepping is unreliable near a managed
    /// region: empirically (see `PlainArrowMoveAcrossDividerTests`), its
    /// native LEFT step from the boundary immediately below a divider can
    /// jump the WRONG way — forward into a hidden inline-marker run's
    /// interior — instead of stepping backward across the divider, because
    /// the zero-width HR line and a zero-width hidden marker run collapse to
    /// the same visual point and confuse its glyph-based search. `moveRight`
    /// is not known to be broken the same way today, but nothing guarantees
    /// that holds for every marker/font combination, so both directions get
    /// the same authoritative treatment rather than one being incidental.
    /// Rather than trust AppKit's stepping near a managed
    /// region, this override computes its OWN naive one-character step from
    /// the current selection and runs it through the same snap-rescue chain
    /// `setSelectedRanges` already uses — reusing, not reimplementing, those
    /// five helpers. Far from any managed region (the common case), the
    /// cheap gate inside `correctedCaretTarget` returns `nil` immediately and
    /// this defers straight to `super.moveRight(sender)`, so ordinary typing
    /// pays nothing extra. A non-empty selection (range, not caret) also
    /// defers to `super` — collapse-to-edge behavior is unaffected here.
    override func moveRight(_ sender: Any?) {
        let current = selectedRange()
        guard current.length == 0, let storage = textStorage else {
            super.moveRight(sender)
            return
        }
        if moveOffHRRun(from: current.location, direction: .forward) { return }
        let naive = min(current.location + 1, storage.length)
        guard naive != current.location else {
            super.moveRight(sender)
            return
        }
        if escapeBelowTrailingHR(from: current.location, toward: naive) { return }
        let corrected = correctedCaretTarget(fromNaive: naive, previous: current.location, direction: .forward, naiveIsVerifiedStep: true)
        // Never stop left of a checkbox: a step that lands on a checklist
        // line's start continues to its content start in the same press.
        if let contentStart = checklistContentStart(ifLineStartAt: corrected ?? naive) {
            setSelectedRange(NSRange(location: contentStart, length: 0))
            return
        }
        guard let corrected else {
            super.moveRight(sender)
            return
        }
        // A rescue that lands on a line start (e.g. across a divider) goes
        // on past a hidden opening marker there, as AppKit's own step does.
        setSelectedRange(NSRange(location: hiddenPrefixEnd(ifLineStartAt: corrected) ?? corrected, length: 0))
    }

    /// Override of `NSResponder.moveLeft(_:)` — fired by the Left arrow key.
    /// Mirrors `moveRight(_:)` above (same rationale: AppKit's own stepping
    /// is unreliable near a managed region, so this computes its own naive
    /// backward step and runs it through the shared rescue chain instead).
    ///
    /// Mirror of `moveRight`'s checklist rule: a step that lands on a
    /// checklist line's start (left of the checkbox) continues across the
    /// line break to the end of the line above, in the same press. When
    /// there is no inhabitable spot above (the checklist is the first line,
    /// or only a leading divider sits above it), the caret stays where it is.
    override func moveLeft(_ sender: Any?) {
        let current = selectedRange()
        guard current.length == 0, let storage = textStorage else {
            super.moveLeft(sender)
            return
        }
        if moveOffHRRun(from: current.location, direction: .backward) { return }
        let naive = max(current.location - 1, 0)
        guard naive != current.location else {
            super.moveLeft(sender)
            return
        }
        var corrected = correctedCaretTarget(fromNaive: naive, previous: current.location, direction: .backward, naiveIsVerifiedStep: true)
        if let rescued = corrected, let past = stepBackPastCollapsedMarkers(landing: rescued, source: current.location) {
            corrected = past
        }
        let landing = corrected ?? naive
        if checklistContentStart(ifLineStartAt: landing) != nil {
            guard landing > 0 else { return }
            var aboveContentsEnd = 0
            (storage.string as NSString).getLineStart(nil, end: nil, contentsEnd: &aboveContentsEnd,
                                                      for: NSRange(location: landing - 1, length: 0))
            let beyond = correctedCaretTarget(fromNaive: aboveContentsEnd, previous: landing, direction: .backward, naiveIsVerifiedStep: true)
                ?? aboveContentsEnd
            guard beyond < current.location, checklistContentStart(ifLineStartAt: beyond) == nil else { return }
            setSelectedRange(NSRange(location: beyond, length: 0))
            return
        }
        guard let corrected else {
            super.moveLeft(sender)
            return
        }
        setSelectedRange(NSRange(location: corrected, length: 0))
    }

    /// A3: a forward move (Right/Down) from text into a divider block that
    /// ends the note with no line below has nowhere to land, so the HR rescue
    /// sends the caret back to where it was and the key seems stuck. In that
    /// case this extends HR-01's guarantee ("the caret never gets stranded
    /// above the rule") to a divider that was already there: it appends one
    /// `\n` (undo-safe) and parks the caret on the new empty line below, so
    /// typing or Return continues under the divider and `---` stays a
    /// divider. Returns `false` (no change) when `destination` is not on such
    /// a block, or `source` is already on it (`moveOffHRRun` handles that).
    private func escapeBelowTrailingHR(from source: Int, toward destination: Int) -> Bool {
        guard isOnUnterminatedTrailingHR(destination), !isOnUnterminatedTrailingHR(source) else { return false }
        appendLineBelowTrailingHR()
        return true
    }

    /// A4: an arrow key from a caret that sits ON a divider leaves the whole
    /// divider run in the key's direction (see `hrRunExit`), instead of
    /// AppKit's stepping, which can move against the key there. Forward with
    /// no line below appends one (A3 rule); backward with no line above
    /// stays. A forward landing on a checklist line start goes on to its
    /// content start, and one on a hidden line prefix (`*`, `# `) goes past
    /// it, as `moveRight` does. Returns `false` when `source` is
    /// not on a divider, so the caller's normal path runs.
    private func moveOffHRRun(from source: Int, direction: CaretSnapDirection) -> Bool {
        guard let exit = hrRunExit(from: source, direction: direction) else { return false }
        switch exit {
        case .neighbor(let location):
            let landing = direction == .forward
                ? (checklistContentStart(ifLineStartAt: location) ?? hiddenPrefixEnd(ifLineStartAt: location) ?? location)
                : location
            setSelectedRange(NSRange(location: landing, length: 0))
        case .appendBelow:
            appendLineBelowTrailingHR()
        case .stay:
            break
        }
        return true
    }

    /// Mirror of AppKit's own Right step, which crosses one visible character
    /// AND the zero-width hidden markers after it in one press (`a **bold**`:
    /// Right 7 → 10). The backward rescues instead snap to the START of a
    /// hidden run (Left 10 → 8), which sits at the same on-screen point as
    /// the source: a press with no visible move, and typing there lands
    /// inside the bold. When every character between `landing` and `source`
    /// is a zero-width hidden marker (a link chip is excluded: it draws a
    /// pill), this continues one more character back through the rescue
    /// chain, so Left 10 → 7 reverses Right 7 → 10. Returns `nil` when no
    /// continuation applies (a visible move already happened, or nothing
    /// lies before `landing`).
    private func stepBackPastCollapsedMarkers(landing: Int, source: Int) -> Int? {
        guard let storage = textStorage, landing > 0, landing < source, source <= storage.length else { return nil }
        var onlyHiddenMarkers = true
        storage.enumerateAttributes(in: NSRange(location: landing, length: source - landing), options: []) { attrs, _, stop in
            if attrs[.sidekickHiddenMarker] == nil || attrs[.sidekickLinkChip] != nil {
                onlyHiddenMarkers = false
                stop.pointee = true
            }
        }
        guard onlyHiddenMarkers else { return nil }
        let ns = storage.string as NSString
        let previousCharacter = ns.rangeOfComposedCharacterSequence(at: landing - 1).location
        let past = correctedCaretTarget(fromNaive: previousCharacter, previous: landing, direction: .backward, naiveIsVerifiedStep: true)
            ?? previousCharacter
        return past < landing ? past : nil
    }

    /// Override of `NSResponder.moveDown(_:)` — fired by the Down arrow key.
    /// Unlike `moveRight`/`moveLeft`, vertical movement has no single-
    /// character naive step to reuse: AppKit's real `moveDown:` preserves the
    /// caret's on-screen x-position across lines via glyph geometry, which is
    /// not replicated here. Instead this computes a NAIVE same-column step
    /// into the next line via `NSString`'s line-start API — precise enough
    /// only to land somewhere inside the correct adjacent line's span, which
    /// is all `correctedCaretTarget`'s cheap gate needs to detect a managed
    /// region there and run the same five-helper rescue chain `moveRight`/
    /// `moveLeft` already use. When the adjacent line isn't managed, the
    /// naive guess is discarded and `super.moveDown(sender)` runs the real
    /// AppKit vertical move. A non-empty selection or no line below the
    /// current one also defers to `super`.
    override func moveDown(_ sender: Any?) {
        let current = selectedRange()
        guard current.length == 0, let storage = textStorage, storage.length > 0 else {
            super.moveDown(sender)
            return
        }
        if moveOffHRRun(from: current.location, direction: .forward) { return }
        let ns = storage.string as NSString
        var lineStart = 0, lineEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: NSRange(location: current.location, length: 0))
        guard lineEnd < storage.length else {
            super.moveDown(sender)
            return
        }
        let column = current.location - lineStart
        var belowStart = 0, belowContentsEnd = 0
        ns.getLineStart(&belowStart, end: nil, contentsEnd: &belowContentsEnd, for: NSRange(location: lineEnd, length: 0))
        let naive = min(belowStart + column, belowContentsEnd)
        if escapeBelowTrailingHR(from: current.location, toward: naive) { return }
        // `naiveIsVerifiedStep: false` — this naive same-column target is a
        // GUESS (see this override's own doc comment above), not a verified
        // one-raw-character step. The ticket-08 SOURCE-side conditions must
        // stay disabled here: trusting an unverified vertical guess as if it
        // were a real position would land the caret at a visually wrong
        // column whenever the adjacent line's real glyph-x-position column
        // differs from the raw-character-count column.
        guard let corrected = correctedCaretTarget(fromNaive: naive, previous: current.location, direction: .forward, naiveIsVerifiedStep: false) else {
            super.moveDown(sender)
            return
        }
        setSelectedRange(NSRange(location: corrected, length: 0))
    }

    /// Override of `NSResponder.moveUp(_:)` — fired by the Up arrow key.
    /// Mirrors `moveDown(_:)` above (same naive same-column-step rationale,
    /// opposite direction): probes the line above via the same line-start
    /// API, guarding on "no line above" (`lineStart == 0`) instead of "no
    /// line below".
    override func moveUp(_ sender: Any?) {
        let current = selectedRange()
        guard current.length == 0, let storage = textStorage, storage.length > 0 else {
            super.moveUp(sender)
            return
        }
        if moveOffHRRun(from: current.location, direction: .backward) { return }
        let ns = storage.string as NSString
        var lineStart = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: current.location, length: 0))
        guard lineStart > 0 else {
            super.moveUp(sender)
            return
        }
        let column = current.location - lineStart
        var aboveStart = 0, aboveContentsEnd = 0
        ns.getLineStart(&aboveStart, end: nil, contentsEnd: &aboveContentsEnd, for: NSRange(location: lineStart - 1, length: 0))
        let naive = min(aboveStart + column, aboveContentsEnd)
        // `naiveIsVerifiedStep: false` — see `moveDown(_:)`'s identical note
        // above; this same-column target is an unverified guess too.
        guard let corrected = correctedCaretTarget(fromNaive: naive, previous: current.location, direction: .backward, naiveIsVerifiedStep: false) else {
            super.moveUp(sender)
            return
        }
        setSelectedRange(NSRange(location: corrected, length: 0))
    }
}
