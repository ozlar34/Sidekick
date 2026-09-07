/// `HybridTextView` shift-arrow selection extension: anchor/edge resolution
/// for an in-progress extension chain, the per-step correction that reuses
/// `correctedCaretTarget`, and the four `move…AndModifySelection` overrides.
/// The chain state (`selectionExtensionAnchor` /
/// `selectionExtensionOwnedByOverride`) is stored on the class in
/// HybridTextView.swift.

import AppKit
import SwiftUI

extension HybridTextView {

    /// Resolve `(anchor, movingEdge)` for a modify-selection extension step,
    /// given the CURRENT selection (before this keypress). See
    /// `selectionExtensionAnchor`'s doc comment for why the anchor can't be
    /// read back out of `current` alone.
    ///
    /// Returns `nil` when `current` is non-empty but doesn't correspond to
    /// the tracked anchor — e.g. a mouse-drag or double-click selection that
    /// no shift-arrow chain established — since the anchor can't be
    /// determined safely in that case; callers defer to `super` rather than
    /// guess which edge to move.
    private func extensionAnchorAndEdge(for current: NSRange) -> (anchor: Int, edge: Int)? {
        if current.length == 0 {
            selectionExtensionOwnedByOverride = false
            return (current.location, current.location)
        }
        if let tracked = selectionExtensionAnchor {
            if tracked == current.location {
                return (tracked, NSMaxRange(current))
            }
            if tracked == NSMaxRange(current) {
                return (tracked, current.location)
            }
        }
        return nil
    }

    /// Shared step logic for both overrides below, given this step's naive
    /// (uncorrected) one-character target for the moving edge.
    ///
    /// Three outcomes:
    ///   1. `correctedCaretTarget` wants to correct `naive` (near a managed
    ///      region) — apply the correction, and latch
    ///      `selectionExtensionOwnedByOverride` so every later step in this
    ///      chain is also self-computed (see below).
    ///   2. Far from a managed region AND this chain has never been
    ///      corrected yet — defer to `super` (the "far from a managed
    ///      region defers to super" idiom the plain overrides also use).
    ///      This is the overwhelmingly common case, so ordinary shift-arrow
    ///      selection stays exactly native.
    ///   3. Far from a managed region BUT this chain WAS already corrected
    ///      at least once — apply the plain `naive` step ourselves instead
    ///      of deferring. This is not a general reimplementation of AppKit's
    ///      extension logic, just the same one-character step `naive`
    ///      already computed; the reason `super` can't be trusted here is
    ///      empirical: once this override calls `setSelectedRange` with a
    ///      range whose anchor sits at `NSMaxRange` (a Shift+Left-initiated
    ///      extension that has crossed a managed region), the very next
    ///      `super.move…AndModifySelection(sender)` call silently re-anchors
    ///      to the range's `location` instead of continuing from the true
    ///      anchor — confirmed by a throwaway repro: extend left across
    ///      "before\n---\nafter word" from mid-"after", where the press that
    ///      crosses the divider correctly jumps the selection to `{6, 7}`
    ///      (anchor 13, edge 6), but the FOLLOWING plain Shift+Left press,
    ///      handed to `super`, collapsed the selection to `{5, 1}` — the
    ///      anchor silently moved from 13 to 6. Once we've had to take
    ///      manual control of a chain even once, `super` can no longer be
    ///      trusted for the rest of that chain.
    /// `naiveIsVerifiedStep` is threaded straight through to
    /// `correctedCaretTarget` (see its doc comment) — `true` from
    /// `moveRightAndModifySelection`/`moveLeftAndModifySelection` (a real
    /// one-raw-character step), `false` from `moveDownAndModifySelection`/
    /// `moveUpAndModifySelection` (an unverified same-column guess). This
    /// function is shared by both horizontal and vertical modify-selection
    /// overrides, so it cannot assume either — the caller states it.
    private func stepExtension(anchor: Int, naive: Int, edge: Int, direction: CaretSnapDirection, naiveIsVerifiedStep: Bool) -> NSRange? {
        if let corrected = correctedCaretTarget(fromNaive: naive, previous: edge, direction: direction, naiveIsVerifiedStep: naiveIsVerifiedStep) {
            selectionExtensionOwnedByOverride = true
            return NSRange(location: min(anchor, corrected), length: abs(corrected - anchor))
        }
        guard selectionExtensionOwnedByOverride else { return nil }
        return NSRange(location: min(anchor, naive), length: abs(naive - anchor))
    }

