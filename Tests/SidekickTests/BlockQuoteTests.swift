import XCTest
@testable import Sidekick

/// Pins the contract for `FormattingToolbarView.applyBlockQuote(body:range:)`.
/// Mirrors `applyBulletedList` exactly with `"> "` instead of `"- "`.
final class BlockQuoteTests: XCTestCase {

    func test_singleLine_addsPrefix() {
        let (newBody, sel) = FormattingToolbarView.applyBlockQuote(
            body: "alpha",
            range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(newBody, "> alpha")
        XCTAssertEqual(sel.location, 0)
        XCTAssertEqual(sel.length, (newBody as NSString).length)
    }

    func test_multiLine_addsPrefixToEach() {
        let body = "alpha\nbeta\ngamma"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyBlockQuote(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "> alpha\n> beta\n> gamma")
    }

    func test_allPrefixed_togglesOff() {
        let body = "> alpha\n> beta"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyBlockQuote(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "alpha\nbeta")
    }

    func test_mixedPrefixed_addsToAll() {
        // Bulleted-list parity: any non-prefixed non-empty line forces add
        // mode; the prefix is prepended to EVERY line (existing prefixes
        // double-up — same as bulleted list).
        let body = "> alpha\nbeta"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyBlockQuote(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "> > alpha\n> beta")
    }

    func test_emptyLine_getsPrefixedInAddMode() {
        let body = "alpha\n\nbeta"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyBlockQuote(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "> alpha\n> \n> beta")
    }

    func test_preservesTrailingNewline() {
        let body = "alpha\nbeta\n"
        let fullRange = NSRange(location: 0, length: (body as NSString).length)
        let (newBody, _) = FormattingToolbarView.applyBlockQuote(
            body: body,
            range: fullRange
        )
        XCTAssertEqual(newBody, "> alpha\n> beta\n")
    }
}
