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
