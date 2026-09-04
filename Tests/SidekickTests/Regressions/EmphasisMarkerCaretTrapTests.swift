import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// `MarkdownTextStorage` tags EVERY syntax marker — bold `**`, strikethrough
// `~~`, underline `<u>`/`</u>`, italic `*`, inline code `` ` ``, plus the
// line-prefix markers HR/checklist/link already have rescues for — with the
// same `.sidekickHiddenMarker` attribute, which `MarkdownLayoutManager` turns
// into a zero-width `.null` glyph. Every offset INSIDE a 2+ character hidden
// run collapses to the same on-screen point, so arrow-key / click caret
// placement there is geometry-confused: confirmed live via the debug harness
// against `"**Simple**\nnext line"` as actual direction reversal (Right-arrow
// moving the caret backward) and multi-position overshoot.
//
// `HybridEditorView.setSelectedRanges` already carried four purpose-built
// rescues for the other hidden-region producers (HR lines, checklist gaps,
// link chips, styled-link tails) but none of them fired for bold/strike-
// through/underline, because those markers pass the generic `.sidekickHidden-
// Marker` gate without matching any of the four specific detectors.
//
// Fix: a fifth, deliberately GENERIC rescue, `snapCaretOutOfEmphasisMarker`,
// redirects any caret landing strictly inside a leftover `.sidekickHidden-
// Marker` run (not already owned by one of the four rescues above) to the
// run's near edge (backward travel) or far edge (forward travel) — same
// direction convention as the other four. Italic (`*`) and inline code
// (`` ` ``) are 1-character runs with no interior offset to land on, so
// they're structurally immune to this defect; they're covered here only as
// regression proof, not because the fix changes their behavior.
@MainActor
final class EmphasisMarkerCaretTrapTests: XCTestCase {

    // MARK: - Bold (`**`)

    // "before **bold** after"
    // offsets: "before " = 0…6, open "**" = 7…8, content "bold" = 9…12,
    // close "**" = 13…14, " after" = 15…20.
    private let boldBody = "before **bold** after"

