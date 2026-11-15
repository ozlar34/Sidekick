/// `HybridTextView` caret-snap geometry: pure "given this proposed caret
/// location, where should it actually land" helpers for each managed region
/// (thematic break, checklist prefix gap, link chip / tail, hidden marker
/// run). Every function here is side-effect free and returns `nil` to mean
/// "no correction needed" — the callers that act on the results live in
/// HybridTextView+CaretMovement.swift and HybridTextView+Mouse.swift.

import AppKit
import SwiftUI

extension HybridTextView {

    /// Explicit direction of caret travel for the five snap-rescue helpers
    /// below, mirroring `FormattingToolbarView.AtomicMarkerDeleteDirection`.
    /// Every rescue used to infer this by comparing `target` against a
    /// `previous` location it was handed; callers now compute it themselves
    /// and pass it in — `setSelectedRanges` still derives it from its own
    /// position comparison (`target > previous`), so behavior is unchanged
    /// today, but a caller that already knows the direction (e.g. a future
    /// keyboard override reacting to the arrow key pressed) no longer needs
    /// to reconstruct it from two positions.
    enum CaretSnapDirection { case forward, backward }

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
    /// `previous` is still needed here for the same-line exemption below —
    /// unlike the other four rescues, this one has to know where the caret
    /// WAS, not just which way it's headed. The caller-supplied `direction`
    /// replaces the old `target > previous` ordering check for the
    /// above/below tie-break:
    ///   * `.forward` → caret moving forward, snap DOWN to the start of the
    ///     line below HR.
    ///   * `.backward` → moving backward, snap UP to the end of the line
    ///     above HR.
    /// If only one neighbor exists, that wins regardless of direction.
    /// If neither exists (HR is the whole document), return `nil` and
    /// leave the caret alone — degenerate case, no good answer.
    // Internal (not private): called from correctedCaretTarget in
    // HybridTextView+CaretMovement.swift.
    func snapCaretOutOfHR(target: Int, previous: Int, direction: CaretSnapDirection) -> Int? {
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

        return hrNeighborLocation(hrLineRange: lineRange, preferBelow: direction == .forward)
    }

