/// `FormattingToolbarView` — Atomic inline-format marker delete: `atomicMarkerDeleteRange` and the
/// Backspace / forward-delete handlers built on it.

import AppKit
import SwiftUI

extension FormattingToolbarView {

    // MARK: - Atomic inline-format marker delete (quick-260524-0ia)
    //
    // Design decisions (locked — see PLAN.md for full rationale):
    //
    // D-01: ALWAYS delete the pair atomically — preserves inner text, removes
    //       both markers in one edit. Half-deleted markers expose raw markdown.
    // D-02: Cursor INSIDE a marker run also fires atomic delete — any partial
    //       deletion produces the same broken render.
    // D-03: Link [label](url) deletes the whole wrapper and keeps the label.
    // D-04: Routed via doCommand (NOT NSTextView override) — keeps delete logic
    //       unified with checklist handlers; priority: atomic-marker → checklist → default.
    // D-05: Detection uses the parser's named find* functions, NOT .sidekickHiddenMarker
    //       (that attribute is set on 4 different scopes — inline, block, bare-URL, link wrapper).
    // D-06: Return false when no pair is adjacent — preserves checklist & native delete.
    // D-07: Inside a fenced code block → return nil (markers are literal text there).
    // D-08: Adjacency is symmetric and inclusive at BOTH ends, for BOTH directions —
    //       `caret >= marker.location && caret <= marker.location + marker.length`.
    //       Marker characters render at zero visual width (hidden behind the
    //       formatted glyph), so the caret position immediately before and
    //       immediately after a marker run are visually indistinguishable to
    //       the user; both must fire the atomic delete, regardless of whether
    //       the keystroke is Backspace or forward-Delete.
    // D-09: Widening D-08 means the caret offset at the shared boundary between
    //       two back-to-back marker pairs (e.g. `**a****b**`) now matches BOTH
    //       pairs at once — the left pair's close edge and the right pair's
    //       open edge sit at the same zero-width offset. Resolved deterministically
    //       by direction, never by pass/iteration order: Backspace always takes
    //       the pair whose close marker ENDS at the caret (the pair to the
    //       caret's left); forward-Delete always takes the pair whose open
    //       marker STARTS at the caret (the pair to the caret's right). This
    //       tie-break applies whether the two pairs are the same marker type
    //       (checked within one pass) or different types (checked across passes).

    /// Direction for an atomic-marker delete keystroke.
    enum AtomicMarkerDeleteDirection { case backward, forward }

    /// Result of an atomic-marker delete decision.
    struct AtomicMarkerDeleteResult: Equatable {
        /// The full NSRange to replace (open marker + inner content + close marker).
        let deleteRange: NSRange
        /// The inner content text to leave in place of the deletion.
        let replacement: String
        /// Caret location AFTER the edit: deleteRange.location + replacement.utf16 count.
        let postCaret: Int
    }

