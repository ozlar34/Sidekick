import XCTest
import AppKit
@testable import Sidekick

// Finding [3] (xhigh review): hrNeighborLocation inferred "has a line below" from
// `character(at:) == 0x0A`, treating only LF as a terminator. But lineRange(for:)
// also ends lines on CR, CRLF, U+2028, U+2029 and NEL — so an HR line terminated
// by e.g. U+2028 (common in PDF/rich-editor paste) was misread as having no line
// below, and a bottom-half click / downward motion relocated the caret UP instead
// of down. Fix: test the last scalar against CharacterSet.newlines.
@MainActor
final class HRUnicodeTerminatorTests: XCTestCase {

    /// HR terminated by U+2028 (LINE SEPARATOR) with content below: a bottom-half
    /// click must relocate the caret to the line BELOW, not the line above.
    /// Body: "A\u{2028}---\u{2028}B"  (A=0, sep=1, ---=2..4, sep=5, B=6)
    func test_hrTerminatedByLineSeparator_relocatesBelow() {
        let runner = HostedEditorRunner(
            initialBody: "A\u{2028}---\u{2028}B",
            initialSelection: NSRange(location: 0, length: 0)
        )
        let tv = runner.inner.textView

        // Precondition: `---` is detected as an HR across the U+2028 separator.
        // If this fails, [3] is defensive-only (bug not currently reachable).
        XCTAssertNotNil(
            runner.inner.storage.attribute(.sidekickThematicBreak, at: 2, effectiveRange: nil),
            "`---` must be detected as an HR for this case to exercise [3]"
        )

        // Caret on the HR line, click in the bottom half → line below (B @ 6).
        let dest = tv.hrCaretRelocationTarget(caret: 3, clickInBottomHalf: true)
        XCTAssertEqual(dest, 6,
                       "Bottom-half click on a U+2028-terminated HR must relocate DOWN to the line below")
    }
}
