import XCTest
@testable import Sidekick

/// Pins the contract for `FormattingToolbarView.applyNumberedList(body:range:)`.
/// Mirrors `applyBulletedList`'s spec shape — line-block expansion,
/// all-prefixed-toggle-off rule, UTF-16 selection — but the prefix is
/// `<n>. ` with sequential numbering re-starting at 1 across the block.
final class NumberedListTests: XCTestCase {

    func test_singleLine_addsOnePrefix() {
        let (newBody, sel) = FormattingToolbarView.applyNumberedList(
            body: "alpha",
            range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(newBody, "1. alpha")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, (newBody as NSString).length)
    }

    func test_multiLine_numbersSequentially() {
        let body = "alpha\nbeta\ngamma"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyNumberedList(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "1. alpha\n2. beta\n3. gamma")
    }

    func test_allPrefixed_togglesOff() {
        let body = "1. alpha\n2. beta\n3. gamma"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyNumberedList(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "alpha\nbeta\ngamma")
    }

    func test_mixedPrefixed_addsAndRenumbers() {
        // Spec parity with bulleted list: any non-prefixed line forces add
        // mode; existing numeric prefixes are stripped before re-numbering.
        let body = "1. alpha\nbeta\n3. gamma"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyNumberedList(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "1. alpha\n2. beta\n3. gamma")
    }

    func test_outOfOrderPrefixes_areTreatedAsPrefixed_andStrip() {
        // Hand-edited "5. foo\n7. bar" — every non-empty line starts with
        // <digits>. so the toggle-off rule fires.
        let body = "5. foo\n7. bar"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyNumberedList(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "foo\nbar")
    }

    func test_emptyLineInMiddle_getsPrefixedToo() {
        // Apple Notes / bulleted-list convention: empty lines also get the
        // prefix in add mode. Numbering increments through the empty line.
        let body = "alpha\n\nbeta"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyNumberedList(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "1. alpha\n2. \n3. beta")
    }

    func test_preservesTrailingNewline() {
        // Input ends with "\n" — output should preserve it (mirrors
        // applyBulletedList's trailingEmpty handling).
        let body = "alpha\nbeta\n"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyNumberedList(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "1. alpha\n2. beta\n")
    }

    func test_selectionWithinBlock_expandsToFullLines() {
        // Selection is "lph" inside line 1 — lineRange should still expand
        // to cover the full line(s) the selection touches.
        let body = "alpha\nbeta"
        let range = NSRange(location: 1, length: 3)   // "lph"
        let (newBody, _) = FormattingToolbarView.applyNumberedList(
            body: body,
            range: range
        )
        XCTAssertEqual(newBody, "1. alpha\nbeta")
    }
}