    /// Determine whether a Backspace / forward-delete at `caret` should be
    /// promoted to an atomic inline-format marker pair deletion.
    ///
    /// Returns nil when no inline-format pair has marker bytes adjacent to
    /// (or containing) `caret`, or when the caret is inside a fenced code
    /// block (D-07), or body is empty.
    ///
    /// Adjacency rule (D-08 — symmetric, inclusive both ends, same for both
    /// directions):
    ///   caret >= marker.location && caret <= marker.location + marker.length
    ///
    /// Because this widened rule can match more than one marker pair at a
    /// shared zero-width boundary (D-09), every pass below COLLECTS candidates
    /// instead of returning on first match; the final resolution step picks
    /// the direction-correct candidate when more than one matched.
    ///
    /// Pair-detection order (tie-break fallback order only — see below, this
    /// is NOT a first-match-wins order once more than one pass can match):
    ///   1. Links (findLinkRanges) — largest containing structure
    ///   2. Underline (findUnderlineRanges) — asymmetric close (`</u>`, 4 chars)
    ///   3. Bold (findBoldRanges)
    ///   4. Strikethrough (findStrikethroughRanges)
    ///   5. Inline code (findInlineCodeRanges)
    ///   6. Italic (findItalicRanges) — 1-char markers, checked last to avoid
    ///      false matches inside bold/strike runs.
    ///   (The bare-URL pass — findAutoLinkRanges, "1b" at the call site below —
    ///   runs right after Links but is intentionally left out of this numbered
    ///   list: it uses its own unwidened adjacency predicate, not D-08.)
    ///
    /// Resolution when multiple candidates match the same caret (D-09):
    ///   - Exactly one candidate → return it (today's behavior, unchanged).
    ///   - Multiple candidates, Backspace → prefer the one whose close marker
    ///     ends exactly at `caret` (the pair to the caret's left).
    ///   - Multiple candidates, forward-Delete → prefer the one whose open
    ///     marker starts exactly at `caret` (the pair to the caret's right).
    ///   - Multiple candidates, no direction-correct match (shouldn't occur
    ///     with well-formed non-overlapping markdown) → fall back to the
    ///     first candidate in pass-detection order above.
    static func atomicMarkerDeleteRange(
        body: String,
        caret: Int,
        direction: AtomicMarkerDeleteDirection
    ) -> AtomicMarkerDeleteResult? {
        let ns = body as NSString
        guard ns.length > 0 else { return nil }

        // D-07: fenced code block guard — markers are literal inside fences.
        for fence in MarkdownInlineParser.findFencedCodeBlocks(in: body) {
            let cr = fence.contentRange
            if caret >= cr.location && caret <= cr.location + cr.length {
                return nil
            }
        }

        // Adjacency predicate (D-02: inside the run also fires; D-08: symmetric,
        // inclusive at both ends, identical for both directions — hence no
        // direction parameter, unlike `isAdjacentBareURL` below).
        func isAdjacent(_ markerRange: NSRange, _ caret: Int) -> Bool {
            return caret >= markerRange.location && caret <= markerRange.location + markerRange.length
        }

        // Bare-URL adjacency predicate — intentionally NOT widened by D-08.
        // A bare URL collapses to a single visible link-chip pill, unlike the
        // zero-width `**`/`~~`/`` ` ``/`<u>` markers: its leading and trailing
        // edges are real, visually distinct resting spots (the char just
        // before vs. just after the pill), not an ambiguous shared point. The
        // caret positions immediately outside the pill are ordinary text
        // positions, so this pass keeps its original direction-dependent
        // half-open range — Backspace at the pill's leading edge and
        // forward-Delete at its trailing edge fall through to a normal
        // single-character delete, exactly as before (see
        // BareURLCursorAndDeleteTests.swift).
        func isAdjacentBareURL(_ markerRange: NSRange, _ caret: Int, _ dir: AtomicMarkerDeleteDirection) -> Bool {
            switch dir {
            case .backward:
                return caret > markerRange.location && caret <= markerRange.location + markerRange.length
            case .forward:
                return caret >= markerRange.location && caret < markerRange.location + markerRange.length
            }
        }

        // A candidate atomic-delete match, gathered from any pass below.
        // `openStart` / `closeEnd` are the span's outer bounds — used only for
        // the D-09 tie-break resolution, not for the delete itself.
        struct Candidate {
            let openStart: Int
            let closeEnd: Int
            let result: AtomicMarkerDeleteResult
        }
        var candidates: [Candidate] = []

        // Shared Candidate constructor — every pass below resolves its own
        // range shape down to a span + replacement, then builds the
        // deleteRange/postCaret/Candidate the same way through here, so the
        // three call sites (link, bare-URL, pair-shaped) stay uniform even
        // though what feeds them differs.
        func makeCandidate(spanStart: Int, spanEnd: Int, replacement: String) -> Candidate {
            let deleteRange = NSRange(location: spanStart, length: spanEnd - spanStart)
            let postCaret = spanStart + (replacement as NSString).length
            return Candidate(
                openStart: spanStart,
                closeEnd: spanEnd,
                result: AtomicMarkerDeleteResult(deleteRange: deleteRange, replacement: replacement, postCaret: postCaret)
            )
        }

        // Shared candidate-builder for the five identical-shaped marker/content
        // passes below (underline, bold, strikethrough, inline code, italic).
        func addPairCandidate(openRange: NSRange, closeRange: NSRange, contentRange: NSRange) {
            guard isAdjacent(openRange, caret) || isAdjacent(closeRange, caret) else { return }
            candidates.append(makeCandidate(
                spanStart: openRange.location,
                spanEnd: closeRange.location + closeRange.length,
                replacement: ns.substring(with: contentRange)
            ))
        }

        // 1. Link pass — highest priority (outer structure).
        for m in MarkdownInlineParser.findLinkRanges(in: body) {
            let adjacentToMarker = isAdjacent(m.openBracketRange, caret)
                || isAdjacent(m.closeBracketRange, caret)
                || isAdjacent(m.openParenRange, caret)
                || isAdjacent(m.urlRange, caret)
                || isAdjacent(m.closeParenRange, caret)
            if adjacentToMarker {
                candidates.append(makeCandidate(
                    spanStart: m.openBracketRange.location,
                    spanEnd: m.closeParenRange.location + m.closeParenRange.length,
                    replacement: ns.substring(with: m.labelRange)   // D-03: keep label only
                ))
            }
        }

        // 1b. Bare-URL pass — whole-URL atomic delete. A bare URL renders as a
        //     single collapsed link chip (every char hidden behind one pill),
        //     so a Backspace/forward-Delete adjacent to it must remove the
        //     entire URL in one step — parity with how `[label](url)` deletes
        //     atomically above. There is no marker/label to keep, so the whole
        //     span is the delete range and the replacement is empty.
        //
        //     Ordered before the emphasis passes so a URL containing `_`, `*`,
        //     or `~` is never mis-split by the bold/italic/strike parsers
        //     (e.g. `https://host/a_b_c` must not delete just `_b_`).
        //
        //     Uses `isAdjacentBareURL`, NOT the widened `isAdjacent` — this
        //     pass is deliberately out of scope for the D-08 boundary widening
        //     (see that predicate's doc comment above).
        for urlRange in MarkdownInlineParser.findAutoLinkRanges(in: body) {
            if isAdjacentBareURL(urlRange, caret, direction) {
                candidates.append(makeCandidate(
                    spanStart: urlRange.location,
                    spanEnd: urlRange.location + urlRange.length,
                    replacement: ""
                ))
            }
        }

        // 2. Underline pass — asymmetric close (`</u>` = 4 chars) before bold.
        for m in MarkdownInlineParser.findUnderlineRanges(in: body) {
            addPairCandidate(openRange: m.markerOpenRange, closeRange: m.markerCloseRange, contentRange: m.contentRange)
        }

        // 3. Bold pass.
        for m in MarkdownInlineParser.findBoldRanges(in: body) {
            addPairCandidate(openRange: m.markerOpenRange, closeRange: m.markerCloseRange, contentRange: m.contentRange)
        }

        // 4. Strikethrough pass.
        for m in MarkdownInlineParser.findStrikethroughRanges(in: body) {
            addPairCandidate(openRange: m.markerOpenRange, closeRange: m.markerCloseRange, contentRange: m.contentRange)
        }

        // 5. Inline code pass.
        for m in MarkdownInlineParser.findInlineCodeRanges(in: body) {
            addPairCandidate(openRange: m.markerOpenRange, closeRange: m.markerCloseRange, contentRange: m.contentRange)
        }

        // 6. Italic pass — 1-char markers, lowest priority, checked last to
        //    avoid false matches inside bold/strike runs.
        for m in MarkdownInlineParser.findItalicRanges(in: body) {
            addPairCandidate(openRange: m.markerOpenRange, closeRange: m.markerCloseRange, contentRange: m.contentRange)
        }

        // Resolution (D-09): single match is unambiguous (today's behavior,
        // unchanged); multiple matches at a shared boundary are resolved by
        // direction, not by which pass happened to run first.
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0].result }

        switch direction {
        case .backward:
            if let left = candidates.first(where: { $0.closeEnd == caret }) {
                return left.result
            }
        case .forward:
            if let right = candidates.first(where: { $0.openStart == caret }) {
                return right.result
            }
        }
        return candidates[0].result
    }

    /// Atomic-marker Backspace handler (quick-260524-0ia).
    /// Returns true when a collapsed caret is adjacent to (or inside) an
    /// inline-format marker run and the full pair was deleted atomically.
    /// Returns false for non-collapsed selections (D-06) and when no pair
    /// is adjacent — caller falls through to the existing checklist handler.
    static func handleAtomicMarkerBackspace(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }   // D-06: non-empty selection → false
        guard let result = atomicMarkerDeleteRange(
            body: textView.string,
            caret: selection.location,
            direction: .backward
        ) else { return false }

        guard textView.shouldChangeText(in: result.deleteRange, replacementString: result.replacement) else { return false }
        textView.replaceCharacters(in: result.deleteRange, with: result.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: result.postCaret, length: 0))
        return true
    }

    /// Atomic-marker forward-delete handler (quick-260524-0ia).
    /// Returns true when a collapsed caret is adjacent to (or inside) an
    /// inline-format marker run and the full pair was deleted atomically.
    /// Returns false for non-collapsed selections (D-06) and when no pair
    /// is adjacent — caller falls through to the existing checklist handler.
    static func handleAtomicMarkerForwardDelete(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }   // D-06: non-empty selection → false
        guard let result = atomicMarkerDeleteRange(
            body: textView.string,
            caret: selection.location,
            direction: .forward
        ) else { return false }

        guard textView.shouldChangeText(in: result.deleteRange, replacementString: result.replacement) else { return false }
        textView.replaceCharacters(in: result.deleteRange, with: result.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: result.postCaret, length: 0))
        return true
    }
}
