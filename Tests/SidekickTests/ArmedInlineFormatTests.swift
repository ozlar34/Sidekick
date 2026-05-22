import XCTest
@testable import Sidekick

/// Pins the pure-function contract for "hide inline markers on empty
/// selection; wrap-on-next-keystroke". Two helpers:
///   1. `armedInlineKindsAfterArm(current:requestedKind:)` — state transition
///      math for arm / toggle-off / mutex-replace / orthogonal-stack.
///   2. `composeArmedWrap(order:)` — builds the (prefix, suffix) strings that
///      wrap a single typed character. Outer-first reading order:
///      `prefix = order.reversed().map(prefixFor).joined()`,
///      `suffix = order.map(suffixFor).joined()`.
///
/// Pattern: FormattingToolbarTests (pure-function, no NSTextView, no @MainActor).
final class ArmedInlineFormatTests: XCTestCase {

    // MARK: - Group A: armedInlineKindsAfterArm

    func test_arm_emptySet_addsKind() {
        let result = FormattingToolbarView.armedInlineKindsAfterArm(
            current: (set: [], order: []),
            requestedKind: .bold
        )
        XCTAssertEqual(result.set, [.bold], "Arming bold into empty set adds bold")
        XCTAssertEqual(result.order, [.bold], "Order list starts with bold")
    }

    func test_arm_sameKindAgain_togglesOff() {
        let result = FormattingToolbarView.armedInlineKindsAfterArm(
            current: (set: [.bold], order: [.bold]),
            requestedKind: .bold
        )
        XCTAssertEqual(result.set, [], "Re-arming bold toggles it off")
        XCTAssertEqual(result.order, [], "Order list becomes empty after toggle off")
    }

    func test_arm_mutexReplace_boldToItalic() {
        let result = FormattingToolbarView.armedInlineKindsAfterArm(
            current: (set: [.bold], order: [.bold]),
            requestedKind: .italic
        )
        XCTAssertEqual(result.set, [.italic], "Arming italic over bold replaces it (mutex)")
        XCTAssertEqual(result.order, [.italic], "Order list contains only italic")
    }

    func test_arm_mutexReplace_italicToCode() {
        let result = FormattingToolbarView.armedInlineKindsAfterArm(
            current: (set: [.italic], order: [.italic]),
            requestedKind: .code
        )
        XCTAssertEqual(result.set, [.code], "Arming code over italic replaces it (mutex)")
        XCTAssertEqual(result.order, [.code], "Order list contains only code")
    }

    func test_arm_orthogonalStack_underlinePlusStrike() {
        let result = FormattingToolbarView.armedInlineKindsAfterArm(
            current: (set: [.underline], order: [.underline]),
            requestedKind: .strikethrough
        )
        XCTAssertEqual(result.set, [.underline, .strikethrough],
                       "Strikethrough stacks orthogonally on underline")
        XCTAssertEqual(result.order, [.underline, .strikethrough],
                       "Order appends strike after underline")
    }

    func test_arm_orthogonalDoesNotEvictMutex() {
        let result = FormattingToolbarView.armedInlineKindsAfterArm(
            current: (set: [.bold, .underline], order: [.bold, .underline]),
            requestedKind: .strikethrough
        )
        XCTAssertEqual(result.set, [.bold, .underline, .strikethrough],
                       "Strikethrough stacks; does not evict bold or underline")
        XCTAssertEqual(result.order, [.bold, .underline, .strikethrough],
                       "Order appends strike at the end")
    }

    func test_arm_mutexReplace_preservesOrthogonalSlot() {
        // bold occupies order index 0, underline index 1. Replacing bold with
        // italic must leave underline at index 1; italic takes bold's slot
        // (index 0).
        let result = FormattingToolbarView.armedInlineKindsAfterArm(
            current: (set: [.bold, .underline], order: [.bold, .underline]),
            requestedKind: .italic
        )
        XCTAssertEqual(result.set, [.italic, .underline],
                       "Italic replaces bold; underline survives")
        XCTAssertEqual(result.order, [.italic, .underline],
                       "Italic takes bold's slot; underline stays at its index")
    }

