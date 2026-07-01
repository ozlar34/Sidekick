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
}
