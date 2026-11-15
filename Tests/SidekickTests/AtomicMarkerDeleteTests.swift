import XCTest
@testable import Sidekick

// MARK: - Pure-function tests (no AppKit, no @MainActor)

/// Tests for `FormattingToolbarView.atomicMarkerDeleteRange(body:caret:direction:)`.
/// These are pure-function tests with no AppKit dependencies — they run without
/// a window or main actor and are fast to execute.
final class AtomicMarkerDeleteRangeTests: XCTestCase {

    private typealias Dir = FormattingToolbarView.AtomicMarkerDeleteDirection
    private typealias Result = FormattingToolbarView.AtomicMarkerDeleteResult

    private func find(_ body: String, caret: Int, _ dir: Dir) -> Result? {
        FormattingToolbarView.atomicMarkerDeleteRange(body: body, caret: caret, direction: dir)
    }

    // MARK: - Group P-Bold

    func test_pure_bold_caretAtCloseEdge_returnsPairRange() {
        // "**foo**", caret = 7 (right after last `*`), direction = .backward
        let r = find("**foo**", caret: 7, .backward)
        XCTAssertNotNil(r, "Should find bold pair when caret is at close edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7), "deleteRange must cover the full bold span")
        XCTAssertEqual(r?.replacement, "foo", "replacement must be the inner content")
        XCTAssertEqual(r?.postCaret, 3, "caret after edit must be at end of 'foo'")
    }

    func test_pure_bold_caretAtOpenEdge_returnsPairRange() {
        // "**foo**", caret = 0, direction = .forward
        let r = find("**foo**", caret: 0, .forward)
        XCTAssertNotNil(r, "Should find bold pair when caret is at open edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_bold_caretInsideOpenRun_returnsPairRange() {
        // "**foo**", caret = 1 (between the two open `*`), direction = .backward
        let r = find("**foo**", caret: 1, .backward)
        XCTAssertNotNil(r, "Caret inside the open marker run must fire atomic delete (D-02)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_bold_caretInMiddleOfContent_returnsNil() {
        // "**foo**", caret = 4 (between `f` and first `o`), direction = .backward
        let r = find("**foo**", caret: 4, .backward)
        XCTAssertNil(r, "Caret in the middle of content must NOT fire atomic delete")
    }

    // MARK: - Group P-Italic

    func test_pure_italic_asterisk_caretAtCloseEdge_returnsPairRange() {
        // "*foo*", caret = 5, direction = .backward
        let r = find("*foo*", caret: 5, .backward)
        XCTAssertNotNil(r, "Should find italic pair when caret is at close edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_italic_underscore_caretAtCloseEdge_returnsPairRange() {
        // "_foo_", caret = 5, direction = .backward
        let r = find("_foo_", caret: 5, .backward)
        XCTAssertNotNil(r, "Should find underscore-italic pair when caret is at close edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_italic_caretAtOpenEdge_returnsPairRange() {
        // "*foo*", caret = 0, direction = .forward
        let r = find("*foo*", caret: 0, .forward)
        XCTAssertNotNil(r, "Should find italic pair when caret is at open edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    // MARK: - Group P-InlineCode

    func test_pure_code_caretAtCloseEdge_returnsPairRange() {
        // "`foo`", caret = 5, direction = .backward
        let r = find("`foo`", caret: 5, .backward)
        XCTAssertNotNil(r, "Should find inline-code pair when caret is at close edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_code_caretAtOpenEdge_returnsPairRange() {
        // "`foo`", caret = 0, direction = .forward
        let r = find("`foo`", caret: 0, .forward)
        XCTAssertNotNil(r, "Should find inline-code pair when caret is at open edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    // MARK: - Group P-Strikethrough

    func test_pure_strike_caretAtCloseEdge_returnsPairRange() {
        // "~~foo~~", caret = 7, direction = .backward
        let r = find("~~foo~~", caret: 7, .backward)
        XCTAssertNotNil(r, "Should find strikethrough pair when caret is at close edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_strike_caretAtOpenEdge_returnsPairRange() {
        // "~~foo~~", caret = 0, direction = .forward
        let r = find("~~foo~~", caret: 0, .forward)
        XCTAssertNotNil(r, "Should find strikethrough pair when caret is at open edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    // MARK: - Group P-Underline

    func test_pure_underline_caretAtCloseEdge_returnsPairRange() {
        // "<u>foo</u>", caret = 10, direction = .backward
        let body = "<u>foo</u>"
        XCTAssertEqual((body as NSString).length, 10, "Sanity: body must be 10 UTF-16 units")
        let r = find(body, caret: 10, .backward)
        XCTAssertNotNil(r, "Should find underline pair when caret is at close edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 10))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_underline_caretAtOpenEdge_returnsPairRange() {
        // "<u>foo</u>", caret = 0, direction = .forward
        let body = "<u>foo</u>"
        let r = find(body, caret: 0, .forward)
        XCTAssertNotNil(r, "Should find underline pair when caret is at open edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 10))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_underline_caretInsideCloseRun_returnsPairRange() {
        // "<u>foo</u>", caret = 8 (between `/` and `u` in `</u>`)
        // This is the EXACT bug scenario — the user reported that backspace at
        // this position ate one byte at a time, exposing `</u` / `</` literals.
        let body = "<u>foo</u>"
        // body:  < u > f o o < / u >
        // index: 0 1 2 3 4 5 6 7 8 9  (UTF-16)
        // caret 8 sits between `/` (index 7) and `u` (index 8)
        let r = find(body, caret: 8, .backward)
        XCTAssertNotNil(r, "Caret inside the close marker run must fire atomic delete (D-02, primary bug case)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 10))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    // MARK: - Group P-Link

    func test_pure_link_caretAtCloseEdge_returnsWrapperRange_keepingLabel() {
        // "[label](http://x.io)", caret = 20, direction = .backward
        let body = "[label](http://x.io)"
        XCTAssertEqual((body as NSString).length, 20, "Sanity: body must be 20 UTF-16 units")
        let r = find(body, caret: 20, .backward)
        XCTAssertNotNil(r, "Should find link wrapper when caret is at close edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 20))
        XCTAssertEqual(r?.replacement, "label", "D-03: label is preserved, URL is dropped")
        XCTAssertEqual(r?.postCaret, 5)
    }

    func test_pure_link_caretAtOpenEdge_returnsWrapperRange_keepingLabel() {
        // "[label](http://x.io)", caret = 0, direction = .forward
        let body = "[label](http://x.io)"
        let r = find(body, caret: 0, .forward)
        XCTAssertNotNil(r, "Should find link wrapper when caret is at open edge")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 20))
        XCTAssertEqual(r?.replacement, "label")
        XCTAssertEqual(r?.postCaret, 5)
    }

    func test_pure_link_caretInsideURL_returnsWrapperRange_keepingLabel() {
        // "[label](http://x.io)", caret = 15 (inside the URL chars), direction = .backward
        // body:  [ l a b e l ] ( h  t  t  p  :  /  /  x  .  i  o  )
        // index: 0 1 2 3 4 5 6 7 8  9  10 11 12 13 14 15 16 17 18 19
        let body = "[label](http://x.io)"
        let r = find(body, caret: 15, .backward)
        XCTAssertNotNil(r, "Caret inside URL chars must fire atomic delete (urlRange is treated as marker)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 20))
        XCTAssertEqual(r?.replacement, "label")
        XCTAssertEqual(r?.postCaret, 5)
    }

    // MARK: - Group P-Adjacency / Guards

    func test_pure_plainText_returnsNil() {
        let r = find("hello world", caret: 5, .backward)
        XCTAssertNil(r, "Plain text must not trigger atomic delete")
    }

    func test_pure_insideFencedBlock_returnsNil() {
        // "```\n**foo**\n```" — the bold pair is literal text inside the fence.
        // D-07: caret anywhere inside the content range → nil.
        let body = "```\n**foo**\n```"
        // content range starts at offset 4 (after "```\n")
        // place caret at offset 6 (inside "**foo**")
        let r = find(body, caret: 6, .backward)
        XCTAssertNil(r, "Caret inside a fenced code block must return nil (D-07)")
    }

    func test_pure_caretAtFarEdge_outsideAnyPair_returnsNil() {
        // "a **foo** b", caret = 1 (between `a` and ` `), direction = .backward
        // The bold pair is at offsets 2–8; caret 1 is not adjacent to any marker.
        let r = find("a **foo** b", caret: 1, .backward)
        XCTAssertNil(r, "Caret far from any marker run must return nil")
    }

    func test_pure_emptyBody_returnsNil() {
        let r = find("", caret: 0, .backward)
        XCTAssertNil(r, "Empty body must return nil (bounds guard)")
    }

    // MARK: - Group P-OpenCloseReachability (D-08 widened adjacency)
    //
    // Before D-08, `isAdjacent` used direction-dependent half-open ranges, so
    // only ONE of the two visually-identical caret positions at each marker
    // edge fired the atomic delete: Backspace worked at the close edge but
    // not the open edge; forward-Delete worked at the open edge but not the
    // close edge. These tests cover the previously-nil combination for each
    // of the 6 pass types: Backspace at the open edge, and forward-Delete at
    // the close edge.

    func test_pure_bold_caretAtOpenEdge_backspace_returnsPairRange() {
        // "**foo**", caret = 0, direction = .backward — previously nil.
        let r = find("**foo**", caret: 0, .backward)
        XCTAssertNotNil(r, "Backspace at the open edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_bold_caretAtCloseEdge_forwardDelete_returnsPairRange() {
        // "**foo**", caret = 7, direction = .forward — previously nil.
        let r = find("**foo**", caret: 7, .forward)
        XCTAssertNotNil(r, "forward-Delete at the close edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_italic_caretAtOpenEdge_backspace_returnsPairRange() {
        // "*foo*", caret = 0, direction = .backward — previously nil.
        let r = find("*foo*", caret: 0, .backward)
        XCTAssertNotNil(r, "Backspace at the open edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_italic_caretAtCloseEdge_forwardDelete_returnsPairRange() {
        // "*foo*", caret = 5, direction = .forward — previously nil.
        let r = find("*foo*", caret: 5, .forward)
        XCTAssertNotNil(r, "forward-Delete at the close edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_code_caretAtOpenEdge_backspace_returnsPairRange() {
        // "`foo`", caret = 0, direction = .backward — previously nil.
        let r = find("`foo`", caret: 0, .backward)
        XCTAssertNotNil(r, "Backspace at the open edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_code_caretAtCloseEdge_forwardDelete_returnsPairRange() {
        // "`foo`", caret = 5, direction = .forward — previously nil.
        let r = find("`foo`", caret: 5, .forward)
        XCTAssertNotNil(r, "forward-Delete at the close edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_strike_caretAtOpenEdge_backspace_returnsPairRange() {
        // "~~foo~~", caret = 0, direction = .backward — previously nil.
        let r = find("~~foo~~", caret: 0, .backward)
        XCTAssertNotNil(r, "Backspace at the open edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_strike_caretAtCloseEdge_forwardDelete_returnsPairRange() {
        // "~~foo~~", caret = 7, direction = .forward — previously nil.
        let r = find("~~foo~~", caret: 7, .forward)
        XCTAssertNotNil(r, "forward-Delete at the close edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_underline_caretAtOpenEdge_backspace_returnsPairRange() {
        // "<u>foo</u>", caret = 0, direction = .backward — previously nil.
        let body = "<u>foo</u>"
        let r = find(body, caret: 0, .backward)
        XCTAssertNotNil(r, "Backspace at the open edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 10))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_underline_caretAtCloseEdge_forwardDelete_returnsPairRange() {
        // "<u>foo</u>", caret = 10, direction = .forward — previously nil.
        let body = "<u>foo</u>"
        let r = find(body, caret: 10, .forward)
        XCTAssertNotNil(r, "forward-Delete at the close edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 10))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_link_caretAtOpenEdge_backspace_returnsWrapperRange_keepingLabel() {
        // "[label](http://x.io)", caret = 0, direction = .backward — previously nil.
        let body = "[label](http://x.io)"
        let r = find(body, caret: 0, .backward)
        XCTAssertNotNil(r, "Backspace at the open edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 20))
        XCTAssertEqual(r?.replacement, "label")
        XCTAssertEqual(r?.postCaret, 5)
    }

    func test_pure_link_caretAtCloseEdge_forwardDelete_returnsWrapperRange_keepingLabel() {
        // "[label](http://x.io)", caret = 20, direction = .forward — previously nil.
        let body = "[label](http://x.io)"
        let r = find(body, caret: 20, .forward)
        XCTAssertNotNil(r, "forward-Delete at the close edge must now fire the atomic delete (D-08)")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 20))
        XCTAssertEqual(r?.replacement, "label")
        XCTAssertEqual(r?.postCaret, 5)
    }

    // MARK: - Group P-TieBreak (D-09 direction-based resolution)
    //
    // Widening adjacency (D-08) means the shared zero-width offset between two
    // back-to-back marker pairs now matches both pairs at once. These tests
    // confirm the tie-break resolves by direction, not by pass/iteration order.

    func test_pure_tieBreak_boldBackToBack_backspaceAtSharedBoundary_removesLeftPairOnly() {
        // "**a****b**" — two back-to-back bold pairs sharing the boundary at offset 5.
        // index: 0 1 2 3 4 5 6 7 8 9  ->  * * a * * * * b * *
        // Left pair "**a**" spans [0,5); right pair "**b**" spans [5,10).
        let body = "**a****b**"
        XCTAssertEqual((body as NSString).length, 10, "Sanity: body must be 10 UTF-16 units")
        let r = find(body, caret: 5, .backward)
        XCTAssertNotNil(r, "Backspace at the shared boundary must match a pair")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5), "Backspace must remove the LEFT pair only")
        XCTAssertEqual(r?.replacement, "a")
        XCTAssertEqual(r?.postCaret, 1)
    }

    func test_pure_tieBreak_boldBackToBack_forwardDeleteAtSharedBoundary_removesRightPairOnly() {
        // Same body as above; forward-Delete at the same offset must resolve
        // to the RIGHT pair instead — proving the tie-break is direction-based,
        // not a fixed first-match / last-match rule.
        let body = "**a****b**"
        let r = find(body, caret: 5, .forward)
        XCTAssertNotNil(r, "forward-Delete at the shared boundary must match a pair")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 5, length: 5), "forward-Delete must remove the RIGHT pair only")
        XCTAssertEqual(r?.replacement, "b")
        XCTAssertEqual(r?.postCaret, 6)
    }

    func test_pure_tieBreak_boldThenStrikeBackToBack_backspaceAtSharedBoundary_removesLeftBoldOnly() {
        // "**a**~~b~~" — bold pair immediately followed by a strikethrough pair.
        // index: 0 1 2 3 4 5 6 7 8 9  ->  * * a * * ~ ~ b ~ ~
        // Bold pass runs before strikethrough pass, so this proves the D-09
        // direction resolution wins over pass order (bold candidate is added
        // to the list first, but must NOT win here for forward-Delete).
        let body = "**a**~~b~~"
        XCTAssertEqual((body as NSString).length, 10, "Sanity: body must be 10 UTF-16 units")
        let r = find(body, caret: 5, .backward)
        XCTAssertNotNil(r, "Backspace at the shared boundary must match a pair")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 5), "Backspace must remove the LEFT (bold) pair only")
        XCTAssertEqual(r?.replacement, "a")
        XCTAssertEqual(r?.postCaret, 1)
    }

    func test_pure_tieBreak_boldThenStrikeBackToBack_forwardDeleteAtSharedBoundary_removesRightStrikeOnly() {
        // Same cross-type body; forward-Delete must resolve to the RIGHT
        // (strikethrough) pair, confirming pass order (bold before strike)
        // never silently overrides the direction-based tie-break.
        let body = "**a**~~b~~"
        let r = find(body, caret: 5, .forward)
        XCTAssertNotNil(r, "forward-Delete at the shared boundary must match a pair")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 5, length: 5), "forward-Delete must remove the RIGHT (strike) pair only")
        XCTAssertEqual(r?.replacement, "b")
        XCTAssertEqual(r?.postCaret, 6)
    }

    // MARK: - Group P-DocumentEdgeMirror
    //
    // At a document edge there is only one candidate pair — no tie-break is
    // invoked, and the single-candidate path (unchanged from today) applies.

    func test_pure_documentEdge_backspaceAtCaretZero_firstCharsAreMarkerOpen_matchesOnlyThatMarker() {
        // "**foo**" — the document's first characters ARE a marker's open
        // sequence. Backspace at caret 0 must match only that first marker;
        // there is nothing to its left to create ambiguity.
        let r = find("**foo**", caret: 0, .backward)
        XCTAssertNotNil(r, "Backspace at document-start marker open sequence must fire")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }

    func test_pure_documentEdge_forwardDeleteAtBodyLength_lastCharsAreMarkerClose_matchesOnlyThatMarker() {
        // "**foo**" — the document's last characters ARE a marker's close
        // sequence. forward-Delete at caret == body.length must match only
        // that final marker; there is nothing to its right to create ambiguity.
        let body = "**foo**"
        let bodyLength = (body as NSString).length
        XCTAssertEqual(bodyLength, 7, "Sanity: body must be 7 UTF-16 units")
        let r = find(body, caret: bodyLength, .forward)
        XCTAssertNotNil(r, "forward-Delete at document-end marker close sequence must fire")
        XCTAssertEqual(r?.deleteRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(r?.replacement, "foo")
        XCTAssertEqual(r?.postCaret, 3)
    }
}

// MARK: - Live-textview tests (@MainActor)

/// HybridTextView subclass that injects a local UndoManager. Windowless
/// NSTextViews have no responder chain so `undoManager` is nil by default.
/// This is a per-file re-declaration; Swift private scoping keeps it from
/// conflicting with the identical class in ArmedInlineFormatTests.swift.
private final class TestableHybridTextView: HybridTextView {
    private let _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }
}

@MainActor
final class AtomicMarkerDeleteHelperTests: XCTestCase {

    private func makeTV(_ body: String, selection: NSRange) -> TestableHybridTextView {
        let tv = TestableHybridTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.string = body
        tv.setSelectedRange(selection)
        return tv
    }

    // MARK: - Group L-Backspace: 6 marker pairs × Backspace at closing edge

    func test_live_backspace_bold_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("**foo**", selection: NSRange(location: 7, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for bold close edge")
        XCTAssertEqual(tv.string, "foo", "Bold pair must be deleted; inner content preserved")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0), "Caret must be at end of 'foo'")
    }

    func test_live_backspace_italic_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("*foo*", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for italic close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_code_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("`foo`", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for inline-code close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_strike_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("~~foo~~", selection: NSRange(location: 7, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for strikethrough close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_underline_atCloseEdge_swallowsPairKeepsContent() {
        // PRIMARY bug-fix assertion: <u>foo</u> + Backspace at caret 10 → "foo", caret {3,0}
        let tv = makeTV("<u>foo</u>", selection: NSRange(location: 10, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for underline close edge — this is the primary bug fix")
        XCTAssertEqual(tv.string, "foo", "Underline pair must be deleted; inner content preserved (primary bug case)")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_link_atCloseEdge_swallowsWrapperKeepsLabel() {
        let tv = makeTV("[label](http://x.io)", selection: NSRange(location: 20, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for link close edge")
        XCTAssertEqual(tv.string, "label", "Link wrapper must be deleted; label preserved (D-03)")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0))
    }

    // MARK: - Group L-Forward: 6 marker pairs × forward-delete at opening edge

    func test_live_forwardDelete_bold_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("**foo**", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for bold open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_italic_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("*foo*", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for italic open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_code_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("`foo`", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for inline-code open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_strike_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("~~foo~~", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for strikethrough open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_underline_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("<u>foo</u>", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for underline open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_link_atOpenEdge_swallowsWrapperKeepsLabel() {
        let tv = makeTV("[label](http://x.io)", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for link open edge")
        XCTAssertEqual(tv.string, "label")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0))
    }

    // MARK: - Group L-Inside: caret in middle of marker run

    func test_live_backspace_underline_caretInsideCloseRun_stillSwallowsPair() {
        // Caret at offset 8 — between `/` (index 7) and `u` (index 8) in `</u>`.
        // This exercises D-02 on the live path.
        let tv = makeTV("<u>foo</u>", selection: NSRange(location: 8, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "Caret inside close-marker run must fire atomic delete (D-02)")
        XCTAssertEqual(tv.string, "foo", "Full pair must be deleted even when caret is mid-marker")
    }

    // MARK: - Group L-Undo

    func test_live_backspace_underline_singleUndoStepRestoresPair() {
        let tv = makeTV("<u>foo</u>", selection: NSRange(location: 10, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled)
        XCTAssertEqual(tv.string, "foo", "After backspace the pair must be gone")
        XCTAssertTrue(tv.undoManager?.canUndo == true, "Undo stack must have one entry")

        tv.undoManager?.undo()

        // Primary undo assertion: full pair is restored as a single undo step.
        XCTAssertEqual(tv.string, "<u>foo</u>", "Undo must restore the full pair + content in one step")
        XCTAssertTrue(tv.undoManager?.canRedo == true, "Redo must be available after undo")
        // Note: AppKit default undo may restore the selection to a different location
        // than {10,0} depending on how NSTextView coalesces undo registration.
        // The critical invariant is the string content, not the exact caret.
    }

    // MARK: - Group L-NoOp

    func test_live_backspace_plainText_returnsFalse() {
        let tv = makeTV("hello", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertFalse(handled, "Plain text must not be intercepted — returns false")
        XCTAssertEqual(tv.string, "hello", "Body must be unchanged")
    }

    func test_live_backspace_nonEmptySelection_returnsFalse() {
        // Non-empty selection: "**foo**", selection covers "foo" (offset 2, length 3).
        // The existing PerformWrap-style selection behavior must remain untouched (D-06).
        let tv = makeTV("**foo**", selection: NSRange(location: 2, length: 3))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertFalse(handled, "Non-empty selection must NOT be intercepted by atomic delete (D-06)")
        XCTAssertEqual(tv.string, "**foo**", "Body must be unchanged — selection path is handled elsewhere")
    }

    // MARK: - Group L-FallThrough: regression guard for checklist/bullet/bare-URL paths

    func test_live_backspace_atChecklistPrefixBoundary_atomicReturnsFalse() {
        // Caret right after `- [ ] ` prefix (offset 6). No inline-format pair is adjacent.
        // handleAtomicMarkerBackspace must return false so handleChecklistBackspace still runs.
        let tv = makeTV("- [ ] foo", selection: NSRange(location: 6, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertFalse(handled, "Atomic helper must return false at checklist prefix boundary (not an inline-format pair)")
    }

    func test_live_backspace_betweenBulletPrefixAndContent_atomicReturnsFalse() {
        // "- foo", caret at offset 2 (right after `- `). No inline-format pair adjacent.
        let tv = makeTV("- foo", selection: NSRange(location: 2, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertFalse(handled, "Atomic helper must return false adjacent to bullet prefix")
        XCTAssertEqual(tv.string, "- foo", "Body must be unchanged")
    }

    func test_live_backspace_atBareURLChip_atomicReturnsFalse() {
        // "see https://example.com here", caret right after "here" (last char).
        // Bare URLs are NOT consulted by findLinkRanges — they fall through to
        // native NSTextView single-char delete (per D-05 and the plan's scope exclusion).
        let body = "see https://example.com here"
        let tv = makeTV(body, selection: NSRange(location: (body as NSString).length, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertFalse(handled, "Atomic helper must return false adjacent to bare-URL text (not a markdown link pair)")
        XCTAssertEqual(tv.string, body, "Body must be unchanged")
    }

    // MARK: - Group L-OpenCloseReachability (D-08 widened adjacency)
    //
    // Live-handler mirrors of the P-OpenCloseReachability pure tests: the
    // previously-nil combination for each of the 6 pass types — Backspace at
    // the open edge, and forward-Delete at the close edge — now routed through
    // handleAtomicMarkerBackspace / handleAtomicMarkerForwardDelete.

    func test_live_backspace_bold_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("**foo**", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for bold open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_bold_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("**foo**", selection: NSRange(location: 7, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for bold close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_italic_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("*foo*", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for italic open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_italic_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("*foo*", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for italic close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_code_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("`foo`", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for inline-code open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_code_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("`foo`", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for inline-code close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_strike_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("~~foo~~", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for strikethrough open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_strike_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("~~foo~~", selection: NSRange(location: 7, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for strikethrough close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_underline_atOpenEdge_swallowsPairKeepsContent() {
        let tv = makeTV("<u>foo</u>", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for underline open edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_underline_atCloseEdge_swallowsPairKeepsContent() {
        let tv = makeTV("<u>foo</u>", selection: NSRange(location: 10, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for underline close edge")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_backspace_link_atOpenEdge_swallowsWrapperKeepsLabel() {
        let tv = makeTV("[label](http://x.io)", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true for link open edge")
        XCTAssertEqual(tv.string, "label")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0))
    }

    func test_live_forwardDelete_link_atCloseEdge_swallowsWrapperKeepsLabel() {
        let tv = makeTV("[label](http://x.io)", selection: NSRange(location: 20, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true for link close edge")
        XCTAssertEqual(tv.string, "label")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0))
    }

    // MARK: - Group L-TieBreak (D-09 direction-based resolution)
    //
    // Live-handler mirrors of the P-TieBreak pure tests: same-type and
    // cross-type back-to-back marker pairs sharing a caret offset, resolved
    // by direction via handleAtomicMarkerBackspace / handleAtomicMarkerForwardDelete.

    func test_live_backspace_tieBreak_boldBackToBack_atSharedBoundary_removesLeftPairOnly() {
        // "**a****b**", caret 5 — Backspace must remove the LEFT bold pair only.
        let tv = makeTV("**a****b**", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true at the shared boundary")
        XCTAssertEqual(tv.string, "a**b**", "Only the LEFT pair must be removed; the right pair's marker + content survive")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 0))
    }

    func test_live_forwardDelete_tieBreak_boldBackToBack_atSharedBoundary_removesRightPairOnly() {
        // Same body; forward-Delete at the same offset must remove the RIGHT pair only.
        let tv = makeTV("**a****b**", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true at the shared boundary")
        XCTAssertEqual(tv.string, "**a**b", "Only the RIGHT pair must be removed; the left pair's marker + content survive")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 0))
    }

    func test_live_backspace_tieBreak_boldThenStrikeBackToBack_atSharedBoundary_removesLeftBoldOnly() {
        // "**a**~~b~~", caret 5 — bold pass runs before strikethrough pass, so
        // this proves the direction-based tie-break wins over pass order.
        let tv = makeTV("**a**~~b~~", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true at the shared boundary")
        XCTAssertEqual(tv.string, "a~~b~~", "Only the LEFT (bold) pair must be removed")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 0))
    }

    func test_live_forwardDelete_tieBreak_boldThenStrikeBackToBack_atSharedBoundary_removesRightStrikeOnly() {
        // Same cross-type body; forward-Delete must resolve to the RIGHT
        // (strikethrough) pair, confirming pass order never silently wins.
        let tv = makeTV("**a**~~b~~", selection: NSRange(location: 5, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true at the shared boundary")
        XCTAssertEqual(tv.string, "**a**b", "Only the RIGHT (strike) pair must be removed")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 0))
    }

    // MARK: - Group L-DocumentEdgeMirror
    //
    // Live-handler mirrors of the P-DocumentEdgeMirror pure tests: at a
    // document edge there is only one candidate pair, so no tie-break is
    // invoked — the single-candidate path applies, reachable from either
    // handler.

    func test_live_backspace_documentEdge_atCaretZero_matchesOnlyThatMarker() {
        // "**foo**" — the document's first characters ARE a marker's open
        // sequence. Backspace at caret 0 must match only that first marker.
        let tv = makeTV("**foo**", selection: NSRange(location: 0, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerBackspace(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerBackspace must return true at document-start marker open sequence")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_live_forwardDelete_documentEdge_atBodyLength_matchesOnlyThatMarker() {
        // "**foo**" — the document's last characters ARE a marker's close
        // sequence. forward-Delete at caret == body.length must match only
        // that final marker.
        let body = "**foo**"
        let bodyLength = (body as NSString).length
        let tv = makeTV(body, selection: NSRange(location: bodyLength, length: 0))
        let handled = FormattingToolbarView.handleAtomicMarkerForwardDelete(in: tv)
        XCTAssertTrue(handled, "handleAtomicMarkerForwardDelete must return true at document-end marker close sequence")
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0))
    }
}