    // MARK: - Group B: composeArmedWrap

    func test_compose_singleBold_returnsAsteriskPair() {
        let (p, s) = FormattingToolbarView.composeArmedWrap(order: [.bold])
        XCTAssertEqual(p, "**", "Bold-only prefix is **")
        XCTAssertEqual(s, "**", "Bold-only suffix is **")
    }

    func test_compose_underlineThenStrike_outerIsStrike() {
        // order = [.underline, .strikethrough] means underline was armed first
        // (innermost), strikethrough second (outermost). Reading left-to-right,
        // the outer prefix comes first.
        let (p, s) = FormattingToolbarView.composeArmedWrap(order: [.underline, .strikethrough])
        XCTAssertEqual(p, "~~<u>",
                       "Outer ~~ then inner <u> — strike is outermost (last armed)")
        XCTAssertEqual(s, "</u>~~",
                       "Inner </u> then outer ~~ — closes inner first")
    }

    func test_compose_strikeThenUnderline_outerIsUnderline() {
        // Reversed of the prior test: strike armed first, underline second
        // (outermost).
        let (p, s) = FormattingToolbarView.composeArmedWrap(order: [.strikethrough, .underline])
        XCTAssertEqual(p, "<u>~~",
                       "Outer <u> then inner ~~ — underline is outermost")
        XCTAssertEqual(s, "~~</u>",
                       "Inner ~~ then outer </u>")
    }

    func test_compose_threeStack_boldUnderlineStrike() {
        // bold first → innermost, strike last → outermost.
        let (p, s) = FormattingToolbarView.composeArmedWrap(
            order: [.bold, .underline, .strikethrough]
        )
        XCTAssertEqual(p, "~~<u>**",
                       "Outer-to-inner: ~~ then <u> then **")
        XCTAssertEqual(s, "**</u>~~",
                       "Inner-to-outer: ** then </u> then ~~")
    }

    func test_compose_emptyOrder_returnsEmptyStrings() {
        let (p, s) = FormattingToolbarView.composeArmedWrap(order: [])
        XCTAssertEqual(p, "", "Empty order yields empty prefix")
        XCTAssertEqual(s, "", "Empty order yields empty suffix")
    }
}

// MARK: - Integration tests (performWrap arm path + insertText consumption)

import AppKit

/// HybridTextView subclass that injects a local UndoManager. Windowless
/// NSTextViews have no responder chain so `undoManager` is nil by default;
/// this mirrors the `TestableTextView` pattern in PerformWrapTests but keeps
/// the HybridTextView subclass so the overridden `insertText` and
/// `setSelectedRanges` paths exercise the real production code.
private final class TestableHybridTextView: HybridTextView {
    private let _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }
}

@MainActor
final class ArmedInlinePerformWrapTests: XCTestCase {

    private func makeHybridTextView(_ body: String, selection: NSRange)
        -> (tv: TestableHybridTextView, controller: HybridEditorController)
    {
        let tv = TestableHybridTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.string = body
        tv.setSelectedRange(selection)
        let controller = HybridEditorController()
        tv.hybridController = controller
        return (tv, controller)
    }

    // MARK: - Group C: performWrap empty-selection arm path

    func test_emptySelection_bold_armsAndDoesNotMutateBody() {
        let (tv, controller) = makeHybridTextView("hello", selection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "hello",
                       "Body MUST be unchanged on empty-selection arm — no marker spam")
        XCTAssertEqual(tv.armedInlineKinds, [.bold],
                       "Bold is armed on the text view")
        XCTAssertEqual(tv.armedInlineKindsOrder, [.bold],
                       "Order list matches the armed set")
        XCTAssertEqual(controller.armedInlineKinds, [.bold],
                       "Controller publishes the armed kinds for the toolbar")
    }

