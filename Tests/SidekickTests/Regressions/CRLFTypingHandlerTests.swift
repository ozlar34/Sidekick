import XCTest
import AppKit
@testable import Sidekick

/// Regression: the HybridTextView typing triggers (`/hr` quick-insert and the
/// trailing-HR escape) used to strip only one line-terminator char, so on a
/// CRLF line the "\r" counted as line content. Each test types the same
/// keystrokes into an LF body and the same body with CRLF endings, and
/// requires identical results (after normalizing CRLF → LF).
@MainActor
final class CRLFTypingHandlerTests: XCTestCase {

    /// `lfCaret` is the caret offset in the LF body; the CRLF caret is shifted
    /// by one for every line break before it. `fired` checks, on the LF result,
    /// that the typed input actually exercised the handler under test.
    private func assertCRLFMatchesLF(
        lfBody: String, lfCaret: Int, typing: String,
        fired: (String) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let crlfBody = lfBody.replacingOccurrences(of: "\n", with: "\r\n")
        let prefix = (lfBody as NSString).substring(to: lfCaret)
        let crlfCaret = lfCaret + prefix.filter { $0 == "\n" }.count

        let lf = KeystrokeRunner(initialBody: lfBody,
                                 initialSelection: NSRange(location: lfCaret, length: 0))
        let crlf = KeystrokeRunner(initialBody: crlfBody,
                                   initialSelection: NSRange(location: crlfCaret, length: 0))
        lf.type(typing)
        crlf.type(typing)

        XCTAssertTrue(fired(lf.body), "sanity: handler must fire on the LF body", file: file, line: line)
        XCTAssertEqual(crlf.body.replacingOccurrences(of: "\r\n", with: "\n"), lf.body,
                       "CRLF result must match LF result", file: file, line: line)
    }

    /// `/hr` typed on a line that has a line below it. On CRLF the line
    /// content read as "/hr\r", so the exact match failed and the trigger
    /// stayed as literal text.
    func test_slashQuickInsert_lineBelow_crlf() {
        assertCRLFMatchesLF(lfBody: "/h\nnext", lfCaret: 2, typing: "r",
                            fired: { !$0.contains("/hr") && $0.contains("---") })
    }

    func test_slashQuickInsertDivider_lineBelow_crlf() {
        assertCRLFMatchesLF(lfBody: "/divide\nnext", lfCaret: 7, typing: "r",
                            fired: { !$0.contains("/divider") && $0.contains("---") })
    }

    /// Trailing-HR escape: `---` typed as the final line. The escape only
    /// fires when the HR line has no terminator, so CRLF bodies can't reach
    /// the "\r" branch; this pins the behavior across the helper swap.
    func test_trailingHREscape_finalLine_crlf() {
        assertCRLFMatchesLF(lfBody: "x\n\n--", lfCaret: 5, typing: "-",
                            fired: { $0.hasSuffix("---\n") })
    }
}
