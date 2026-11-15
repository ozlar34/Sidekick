import XCTest
import AppKit
@testable import Sidekick

/// Regression: the FormattingToolbarView key handlers used to strip only one
/// line-terminator char, so on a CRLF line the "\r" counted as line content.
/// Each test runs a handler on an LF body and on the same body with CRLF
/// endings, and requires identical results (after normalizing CRLF → LF).
@MainActor
final class CRLFToolbarHandlerTests: XCTestCase {

    private func makeTextView(body: String, caret: Int) -> NSTextView {
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: body)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return textView
    }

    /// `lfCaret` is the caret offset in the LF body; the CRLF caret is shifted
    /// by one for every line break before it.
    private func assertCRLFMatchesLF(
        _ handler: (NSTextView) -> Bool, lfBody: String, lfCaret: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let crlfBody = lfBody.replacingOccurrences(of: "\n", with: "\r\n")
        let prefix = (lfBody as NSString).substring(to: lfCaret)
        let crlfCaret = lfCaret + prefix.filter { $0 == "\n" }.count

        let lf = makeTextView(body: lfBody, caret: lfCaret)
        let crlf = makeTextView(body: crlfBody, caret: crlfCaret)
        let lfHandled = handler(lf)
        let crlfHandled = handler(crlf)

        XCTAssertTrue(lfHandled, "sanity: handler must fire on the LF body", file: file, line: line)
        XCTAssertEqual(crlfHandled, lfHandled, "CRLF body must be handled like LF", file: file, line: line)
        XCTAssertEqual(crlf.string.replacingOccurrences(of: "\r\n", with: "\n"), lf.string,
                       "CRLF result must match LF result", file: file, line: line)
    }

    func test_checklistReturn_emptyItem_crlf() {
        assertCRLFMatchesLF(FormattingToolbarView.handleChecklistReturn, lfBody: "- [ ] \nnext", lfCaret: 6)
    }

    func test_checklistBackspace_crlf() {
        assertCRLFMatchesLF(FormattingToolbarView.handleChecklistBackspace, lfBody: "- [ ] a\nnext", lfCaret: 6)
    }

    func test_checklistForwardDelete_crlf() {
        assertCRLFMatchesLF(FormattingToolbarView.handleChecklistForwardDelete, lfBody: "- [ ] a\nnext", lfCaret: 0)
    }

    func test_thematicBreakBackspace_emptyLineBelow_crlf() {
        assertCRLFMatchesLF(FormattingToolbarView.handleThematicBreakBackspace, lfBody: "before\n\n---\n\nafter", lfCaret: 12)
    }

    func test_thematicBreakForwardDelete_contentLineAbove_crlf() {
        assertCRLFMatchesLF(FormattingToolbarView.handleThematicBreakForwardDelete, lfBody: "x\n---\nafter", lfCaret: 1)
    }

    func test_bulletReturn_emptyItem_crlf() {
        assertCRLFMatchesLF(FormattingToolbarView.handleBulletReturn, lfBody: "- \nnext", lfCaret: 2)
    }

    func test_numberedReturn_emptyItem_crlf() {
        assertCRLFMatchesLF(FormattingToolbarView.handleNumberedReturn, lfBody: "1. \nnext", lfCaret: 3)
    }
}