    /// Forward motion into the close marker's interior snaps to its far edge.
    /// Pre-fix: the caret rested inside (invisible), offset unchanged.
    func test_bold_forwardIntoInterior_snapsToFarEdge() {
        let runner = HostedEditorRunner(initialBody: boldBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 14, length: 0))   // interior of close "**", forward from 0
        XCTAssertEqual(
            tv.selectedRange().location, 15,
            "Caret cannot rest inside the hidden close marker — forward motion snaps to just after it (15)"
        )
    }

    /// Backward motion into the close marker's interior snaps to its near edge.
    func test_bold_backwardIntoInterior_snapsToNearEdge() {
        let runner = HostedEditorRunner(initialBody: boldBody, initialSelection: NSRange(location: 18, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 14, length: 0))   // interior of close "**", backward from 18
        XCTAssertEqual(
            tv.selectedRange().location, 13,
            "Backward motion into the hidden close marker snaps to just before it (13)"
        )
    }

    /// The leading edge (right after content, before the close marker) is a
    /// valid resting spot — never snapped.
    func test_bold_leadingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: boldBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 13, "Just after the content / before the close marker must stay inhabitable")
    }

    /// The trailing edge (right after the close marker) is a valid resting spot.
    func test_bold_trailingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: boldBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 15, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 15, "Just after the close marker must stay inhabitable")
    }

    // MARK: - Strikethrough (`~~`)

    // "before ~~struck~~ after"
    // offsets: "before " = 0…6, open "~~" = 7…8, content "struck" = 9…14,
    // close "~~" = 15…16, " after" = 17…22.
    private let strikeBody = "before ~~struck~~ after"

    func test_strikethrough_forwardIntoInterior_snapsToFarEdge() {
        let runner = HostedEditorRunner(initialBody: strikeBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 16, length: 0))   // interior of close "~~", forward from 0
        XCTAssertEqual(
            tv.selectedRange().location, 17,
            "Caret cannot rest inside the hidden close marker — forward motion snaps to just after it (17)"
        )
    }

    func test_strikethrough_backwardIntoInterior_snapsToNearEdge() {
        let runner = HostedEditorRunner(initialBody: strikeBody, initialSelection: NSRange(location: 20, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 16, length: 0))   // interior of close "~~", backward from 20
        XCTAssertEqual(
            tv.selectedRange().location, 15,
            "Backward motion into the hidden close marker snaps to just before it (15)"
        )
    }

    func test_strikethrough_leadingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: strikeBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 15, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 15, "Just after the content / before the close marker must stay inhabitable")
    }

    func test_strikethrough_trailingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: strikeBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 17, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 17, "Just after the close marker must stay inhabitable")
    }

    // MARK: - Underline (`<u>` / `</u>`) — asymmetric 3-char open / 4-char close

    // "before <u>underlined</u> after"
    // offsets: "before " = 0…6, open "<u>" = 7…9, content "underlined" = 10…19,
    // close "</u>" = 20…23, " after" = 24…29.
    private let underlineBody = "before <u>underlined</u> after"

    /// Open tag (3-char run): forward motion into its interior snaps far.
    func test_underline_openTag_forwardIntoInterior_snapsToFarEdge() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 8, length: 0))    // interior of "<u>", forward from 0
        XCTAssertEqual(
            tv.selectedRange().location, 10,
            "Caret cannot rest inside the hidden open tag — forward motion snaps to just after it (10)"
        )
    }

    /// Open tag: backward motion into its interior snaps near.
    func test_underline_openTag_backwardIntoInterior_snapsToNearEdge() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 15, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 8, length: 0))    // interior of "<u>", backward from 15
        XCTAssertEqual(
            tv.selectedRange().location, 7,
            "Backward motion into the hidden open tag snaps to just before it (7)"
        )
    }

    /// Open tag: leading edge (before "<u>") stays inhabitable.
    func test_underline_openTag_leadingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 7, "Just before the open tag must stay inhabitable")
    }

    /// Open tag: trailing edge (content start, right after "<u>") stays inhabitable.
    func test_underline_openTag_trailingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 10, "Just after the open tag must stay inhabitable")
    }

    /// Close tag (4-char run): forward motion into its interior snaps far.
    /// Covering the 4-char tag separately from the 3-char open tag confirms
    /// the fix isn't hardcoded to a 2-char run length.
    func test_underline_closeTag_forwardIntoInterior_snapsToFarEdge() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 10, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 22, length: 0))   // interior of "</u>", forward from 10
        XCTAssertEqual(
            tv.selectedRange().location, 24,
            "Caret cannot rest inside the hidden close tag — forward motion snaps to just after it (24)"
        )
    }

    /// Close tag: backward motion into its interior snaps near.
    func test_underline_closeTag_backwardIntoInterior_snapsToNearEdge() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 26, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 22, length: 0))   // interior of "</u>", backward from 26
        XCTAssertEqual(
            tv.selectedRange().location, 20,
            "Backward motion into the hidden close tag snaps to just before it (20)"
        )
    }

    /// Close tag: leading edge (content end, right before "</u>") stays inhabitable.
    func test_underline_closeTag_leadingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 20, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 20, "Just before the close tag must stay inhabitable")
    }

    /// Close tag: trailing edge (right after "</u>") stays inhabitable.
    func test_underline_closeTag_trailingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: underlineBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 24, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 24, "Just after the close tag must stay inhabitable")
    }

    // MARK: - Italic (`*`) — 1-char run, structurally immune, regression only

    // "before *em* after"
    // offsets: "before " = 0…6, open "*" = 7, content "em" = 8…9,
    // close "*" = 10, " after" = 11…16.
    private let italicBody = "before *em* after"

    /// Forward motion landing exactly on the open marker's own position
    /// (its only possible resting edge — a 1-char run has no interior) is
    /// left alone: no snap needed, no snap fires.
    func test_italic_forwardOntoMarker_noSnap() {
        let runner = HostedEditorRunner(initialBody: italicBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 7, length: 0))    // open "*", forward from 0
        XCTAssertEqual(tv.selectedRange().location, 7, "A 1-char marker run has no interior — the caret already lands correctly")
    }

    /// Backward motion landing exactly on the close marker's own position is
    /// left alone.
    func test_italic_backwardOntoMarker_noSnap() {
        let runner = HostedEditorRunner(initialBody: italicBody, initialSelection: NSRange(location: 13, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 10, length: 0))   // close "*", backward from 13
        XCTAssertEqual(tv.selectedRange().location, 10, "A 1-char marker run has no interior — the caret already lands correctly")
    }

    // MARK: - Inline code (`` ` ``) — 1-char run, structurally immune, regression only

    // "before `code` after"
    // offsets: "before " = 0…6, open "`" = 7, content "code" = 8…11,
    // close "`" = 12, " after" = 13…18.
    private let codeBody = "before `code` after"

    func test_inlineCode_forwardOntoMarker_noSnap() {
        let runner = HostedEditorRunner(initialBody: codeBody, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 7, length: 0))    // open "`", forward from 0
        XCTAssertEqual(tv.selectedRange().location, 7, "A 1-char marker run has no interior — the caret already lands correctly")
    }

    func test_inlineCode_backwardOntoMarker_noSnap() {
        let runner = HostedEditorRunner(initialBody: codeBody, initialSelection: NSRange(location: 15, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 12, length: 0))   // close "`", backward from 15
        XCTAssertEqual(tv.selectedRange().location, 12, "A 1-char marker run has no interior — the caret already lands correctly")
    }
}