    func test_emptySelection_secondPress_togglesArmingOff() {
        let (tv, controller) = makeHybridTextView("hello", selection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "hello", "Body still unchanged after toggle-off")
        XCTAssertEqual(tv.armedInlineKinds, [], "Re-press clears arming")
        XCTAssertEqual(tv.armedInlineKindsOrder, [])
        XCTAssertEqual(controller.armedInlineKinds, [])
    }

    func test_emptySelection_boldThenItalic_mutexReplaces() {
        let (tv, _) = makeHybridTextView("hello", selection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        FormattingToolbarView.performWrap(prefix: "*", suffix: "*", in: tv)
        XCTAssertEqual(tv.string, "hello", "No body mutation on either arm")
        XCTAssertEqual(tv.armedInlineKinds, [.italic],
                       "Italic replaces bold (mutex)")
        XCTAssertEqual(tv.armedInlineKindsOrder, [.italic])
    }

    func test_emptySelection_underlineThenStrike_stacks() {
        let (tv, _) = makeHybridTextView("hello", selection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performWrap(prefix: "<u>", suffix: "</u>", in: tv)
        FormattingToolbarView.performWrap(prefix: "~~", suffix: "~~", in: tv)
        XCTAssertEqual(tv.string, "hello")
        XCTAssertEqual(tv.armedInlineKinds, [.underline, .strikethrough],
                       "Underline + strikethrough stack orthogonally")
        XCTAssertEqual(tv.armedInlineKindsOrder, [.underline, .strikethrough])
    }

    func test_emptySelection_armingPushesNoUndo() {
        let (tv, _) = makeHybridTextView("hello", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(tv.undoManager?.canUndo, false,
                       "Sanity: no undo state before arming")
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.undoManager?.canUndo, false,
                       "Arming MUST NOT push undo state — it's an in-memory flag flip")
    }

    func test_emptySelection_armInsideFencedBlock_isNoOp() {
        // F-05 parity: arming inside ```…``` content is silent. The fenced
        // block is at lines 1–3 of the body; "foo" starts at index 4.
        let (tv, _) = makeHybridTextView("```\nfoo\n```", selection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "```\nfoo\n```",
                       "Body must be unchanged inside fenced block")
        XCTAssertEqual(tv.armedInlineKinds, [],
                       "Arm must be a no-op inside fenced block (F-05)")
    }

    func test_emptySelection_armWhenInsideExistingPair_fallsThroughToToggleOff() {
        // Caret sits inside an existing **foo** pair. Per existing parity,
        // performWrap strips the pair (toggle-off path). Arming is NOT taken.
        let (tv, _) = makeHybridTextView("**foo**", selection: NSRange(location: 3, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "foo",
                       "Existing same-kind pair stripped via toggle-off path")
        XCTAssertEqual(tv.armedInlineKinds, [],
                       "Arm NOT taken — existing pair detection fired first")
    }

    // MARK: - Group D: insertText consumption-on-type

    func test_armedBold_typingChar_wrapsCharAndPlacesCaretBeforeSuffix() {
        let (tv, _) = makeHybridTextView("ab", selection: NSRange(location: 1, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.armedInlineKinds, [.bold])

        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(tv.string, "a**X**b",
                       "Typed char wrapped with armed markers")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 0),
                       "Caret lands between X and the closing ** (1 + 2 + 1 = 4)")
        XCTAssertEqual(tv.armedInlineKinds, [],
                       "Armed state clears after consumption")
    }

    func test_armedUnderlineStrike_typingChar_composedOrderIsStrikeOuterUnderlineInner() {
        let (tv, _) = makeHybridTextView("", selection: NSRange(location: 0, length: 0))
        // Underline first (innermost), then strikethrough (outermost).
        FormattingToolbarView.performWrap(prefix: "<u>", suffix: "</u>", in: tv)
        FormattingToolbarView.performWrap(prefix: "~~", suffix: "~~", in: tv)
        XCTAssertEqual(tv.armedInlineKindsOrder, [.underline, .strikethrough])

        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        // prefix = "~~<u>" (outer ~~ then inner <u>), suffix = "</u>~~"
        XCTAssertEqual(tv.string, "~~<u>X</u>~~",
                       "Composed wrap: outer strike contains inner underline contains X")
        // Caret between X and the closing tag = prefix.length + 1 = 5 + 1 = 6
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 0),
                       "Caret lands between X and </u> (prefix=5 + X=1 = 6)")
    }

