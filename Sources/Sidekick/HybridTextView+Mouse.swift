/// `HybridTextView` click handling: the GFM checklist toggle, styled-link
/// label drag-selection, and the post-click caret relocation that keeps a
/// mouse-placed caret out of every managed region.

import AppKit
import SwiftUI

extension HybridTextView {

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
        // Styled-link label: AppKit never places a caret or tracks a text
        // selection on `.link` text, so own the whole gesture. See
        // `trackLinkLabelSelection`.
        if trackLinkLabelSelection(event) { return }
        super.mouseDown(with: event)
        // Click-path caret rescue: the `setSelectedRanges` snap chain runs INSIDE
        // super.mouseDown with a meaningless keyboard `previous` (a click has no
        // previous caret), so it can strand the caret on the wrong edge of a
        // managed region. Re-decide here from click GEOMETRY. See
        // `relocateCaretAfterClick`.
        relocateCaretAfterClick(event)
    }

    /// Styled-link label (`[label](url)`, label carries `.link`): NSTextView
    /// treats a mouseDown on `.link` text as a link click — it tracks to
    /// mouseUp, consults `clickedOnLink`, and never places the caret, even
    /// when the delegate declines the click. A drag from the label is a link
    /// drag, never a text selection. Either way the caret stays wherever it
    /// was, which reads as a jump. So for a plain / ⇧ single click, take over
    /// the gesture: place the caret (or ⇧-extend the current selection) at the
    /// insertion point, then run the same tracking loop AppKit would for plain
    /// text — extend the selection to each dragged point until mouseUp.
    /// ⌘-click is the open-URL gesture and multi-clicks already select word /
    /// paragraph through the normal path, so those fall through to `super`.
    /// Chips (a pill for a bare URL) are excluded — their own half-geometry
    /// rescue lives in `relocateCaretAfterClick`.
    ///
    /// Returns true when the gesture was consumed here.
    private func trackLinkLabelSelection(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1,
              !event.modifierFlags.contains(.command),
              let lm = layoutManager, let tc = textContainer, let storage = textStorage,
              let window else { return false }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let glyphIdx = lm.glyphIndex(for: textPoint, in: tc)
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < storage.length,
              storage.attribute(.link, at: charIdx, effectiveRange: nil) != nil,
              storage.attribute(.sidekickLinkChip, at: charIdx, effectiveRange: nil) == nil
        else { return false }

        if window.firstResponder !== self { window.makeFirstResponder(self) }

        // ⇧ extends from the existing selection; otherwise the mouseDown
        // insertion point is the anchor and the selection grows from there.
        let insertion = characterIndexForInsertion(at: viewPoint)
        let anchor = event.modifierFlags.contains(.shift)
            ? selectedRange()
            : NSRange(location: insertion, length: 0)
        func extend(to end: Int) {
            let lo = min(anchor.location, end)
            let hi = max(NSMaxRange(anchor), end)
            setSelectedRange(NSRange(location: lo, length: hi - lo))
        }
        extend(to: insertion)
        // Only dragged events move the selection end, as in AppKit's own loop;
        // the release point is wherever the last drag left it.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              next.type == .leftMouseDragged {
            autoscroll(with: next)
            extend(to: characterIndexForInsertion(at: convert(next.locationInWindow, from: nil)))
        }
        return true
    }

    /// Click-path counterpart to the `setSelectedRanges` snap chain. A mouse
    /// click has no meaningful "previous caret", so the keyboard snaps — which
    /// run inside `super.mouseDown` via `setSelectedRanges` — decide the side of
    /// a managed region from a stale `previous` and can strand the caret on the
    /// wrong edge. This runs after `super.mouseDown` and re-decides from click
    /// GEOMETRY, overriding that result. The regions are mutually exclusive (a
    /// line is at most one of HR / checklist prefix / link chip); first match
    /// wins. No-op when the click produced a range selection.
    ///
    /// Everything keys off the CLICKED glyph, never the post-`super` caret. Two
    /// reasons (surfaced as [8]/[9] on the HR case, general to all regions):
    ///   * The keyboard snap may already have moved the caret OFF the region
    ///     before we run — e.g. [9]: `snapCaretOutOfHR`'s same-line exemption
    ///     didn't fire, so it relocated by keyboard direction. Reading the
    ///     resolved caret would then see a non-region line and no-op. The
    ///     clicked glyph still points at what the user actually hit.
    ///   * [8] A region's geometry decision must come from the SAME line /
    ///     fragment the rescue acts on. Deriving both from one glyph keeps them
    ///     consistent even at a line-fragment boundary, where re-hit-testing the
    ///     point against the resolved caret's line could pick the adjacent
    ///     fragment and flip the decision.
    private func relocateCaretAfterClick(_ event: NSEvent) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let glyphIdx = lm.glyphIndex(for: textPoint, in: tc)
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)

        // Multi-click whose word / paragraph selection landed entirely inside a
        // checklist prefix (`- [ ] `): the prefix renders as a checkbox, so the
        // selection is invisible and the next keystroke would silently replace
        // hidden syntax. Collapse to content start; a selection that reaches
        // into the content (triple-click paragraph) is left alone.
        let current = selectedRange()
        if current.length > 0, let dest = checklistPrefixSelectionCollapseTarget(selection: current) {
            setSelectedRange(NSRange(location: dest, length: 0))
            return
        }

        // A drag that produced a range selection is the user's intent, not a
        // caret landing in a region — leave it alone.
        guard current.length == 0 else { return }

        // [8][9] HR line → nearest inhabitable neighbor by which half of the
        // divider the click landed in (top → line above, bottom → line below).
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let clickInBottomHalf = textPoint.y >= lineRect.midY
        if let dest = hrCaretRelocationTarget(caret: charIdx, clickInBottomHalf: clickInBottomHalf) {
            setSelectedRange(NSRange(location: dest, length: 0))
            return
        }

        // [4] Checklist prefix gap → content start. The gap (the `- [ ] `
        // interior, offsets 1…5) sits entirely to the RIGHT of the drawn
        // checkbox, so a click that resolved into it is a click "into" the item;
        // a click LEFT of the box resolves to offset 0 and never enters the gap.
        // No half decision needed — unlike the keyboard path there is no
        // backward direction a click can express here.
        if let dest = checklistGapRelocationTarget(caret: charIdx) {
            setSelectedRange(NSRange(location: dest, length: 0))
            return
        }

        // [7] Link-chip pill → leading edge (chipStart) for a click in the pill's
        // LEFT half, trailing edge (runEnd) for the RIGHT half. The pill is a
        // single wide control glyph at chipStart and the rest of the URL is
        // zero-width hidden chars, so a click anywhere on the pill hit-tests to
        // this one glyph. Split it at the glyph's horizontal midpoint — the
        // click-geometry analog of the HR top/bottom-half split above (x here,
        // y there). The keyboard snap's stale-`previous` side pick could jump a
        // left-of-pill click clear past the whole URL; geometry fixes that.
        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
        let clickInLeftHalf = textPoint.x < glyphRect.midX
        if let dest = linkChipRelocationTarget(caret: charIdx, clickInLeftHalf: clickInLeftHalf) {
            setSelectedRange(NSRange(location: dest, length: 0))
            return
        }
    }

}