    /// Nearest inhabitable neighbor location for a caret leaving an HR line.
    /// `preferBelow` breaks the tie when both neighbors exist — the keyboard
    /// rescue passes direction-of-motion (`target > previous`), the mouse
    /// rescue passes which half of the divider was clicked. Returns the start
    /// of the line below (`belowLoc`) or the end of the line above (`aboveLoc`);
    /// `nil` only when the HR line is the entire document (nowhere to go).
    ///
    /// Consecutive dividers (`---\n---`) form one uninhabitable block: the
    /// neighbor search widens to the first / last HR line of the run before
    /// looking above and below, so the caret never lands on the adjacent HR
    /// (where a follow-up move would snap it in the wrong direction and a
    /// delete would act on the wrong line).
    private func hrNeighborLocation(hrLineRange lineRange: NSRange, preferBelow: Bool) -> Int? {
        guard let storage = textStorage, lineRange.length > 0 else { return nil }
        let ns = storage.string as NSString
        let n = ns.length

        func lineIsHR(_ range: NSRange) -> Bool {
            var found = false
            storage.enumerateAttribute(.sidekickThematicBreak, in: range, options: []) { value, _, stop in
                if (value as? Bool) == true { found = true; stop.pointee = true }
            }
            return found
        }
        // `lineRange(for:)` ends a line on LF, CR, CRLF, U+2028, U+2029 or NEL —
        // not just LF. A trailing terminator means a line exists below (even an
        // empty one), so test the last scalar against ALL newline scalars, not
        // only 0x0A (else e.g. PDF-pasted U+2028 misreads "no line below").
        func endsWithNewline(_ range: NSRange) -> Bool {
            let lastUnichar = ns.character(at: range.location + range.length - 1)
            return Unicode.Scalar(UInt32(lastUnichar)).map(CharacterSet.newlines.contains) ?? false
        }

        // Widen to the whole run of adjacent HR lines.
        var first = lineRange
        while first.location > 0 {
            let above = ns.lineRange(for: NSRange(location: first.location - 1, length: 0))
            guard above.length > 0, lineIsHR(above) else { break }
            first = above
        }
        var last = lineRange
        while endsWithNewline(last), last.location + last.length < n {
            let below = ns.lineRange(for: NSRange(location: last.location + last.length, length: 0))
            guard below.length > 0, lineIsHR(below) else { break }
            last = below
        }

        let hasAbove = first.location > 0
        let hasBelow = endsWithNewline(last)

        let aboveLoc = first.location - 1
        let belowLoc = last.location + last.length

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

    /// Click-path counterpart to `snapCaretOutOfChecklistGap`: given a caret a
    /// mouse click resolved into a rendered checklist prefix gap (offsets 1…5 of
    /// a `- [ ] ` / `- [x] ` line), return content start (line + 6). Unlike the
    /// keyboard path there is no direction to infer — the gap lies entirely to
    /// the RIGHT of the drawn checkbox, so any click that landed in it means
    /// "into the item" (a click LEFT of the box resolves to offset 0 and never
    /// reaches the gap). Returns `nil` when the caret is not in a checklist gap.
    ///
    /// Gated on `.sidekickChecklistMarker` at line start — mirrors
    /// `snapCaretOutOfChecklistGap` so a plain line that merely begins with the
    /// `- [ ] ` characters (no rendered checkbox) is left alone. Left `internal`
    /// so the decision is unit-testable without an AppKit mouse-tracking loop.
    func checklistGapRelocationTarget(caret: Int) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, caret >= 0, caret <= n else { return nil }

        let probeLoc = min(caret, n - 1)
        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: probeLoc, length: 0))
        guard lineRange.length >= 6,
              storage.attribute(.sidekickChecklistMarker,
                                at: lineRange.location,
                                effectiveRange: nil) != nil else { return nil }

        let contentStart = lineRange.location + 6
        guard caret > lineRange.location, caret < contentStart else { return nil }
        return contentStart
    }

    /// Multi-click counterpart to `checklistGapRelocationTarget`: given a RANGE
    /// selection (word / paragraph pick) that lies entirely within a rendered
    /// checklist prefix (`- [ ] `, offsets 0…5 of the line), return content
    /// start (line + 6). A selection that extends past the prefix into the
    /// item's content is a legitimate paragraph selection — return `nil`.
    /// Gated on `.sidekickChecklistMarker` like the caret-path helpers. Left
    /// `internal` so the decision is unit-testable without a mouse loop.
    func checklistPrefixSelectionCollapseTarget(selection: NSRange) -> Int? {
        guard let storage = textStorage, selection.length > 0 else { return nil }
        let n = storage.length
        guard selection.location < n else { return nil }

        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        guard lineRange.length >= 6,
              storage.attribute(.sidekickChecklistMarker,
                                at: lineRange.location,
                                effectiveRange: nil) != nil else { return nil }

        let contentStart = lineRange.location + 6
        let selectionEnd = selection.location + selection.length
        guard selection.location >= lineRange.location, selectionEnd <= contentStart else { return nil }
        return contentStart
    }

    /// Click-path counterpart to `snapCaretOutOfLinkChip`: given a caret a mouse
    /// click resolved onto a collapsed link-chip pill (a bare URL / `[url](url)`
    /// chip whose characters render as one pill), return the pill's leading edge
    /// (`chipStart`) for a click in its LEFT half, or its trailing edge
    /// (`runEnd`) for the RIGHT half. Unlike the keyboard path — which infers the
    /// side from a stale `previous` — a click carries its own geometry, so the
    /// half it landed in IS the whole decision. Returns `nil` when the caret is
    /// not on a chip.
    ///
    /// Detection mirrors `snapCaretOutOfLinkChip`: the caret must sit in a
    /// `.sidekickHiddenMarker` run whose extent carries a `.sidekickLinkChip`
    /// anchor, and the chip's leading edge is the anchor char — not the merged
    /// run's start, since a hidden block prefix (`> `/`# `) can coalesce into the
    /// same run (see `snapCaretOutOfLinkChip`).
    ///
    /// Fires when the caret is anywhere ON the pill (`chipStart …< runEnd`),
    /// INCLUDING `chipStart` itself — a pill click hit-tests to the single wide
    /// control glyph at the anchor char, so `characterIndexForGlyph` resolves it
    /// to `chipStart`. That is an on-pill hit here, not the already-valid leading
    /// edge it is for the keyboard path (which excludes `chipStart`). Left
    /// `internal` so the decision is unit-testable without a mouse-tracking loop.
    func linkChipRelocationTarget(caret: Int, clickInLeftHalf: Bool) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, caret >= 0, caret < n else { return nil }

        var runRange = NSRange(location: NSNotFound, length: 0)
        guard storage.attribute(.sidekickHiddenMarker,
                                at: caret,
                                longestEffectiveRange: &runRange,
                                in: NSRange(location: 0, length: n)) != nil else { return nil }

        var chipStart = NSNotFound
        storage.enumerateAttribute(.sidekickLinkChip, in: runRange, options: []) { value, range, stop in
            if value != nil { chipStart = range.location; stop.pointee = true }
        }
        guard chipStart != NSNotFound else { return nil }

        let runEnd = runRange.location + runRange.length
        guard caret >= chipStart, caret < runEnd else { return nil }

        return clickInLeftHalf ? chipStart : runEnd
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
    /// Direction is caller-supplied (mirrors `snapCaretOutOfHR`):
    ///   * `.forward` → moving forward, snap to content start (line+6)
    ///   * `.backward` → moving backward, snap to line start (line+0)
    // Internal (not private): called from correctedCaretTarget in
    // HybridTextView+CaretMovement.swift.
    func snapCaretOutOfChecklistGap(target: Int, direction: CaretSnapDirection) -> Int? {
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

        return direction == .forward ? contentStart : lineRange.location
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
    /// Direction is caller-supplied (mirrors `snapCaretOutOfHR`): `.forward` →
    /// run end, `.backward` → run start.
    // Internal (not private): called from correctedCaretTarget in
    // HybridTextView+CaretMovement.swift.
    func snapCaretOutOfLinkChip(target: Int, direction: CaretSnapDirection) -> Int? {
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
        return direction == .forward ? runEnd : chipStart
    }

    /// Compute the position to snap a caret to when `target` lands inside the
    /// hidden `](url)` tail of a STYLED markdown link (`[label](url)` where
    /// the label is not itself the URL — see `snapCaretOutOfLinkChip` for
    /// that case). The tail renders nothing (no pill, unlike a link chip),
    /// so without this rescue the caret silently steps through every hidden
    /// character one arrow-key press / click at a time — for a long URL that
    /// can be dozens of keypresses with no visible movement ([10]). Returns
    /// `nil` when no snap applies.
    ///
    /// Detection is attribute-based: `.sidekickLinkTailAnchor` is a key
    /// distinct from `.sidekickHiddenMarker` and applied only to the tail's
    /// own span (never merged with an adjacent hidden run from a different
    /// construct), so `longestEffectiveRange` always yields precisely the
    /// tail's own bounds — no chip-anchor disambiguation needed here.
    ///
    /// Direction is caller-supplied (mirrors `snapCaretOutOfHR` /
    /// `snapCaretOutOfChecklistGap`): `.forward` → tail end, `.backward` →
    /// tail start.
    // Internal (not private): called from correctedCaretTarget in
    // HybridTextView+CaretMovement.swift.
    func snapCaretOutOfLinkTail(target: Int, direction: CaretSnapDirection) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, target > 0, target < n else { return nil }

        var runRange = NSRange(location: NSNotFound, length: 0)
        guard storage.attribute(.sidekickLinkTailAnchor,
                                at: target,
                                longestEffectiveRange: &runRange,
                                in: NSRange(location: 0, length: n)) != nil else { return nil }

        // Snap only when strictly inside the tail — a caret at either edge
        // is already a valid resting spot.
        let runEnd = runRange.location + runRange.length
        guard target > runRange.location, target < runEnd else { return nil }

        return direction == .forward ? runEnd : runRange.location
    }

    /// Compute the position to snap a caret to when `target` lands strictly
    /// inside any remaining `.sidekickHiddenMarker` run not already owned by
    /// one of the four rescues above. Bold (`**`), strikethrough (`~~`), and
    /// underline (`<u>`/`</u>`) marker pairs are the primary targets — each
    /// has a 2+ character hidden run on at least one edge, so (like HR
    /// lines, checklist gaps, link chips, and link tails) a caret can land
    /// strictly between its edges, where every offset collapses to the same
    /// zero-width point. This rescue is deliberately generic — it treats ANY
    /// leftover `.sidekickHiddenMarker` run the same way, rather than adding
    /// a fifth/sixth/seventh marker-type-specific function. Italic (`*`) and
    /// inline code (`` ` ``) are 1-character runs with no interior offset to
    /// land on, so they never trigger the strictly-inside guard below —
    /// structurally immune, not specially handled.
    ///
    /// `longestEffectiveRange` merges immediately-adjacent hidden runs from
    /// DIFFERENT constructs into one span (e.g. a heading `# ` prefix butted
    /// against a following bold `**`, or a bold close `**` butted against a
    /// following strikethrough open `~~`). For pure caret positioning this is
    /// safe: every character in a merged span is equally zero-width and
    /// un-restable, so snapping to either true end of the WHOLE span is
    /// correct regardless of how many constructs contributed to it — there
    /// is no "which construct wins" ambiguity for movement (unlike the
    /// delete tie-break in `.scratch/inline-marker-delete-boundary/`).
    ///
    /// Exclusion: if the run at `target` carries (anywhere in its merged
    /// span) the fingerprint of a region one of the four rescues above
    /// already owns — an HR line, a checklist gap, a link chip, or a link
    /// tail — decline (`nil`) and let that rescue's own decision stand,
    /// INCLUDING an intentional decline (e.g. `snapCaretOutOfHR`'s same-line
    /// exemption while typing `---`, or `snapCaretOutOfLinkChip` leaving a
    /// merged heading-prefix-only portion alone). This is checked directly
    /// here — not left to `??`-chain ordering alone — so a merged run that
    /// spans both an owned construct and an unrelated marker is never
    /// partially re-handled. (Checklist gaps in practice never merge with an
    /// adjacent run — `applyChecklists` always leaves a visible separator
    /// space after the hidden ` [ ]`/` [x]` chars — but the line-start check
    /// is kept anyway as a direct, ordering-independent guard rather than an
    /// assumption.)
    ///
    /// Direction is caller-supplied (mirrors the other four): `.forward` →
    /// run end, `.backward` → run start.
    // Internal (not private): called from correctedCaretTarget in
    // HybridTextView+CaretMovement.swift.
    func snapCaretOutOfHiddenMarkerRun(target: Int, direction: CaretSnapDirection) -> Int? {
        guard let storage = textStorage else { return nil }
        let n = storage.length
        guard n > 0, target > 0, target < n else { return nil }

        var runRange = NSRange(location: NSNotFound, length: 0)
        guard storage.attribute(.sidekickHiddenMarker,
                                at: target,
                                longestEffectiveRange: &runRange,
                                in: NSRange(location: 0, length: n)) != nil else { return nil }

        // Snap only when strictly inside the run — either true edge is
        // already a valid resting spot.
        let runEnd = runRange.location + runRange.length
        guard target > runRange.location, target < runEnd else { return nil }

        // Defer to `snapCaretOutOfHR` for any run carrying a thematic-break
        // fingerprint — including its same-line exemption's intentional
        // decline.
        var ownsThematicBreak = false
        storage.enumerateAttribute(.sidekickThematicBreak, in: runRange, options: []) { value, _, stop in
            if (value as? Bool) == true { ownsThematicBreak = true; stop.pointee = true }
        }
        guard !ownsThematicBreak else { return nil }

        // Defer to `snapCaretOutOfLinkChip` / `snapCaretOutOfLinkTail` for
        // any run carrying either anchor, even outside the anchor's own
        // owned sub-span (e.g. a heading prefix merged with a following
        // chip) — those rescues' declines for the non-chip/tail portion of
        // such a merged run are intentional, not an oversight.
        var ownsLinkConstruct = false
        storage.enumerateAttribute(.sidekickLinkChip, in: runRange, options: []) { value, _, stop in
            if value != nil { ownsLinkConstruct = true; stop.pointee = true }
        }
        if !ownsLinkConstruct {
            storage.enumerateAttribute(.sidekickLinkTailAnchor, in: runRange, options: []) { value, _, stop in
                if value != nil { ownsLinkConstruct = true; stop.pointee = true }
            }
        }
        guard !ownsLinkConstruct else { return nil }

        // Defer to `snapCaretOutOfChecklistGap` for a checklist line.
        let ns = storage.string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: runRange.location, length: 0)).location
        guard storage.attribute(.sidekickChecklistMarker, at: lineStart, effectiveRange: nil) == nil else {
            return nil
        }

        return direction == .forward ? runEnd : runRange.location
    }

}