    func test_armedBold_typingTwoCharsSequentially_secondCharLandsInsidePair() {
        let (tv, _) = makeHybridTextView("", selection: NSRange(location: 0, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        // After consumption: tv.string == "**X**", caret at 3, armed cleared.
        XCTAssertEqual(tv.string, "**X**")
        XCTAssertEqual(tv.armedInlineKinds, [])

        tv.insertText("Y", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Y is plain insertion at caret 3 (between X and **).
        XCTAssertEqual(tv.string, "**XY**",
                       "Y inserts inside the pair via vanilla NSTextView path")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 0),
                       "Caret between Y and ** after vanilla insert")
    }

    func test_armed_typingControlChar_doesNotConsume() {
        let (tv, _) = makeHybridTextView("ab", selection: NSRange(location: 1, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.armedInlineKinds, [.bold])

        // Insert a tab character — should fall through to super.insertText,
        // NOT take the consume + wrap path. The filter is the production
        // contract being pinned here; arming state may or may not survive
        // depending on whether super.insertText fires a side-effect selection
        // change (it does in a windowless text view because the caret moves
        // after the tab gets inserted). The point of the test is "the filter
        // works" — no `**` markers leak into the body.
        tv.insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(tv.string.contains("**"),
                       "No bold markers inserted for control-char input — filter rejected the consume path")
    }

    func test_armed_consumption_singleUndoStep() {
        let (tv, _) = makeHybridTextView("a", selection: NSRange(location: 1, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.undoManager?.canUndo, false,
                       "No undo state from arming")

        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "a**X**")
        XCTAssertEqual(tv.undoManager?.canUndo, true,
                       "Consumption registered on undo stack")

        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "a",
                       "Single undo restores the body — no marker residue")
    }

    // MARK: - Group E: selection-change cancel

    func test_armed_thenCaretMove_clearsArming() {
        let (tv, _) = makeHybridTextView("hello", selection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.armedInlineKinds, [.bold])

        tv.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(tv.armedInlineKinds, [],
                       "Caret move cancels arming")
    }

    func test_armed_consumption_doesNotPrematurelyClearViaSelectionChange() {
        let (tv, _) = makeHybridTextView("", selection: NSRange(location: 0, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        FormattingToolbarView.performWrap(prefix: "~~", suffix: "~~", in: tv)
        XCTAssertEqual(tv.armedInlineKinds, [.bold, .strikethrough])

        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        // After consumption, armed should be cleared (by consumption itself,
        // NOT by the side-effect selection change — the suppression flag
        // protects against that).
        XCTAssertEqual(tv.armedInlineKinds, [],
                       "Armed cleared exactly once by consumption; suppression flag prevented double-clear via side-effect selection change")
        XCTAssertTrue(tv.string.contains("**") || tv.string.contains("~~"),
                      "Consumed character was actually wrapped (sanity)")
    }

    func test_armed_stillSelectingDrag_doesNotCancel() {
        let (tv, _) = makeHybridTextView("hello", selection: NSRange(location: 5, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)

        tv.setSelectedRanges(
            [NSValue(range: NSRange(location: 2, length: 0))],
            affinity: .downstream,
            stillSelecting: true
        )
        XCTAssertEqual(tv.armedInlineKinds, [.bold],
                       "Mid-drag selection change must NOT cancel arming")

        tv.setSelectedRanges(
            [NSValue(range: NSRange(location: 2, length: 0))],
            affinity: .downstream,
            stillSelecting: false
        )
        XCTAssertEqual(tv.armedInlineKinds, [],
                       "Drag-end selection change cancels arming")
    }
}
