import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// User-reported bug: a bare URL is ~24 real characters collapsed behind a
// single link-chip pill (all chars `.sidekickHiddenMarker`, anchored on the
// first char). Two things were unfinished for that hidden region:
//   (1) NO atomic delete — Backspace next to a URL silently removed ONE hidden
//       character at a time, quietly corrupting it (`…/page` → `…/pag`).
//   (2) NO cursor rescue — a click into the pill stranded the caret inside the
//       invisible tail.
//
// Fixes:
//   (a) `atomicMarkerDeleteRange` gains a bare-URL pass (via `findAutoLinkRanges`)
//       so one Backspace/forward-Delete removes the whole URL — parity with how
//       `[label](url)` already deletes atomically. Ordered before the emphasis
//       passes so a URL containing `_`/`*`/`~` is never mis-split.
//   (b) `HybridTextView.snapCaretOutOfLinkChip` treats the chip run as atomic:
//       a caret landing on the hidden interior snaps out (forward → run end,
//       backward → run start).
@MainActor
final class BareURLCursorAndDeleteTests: XCTestCase {

    private typealias Dir = FormattingToolbarView.AtomicMarkerDeleteDirection

    private func delete(_ body: String, caret: Int, _ dir: Dir)
        -> FormattingToolbarView.AtomicMarkerDeleteResult?
    {
        FormattingToolbarView.atomicMarkerDeleteRange(body: body, caret: caret, direction: dir)
    }

    // MARK: - (a) Atomic whole-URL delete (pure function)

    // Body "go https://example.com/page end":
    //   "go " = 0…2, URL = offsets 3…26 (24 chars), " " = 27, "end" = 28…30.
    private let body = "go https://example.com/page end"

    /// Backspace at the position right after the URL deletes the whole URL.
    /// Pre-fix: only one hidden char was removed (length 31 → 30).
    func test_backspaceAtURLEnd_deletesWholeURL() {
        let r = delete(body, caret: 27, .backward)
        XCTAssertEqual(r?.deleteRange, NSRange(location: 3, length: 24),
                       "Backspace adjacent to a bare URL must delete its full 24-char span")
        XCTAssertEqual(r?.replacement, "", "Bare URL has no label to keep")
        XCTAssertEqual(r?.postCaret, 3, "Caret lands where the URL began")
    }

    /// Forward-delete at the position right before the URL deletes the whole URL.
    func test_forwardDeleteAtURLStart_deletesWholeURL() {
        let r = delete(body, caret: 3, .forward)
        XCTAssertEqual(r?.deleteRange, NSRange(location: 3, length: 24))
        XCTAssertEqual(r?.replacement, "")
        XCTAssertEqual(r?.postCaret, 3)
    }

    /// Backspace at the URL's leading edge is NOT the URL — it deletes the
    /// preceding character normally (atomic pass declines).
    func test_backspaceAtURLStart_fallsThrough() {
        XCTAssertNil(delete(body, caret: 3, .backward),
                     "Backspace at the URL's leading edge must fall through to a normal char delete")
    }

    /// Forward-delete at the URL's trailing edge is NOT the URL — it deletes the
    /// following character normally.
    func test_forwardDeleteAtURLEnd_fallsThrough() {
        XCTAssertNil(delete(body, caret: 27, .forward),
                     "Forward-delete at the URL's trailing edge must fall through to a normal char delete")
    }

    /// A caret that (defensively) sits inside the URL still deletes the whole
    /// span in one step.
    func test_deleteFromInsideURL_deletesWholeURL() {
        let r = delete(body, caret: 15, .backward)
        XCTAssertEqual(r?.deleteRange, NSRange(location: 3, length: 24))
    }