    /// Override of `NSResponder.moveRightAndModifySelection(_:)` — fired by
    /// Shift+Right. Extends or shrinks the selection by moving its edge one
    /// character, reusing the exact naive-step + snap-rescue logic
    /// `moveRight(_:)` (HybridTextView+CaretMovement.swift) uses for a plain
    /// caret — `correctedCaretTarget`
    /// — applied to the moving edge (`extensionAnchorAndEdge(for:)`) instead
    /// of the caret, then recombined with the unchanged anchor into the new
    /// range via `stepExtension`. `min`/`abs` there (rather than a raw
    /// `location`/`length` pair) because the moving edge can cross to the
    /// other side of the anchor as the selection shrinks past zero and
    /// starts growing the other way — NSRange requires
    /// `location <= location + length`.
    ///
    /// Far from a managed region (the common case, and provided this
    /// extension chain hasn't needed a correction yet — see
    /// `stepExtension`'s doc comment), this defers straight to
    /// `super.moveRightAndModifySelection(sender)`, so ordinary shift-arrow
    /// selection is unaffected. Same when the anchor can't be resolved
    /// (`extensionAnchorAndEdge` returns `nil`) — this never guesses.
    ///
    /// The wrap logic applied afterward (Cmd+B/I/underline/strikethrough) is
    /// unchanged by this ticket — it already operates correctly on whatever
    /// `selectedRange()` it's handed, so fixing the selection here is
    /// sufficient to fix wrapping near a divider too.
    override func moveRightAndModifySelection(_ sender: Any?) {
        let current = selectedRange()
        guard let (anchor, edge) = extensionAnchorAndEdge(for: current), let storage = textStorage else {
            super.moveRightAndModifySelection(sender)
            return
        }
        selectionExtensionAnchor = anchor
        let naive = min(edge + 1, storage.length)
        guard naive != edge else {
            // Already at the document end — nothing left to extend into.
            // Once self-managed (see `stepExtension`), stay self-managed
            // even for a no-op step rather than handing back to `super`.
            if !selectionExtensionOwnedByOverride { super.moveRightAndModifySelection(sender) }
            return
        }
        guard let newRange = stepExtension(anchor: anchor, naive: naive, edge: edge, direction: .forward, naiveIsVerifiedStep: true) else {
            super.moveRightAndModifySelection(sender)
            return
        }
        setSelectedRange(newRange)
    }

    /// Override of `NSResponder.moveLeftAndModifySelection(_:)` — fired by
    /// Shift+Left. Mirrors `moveRightAndModifySelection(_:)` above (same
    /// rationale: reuse the shared anchor/edge resolution and step logic
    /// instead of reimplementing AppKit's extension logic from scratch).
    override func moveLeftAndModifySelection(_ sender: Any?) {
        let current = selectedRange()
        guard let (anchor, edge) = extensionAnchorAndEdge(for: current) else {
            super.moveLeftAndModifySelection(sender)
            return
        }
        selectionExtensionAnchor = anchor
        let naive = max(edge - 1, 0)
        guard naive != edge else {
            // Already at the document start — nothing left to extend into.
            // Once self-managed (see `stepExtension`), stay self-managed
            // even for a no-op step rather than handing back to `super`.
            if !selectionExtensionOwnedByOverride { super.moveLeftAndModifySelection(sender) }
            return
        }
        guard let newRange = stepExtension(anchor: anchor, naive: naive, edge: edge, direction: .backward, naiveIsVerifiedStep: true) else {
            super.moveLeftAndModifySelection(sender)
            return
        }
        setSelectedRange(newRange)
    }

