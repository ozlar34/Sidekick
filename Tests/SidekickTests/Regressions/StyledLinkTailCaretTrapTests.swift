import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/ (review finding [10]):
// A styled markdown link `[label](url)` hides its `](url)` tail behind
// `.sidekickHiddenMarker` same as a bare URL / `[url](url)` chip — but it
// carries NO `.sidekickLinkChip` anchor (that key is reserved for the
// label-is-the-URL case, which renders a pill). `snapCaretOutOfLinkChip`
// therefore declined to rescue it, so the caret silently stepped through
// every hidden character of the tail one arrow-key press / click at a time —
// for a long URL, dozens of keypresses with no visible movement.
//
// Fix: a new NON-RENDERING attribute, `.sidekickLinkTailAnchor`, tags the
// tail's own span (closing bracket through closing paren). It is read only
// by `snapCaretOutOfLinkTail` in HybridEditorView — `MarkdownLayoutManager`
// never looks at it — so no pill is drawn over the styled label. The tail
// becomes atomic: a caret landing inside snaps to either edge in one hop.
@MainActor
final class StyledLinkTailCaretTrapTests: XCTestCase {

    // "see [Google](https://example.com) end"
    // offsets: "see " = 0…3, "[" = 4, "Google" = 5…10, "]" = 11, "(" = 12,
    // url = 13…31 (19 chars), ")" = 32, " end" = 33…36.
    // Tail span (`](https://example.com)`) = location 11, length 22 → [11, 33).
    private let body = "see [Google](https://example.com) end"

    // MARK: - Preconditions

    func test_tail_carriesLinkTailAnchor_notLinkChip() {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        let storage = runner.inner.storage

        var anchorRange = NSRange(location: NSNotFound, length: 0)
        let anchor = storage.attribute(.sidekickLinkTailAnchor, at: 15,
                                        longestEffectiveRange: &anchorRange,
                                        in: NSRange(location: 0, length: storage.length))
        XCTAssertNotNil(anchor, "The hidden tail must carry the non-rendering .sidekickLinkTailAnchor")
        XCTAssertEqual(anchorRange, NSRange(location: 11, length: 22),
                       "The anchor's own span is exactly the tail — never merged with an adjacent run")

        XCTAssertNil(storage.attribute(.sidekickLinkChip, at: 11, effectiveRange: nil),
                     "A styled label's tail must NOT carry .sidekickLinkChip — that would render a pill")
    }

    func test_label_remainsPlainVisibleText() {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        let storage = runner.inner.storage
        XCTAssertNil(storage.attribute(.sidekickHiddenMarker, at: 7, effectiveRange: nil),
                     "The visible label text itself must stay unhidden")
    }

    // MARK: - Caret rescue

    /// Forward motion into the hidden tail interior snaps to just after it.
    /// Pre-fix: the caret rested inside (invisible), offset unchanged.
    func test_forwardIntoTail_snapsToRunEnd() {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 20, length: 0))   // mid-URL, forward from 0
        XCTAssertEqual(
            tv.selectedRange().location, 33,
            "Caret cannot rest inside the hidden tail — forward motion snaps to just after it (33)"
        )
    }

    /// Backward motion into the hidden tail interior snaps to just before it.
    func test_backwardIntoTail_snapsToRunStart() {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 34, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 25, length: 0))   // mid-URL, backward from 34
        XCTAssertEqual(
            tv.selectedRange().location, 11,
            "Backward motion into the hidden tail snaps to just before it (11)"
        )
    }

    /// The leading edge (right after the visible label, before the tail) is a
    /// valid resting spot — never snapped.
    func test_leadingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 11,
                       "Just after the label / before the tail must stay inhabitable")
    }

    /// The trailing edge (right after the closing paren) is a valid resting spot.
    func test_trailingEdge_notSnapped() {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        let tv = runner.inner.textView
        tv.setSelectedRange(NSRange(location: 33, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 33,
                       "Just after the tail must stay inhabitable")
    }

    // MARK: - Mutual exclusivity with the link-chip (label-is-URL) case

    /// A bare-URL chip (`label == url`) must not pick up the new tail anchor —
    /// the two mechanisms are mutually exclusive by construction.
    func test_chipLink_doesNotCarryTailAnchor() {
        let chipBody = "see [https://example.com](https://example.com) end"
        let runner = HostedEditorRunner(initialBody: chipBody, initialSelection: NSRange(location: 0, length: 0))
        let storage = runner.inner.storage
        let n = storage.length
        storage.enumerateAttribute(.sidekickLinkTailAnchor, in: NSRange(location: 0, length: n), options: []) { value, _, _ in
            XCTAssertNil(value, "A label-is-URL chip link must never carry .sidekickLinkTailAnchor")
        }
    }
}