    /// A URL containing `_` must delete as ONE unit, not be mis-split by the
    /// italic/underline parser into a `_b_` emphasis run. This guards the
    /// bare-URL pass ordering (before the emphasis passes).
    func test_urlWithUnderscores_deletesWholeURL_notEmphasis() {
        // "https://ex.com/a_b_c" = offsets 0…19 (20 chars).
        let r = delete("https://ex.com/a_b_c", caret: 20, .backward)
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 20),
                       "The whole URL must delete — the `_b_` inside must not be treated as emphasis")
        XCTAssertEqual(r?.replacement, "")
    }

    // MARK: - (b) Cursor rescue out of the chip interior (hosted)

    /// Forward motion into the hidden URL interior snaps to just after the pill.
    /// Pre-fix: the caret rested inside (invisible), offset unchanged.
    func test_forwardIntoURL_snapsToRunEnd() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 12, length: 0))   // mid-URL, forward from 0
        XCTAssertEqual(
            tv.selectedRange().location, 27,
            "Caret cannot rest inside the URL chip — forward motion snaps to just after it (27)"
        )
    }

    /// Backward motion into the hidden URL interior snaps to just before the pill.
    func test_backwardIntoURL_snapsToRunStart() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 28, length: 0)  // 'e' of "end" (no snap)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 20, length: 0))   // mid-URL, backward from 28
        XCTAssertEqual(
            tv.selectedRange().location, 3,
            "Backward motion into the URL chip snaps to just before it (3)"
        )
    }

    /// Just before the pill (the chip anchor / run leading edge) is a valid
    /// resting spot — never snapped.
    func test_leadingEdge_notSnapped() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 3, "The leading edge just before the pill stays inhabitable")
    }

    /// Just after the pill (on the following space) is a valid resting spot.
    func test_trailingEdge_notSnapped() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 27, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 27, "The trailing edge just after the pill stays inhabitable")
    }

    /// The chip anchor carries a `.toolTip` with the full URL (discoverability
    /// hint — hover reveals the destination and that it is ⌘-clickable).
    func test_chipAnchor_carriesFullURLTooltip() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tip = runner.inner.storage.attribute(.toolTip, at: 3, effectiveRange: nil) as? String
        XCTAssertEqual(tip, "https://example.com/page",
                       "The link-chip anchor must expose the full URL as a hover tooltip")
    }

    // MARK: - (c) Block-prefix + bare-URL over-merge (chip-anchor leading edge)
    //
    // `.sidekickHiddenMarker` is stored uniformly `true`, so `longestEffective-
    // Range` merges a chip's hidden run with an adjacent hidden block prefix
    // (blockquote `> ` / heading `# `) whose content is itself a bare URL. The
    // snap must anchor the chip's leading edge on the `.sidekickLinkChip` char,
    // not the merged run's start, or the caret gets trapped in the prefix and
    // teleported past the whole URL. Body "> https://example.com": `> ` = 0…1,
    // URL = offsets 2…20 (19 chars, chip anchor at 2).
    private let quotedURL = "> https://example.com"

    /// Precondition: the URL inside a blockquote is still chipped (anchor at 2).
    func test_quotedURL_isChipped() {
        let runner = HostedEditorRunner(
            initialBody: quotedURL,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let chip = runner.inner.storage.attribute(.sidekickLinkChip, at: 2, effectiveRange: nil)
        XCTAssertNotNil(chip, "A bare URL inside a blockquote must still render as a link chip")
    }

    /// The URL's leading edge (just after the hidden `> ` prefix, offset 2) is a
    /// valid resting spot — the merged prefix must not make the snap treat it as
    /// chip interior. Pre-fix: `target > runRange.location` (2 > 0) fired and the
    /// caret teleported to the URL's trailing edge.
    func test_quotedURL_leadingEdgeNotSnapped() {
        let runner = HostedEditorRunner(
            initialBody: quotedURL,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))   // forward from 0, onto the URL start
        XCTAssertEqual(
            tv.selectedRange().location, 2,
            "The caret must rest between the `> ` prefix and the URL, not teleport past the pill"
        )
    }

    /// A caret in the hidden `> ` prefix (offset 1) belongs to the blockquote
    /// prefix, not the chip — it must not be snapped to the URL's trailing edge.
    /// Pre-fix: offset 1 was inside the merged run and jumped to the URL end.
    func test_quotedURL_prefixOffsetNotTreatedAsChip() {
        let runner = HostedEditorRunner(
            initialBody: quotedURL,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 1, length: 0))   // inside the hidden `> ` prefix
        XCTAssertEqual(
            tv.selectedRange().location, 1,
            "A caret in the hidden block prefix must not be dragged past the URL chip"
        )
    }

    /// Genuine chip interior still snaps: a caret mid-URL (offset 10) moving
    /// forward lands just after the pill (offset 21), proving the fix narrowed
    /// the leading edge without disabling the rescue.
    func test_quotedURL_interiorStillSnapsForward() {
        let runner = HostedEditorRunner(
            initialBody: quotedURL,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 10, length: 0))   // mid-URL, forward from 0
        XCTAssertEqual(
            tv.selectedRange().location, 21,
            "A caret in the URL interior still snaps out to just after the pill (21)"
        )
    }

    // MARK: - (d) Click-path decision ([7], via linkChipRelocationTarget)
    //
    // The keyboard `snapCaretOutOfLinkChip` picks its side from the stale
    // `previous` — meaningless for a mouse click, so a left-of-pill click could
    // land the caret after the WHOLE URL. The click path instead calls
    // `linkChipRelocationTarget`, deciding purely from which half of the pill
    // glyph the click hit: left → leading edge (chipStart), right → trailing
    // edge (runEnd). A pill click hit-tests to the single control glyph at the
    // anchor char, so `characterIndexForGlyph` resolves it to `chipStart`; the
    // helper therefore treats `chipStart` as an on-pill hit (the keyboard snap
    // excludes it). The full click geometry (glyph → point) is verified live —
    // a synthetic mid-line on-glyph click can't produce a zero-length caret in
    // this harness — so only the decision is unit-tested here, mirroring
    // `ChecklistGapCaretTrapTests`' click section.
    //
    // Body "go https://example.com/page end": chip anchor at 3, URL run 3…26,
    // runEnd = 27.

    /// A click in the pill's LEFT half relocates to the leading edge (chipStart).
    func test_clickTarget_leftHalf_goesToChipStart() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertEqual(
            tv.linkChipRelocationTarget(caret: 3, clickInLeftHalf: true), 3,
            "A click on the left half of the pill must place the caret before it (chipStart 3)"
        )
    }

    /// A click in the pill's RIGHT half relocates to the trailing edge (runEnd).
    func test_clickTarget_rightHalf_goesToRunEnd() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertEqual(
            tv.linkChipRelocationTarget(caret: 3, clickInLeftHalf: false), 27,
            "A click on the right half of the pill must place the caret after it (runEnd 27)"
        )
    }

    /// A caret resolved into the hidden interior (defensive — pill clicks resolve
    /// to the anchor) still decides by the same left/right geometry.
    func test_clickTarget_hiddenInterior_decidesByHalf() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertEqual(tv.linkChipRelocationTarget(caret: 15, clickInLeftHalf: true), 3)
        XCTAssertEqual(tv.linkChipRelocationTarget(caret: 15, clickInLeftHalf: false), 27)
    }

    /// The trailing edge (offset 27, on the following space) is not on the pill —
    /// a click there is left alone regardless of half.
    func test_clickTarget_trailingEdge_notRelocated() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertNil(tv.linkChipRelocationTarget(caret: 27, clickInLeftHalf: true))
        XCTAssertNil(tv.linkChipRelocationTarget(caret: 27, clickInLeftHalf: false))
    }

    /// A plain (non-chip) character is never relocated — the rescue is gated on
    /// the hidden-marker + chip-anchor combination.
    func test_clickTarget_plainChar_notRelocated() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        XCTAssertNil(
            tv.linkChipRelocationTarget(caret: 29, clickInLeftHalf: true),
            "A click on ordinary text (the 'n' of 'end') must not be relocated"
        )
    }

    /// The hidden `> ` block prefix in front of a quoted URL is not the chip —
    /// a click resolving into the prefix must not be dragged onto the pill's
    /// edges (guards the chip-anchor leading-edge disambiguation on the click
    /// path too). Body "> https://example.com": prefix 0…1, chip anchor at 2.
    func test_clickTarget_quotedPrefix_notTreatedAsChip() {
        let runner = HostedEditorRunner(
            initialBody: quotedURL,
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView
        // Offset 1 is inside the hidden `> ` prefix (before chipStart 2).
        XCTAssertNil(tv.linkChipRelocationTarget(caret: 1, clickInLeftHalf: true))
        XCTAssertNil(tv.linkChipRelocationTarget(caret: 1, clickInLeftHalf: false))
        // The chip anchor itself (offset 2) IS on the pill and decides by half.
        XCTAssertEqual(tv.linkChipRelocationTarget(caret: 2, clickInLeftHalf: true), 2)
        XCTAssertEqual(tv.linkChipRelocationTarget(caret: 2, clickInLeftHalf: false), 21)
    }
}