    /// Override of `NSResponder.moveDownAndModifySelection(_:)` — fired by
    /// Shift+Down. Combines two things that already exist separately: the
    /// naive same-column vertical step `moveDown(_:)` (ticket 04) computes
    /// via `NSString.getLineStart(_:end:contentsEnd:for:)`, and the anchor/
    /// moving-edge extension bookkeeping `moveRightAndModifySelection(_:)`/
    /// `moveLeftAndModifySelection(_:)` (ticket 05) use via
    /// `extensionAnchorAndEdge(for:)` and `stepExtension`. The naive step is
    /// computed from the MOVING EDGE, not `current.location` — exactly the
    /// substitution `moveDown(_:)` would make if it were extending a
    /// selection instead of repositioning a caret, since the edge (not the
    /// anchor) is what "the current line" means for this keypress.
    ///
    /// Far from a managed region (the common case, and provided this
    /// extension chain hasn't needed a correction yet — see
    /// `stepExtension`'s doc comment), this defers straight to
    /// `super.moveDownAndModifySelection(sender)`, so ordinary vertical
    /// shift-extend keeps AppKit's real x-position-preserving glyph search.
    /// Same when the anchor can't be resolved, or there's no line below the
    /// edge's line — except once this chain is already self-managed
    /// (`selectionExtensionOwnedByOverride`), in which case a document-end
    /// no-op stays self-managed rather than handing back to `super`, mirroring
    /// the boundary idiom `moveRightAndModifySelection(_:)` uses for the
    /// document-end case.
    override func moveDownAndModifySelection(_ sender: Any?) {
        let current = selectedRange()
        guard let (anchor, edge) = extensionAnchorAndEdge(for: current),
              let storage = textStorage, storage.length > 0
        else {
            super.moveDownAndModifySelection(sender)
            return
        }
        selectionExtensionAnchor = anchor
        let ns = storage.string as NSString
        var lineStart = 0, lineEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: NSRange(location: edge, length: 0))
        guard lineEnd < storage.length else {
            // No line below the edge's line — nothing left to extend into.
            // Once self-managed (see `stepExtension`), stay self-managed
            // even for a no-op step rather than handing back to `super`.
            if !selectionExtensionOwnedByOverride { super.moveDownAndModifySelection(sender) }
            return
        }
        let column = edge - lineStart
        var belowStart = 0, belowContentsEnd = 0
        ns.getLineStart(&belowStart, end: nil, contentsEnd: &belowContentsEnd, for: NSRange(location: lineEnd, length: 0))
        let naive = min(belowStart + column, belowContentsEnd)
        // `naiveIsVerifiedStep: false` — see `moveDown(_:)`'s identical note:
        // this same-column target is an unverified guess, not a real step.
        guard let newRange = stepExtension(anchor: anchor, naive: naive, edge: edge, direction: .forward, naiveIsVerifiedStep: false) else {
            super.moveDownAndModifySelection(sender)
            return
        }
        setSelectedRange(newRange)
    }

    /// Override of `NSResponder.moveUpAndModifySelection(_:)` — fired by
    /// Shift+Up. Mirrors `moveDownAndModifySelection(_:)` above (same
    /// rationale: the naive same-column step comes from `moveUp(_:)`'s
    /// line-above computation, ticket 04, applied to the moving edge instead
    /// of `current.location`, and recombined with the anchor via the ticket
    /// 05 `stepExtension` machinery). The boundary condition mirrors
    /// `moveUp(_:)`'s own — "no line above" (`lineStart == 0` for the edge's
    /// line) instead of "no line below" — and the same "stay self-managed on
    /// a no-op once owned" idiom applies at the document start.
    override func moveUpAndModifySelection(_ sender: Any?) {
        let current = selectedRange()
        guard let (anchor, edge) = extensionAnchorAndEdge(for: current),
              let storage = textStorage, storage.length > 0
        else {
            super.moveUpAndModifySelection(sender)
            return
        }
        selectionExtensionAnchor = anchor
        let ns = storage.string as NSString
        var lineStart = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: edge, length: 0))
        guard lineStart > 0 else {
            // No line above the edge's line — nothing left to extend into.
            // Once self-managed (see `stepExtension`), stay self-managed
            // even for a no-op step rather than handing back to `super`.
            if !selectionExtensionOwnedByOverride { super.moveUpAndModifySelection(sender) }
            return
        }
        let column = edge - lineStart
        var aboveStart = 0, aboveContentsEnd = 0
        ns.getLineStart(&aboveStart, end: nil, contentsEnd: &aboveContentsEnd, for: NSRange(location: lineStart - 1, length: 0))
        let naive = min(aboveStart + column, aboveContentsEnd)
        // `naiveIsVerifiedStep: false` — see `moveUp(_:)`'s identical note:
        // this same-column target is an unverified guess, not a real step.
        guard let newRange = stepExtension(anchor: anchor, naive: naive, edge: edge, direction: .backward, naiveIsVerifiedStep: false) else {
            super.moveUpAndModifySelection(sender)
            return
        }
        setSelectedRange(newRange)
    }
}
