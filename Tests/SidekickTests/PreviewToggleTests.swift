import XCTest
@testable import Sidekick

/// Pins the cursor offset clamp contract from CONTEXT D-04.
/// `EditorPaneView.clampOffset(_:in:)` will be created in plan 04-03;
/// these tests are the RED state that proves the behavior is implemented
/// correctly (UTF-16 units, not Character/Unicode-scalar count).
final class PreviewToggleTests: XCTestCase {

    func testClampOffset_inRangeOffsetIsPreserved() throws {
        let result = EditorPaneView.clampOffset(5, in: "hello world")
        XCTAssertEqual(result, 5, "Offset within bounds must be returned unchanged (D-04)")
    }

    func testClampOffset_outOfRangeClampsToBodyLength() throws {
        // "hello" is 5 UTF-16 code units; offset 999 must clamp to 5
        let result = EditorPaneView.clampOffset(999, in: "hello")
        XCTAssertEqual(result, 5, "Out-of-range offset must clamp to body.utf16.count (D-04 fallback)")
    }

    func testClampOffset_emptyBodyReturnsZero() throws {
        let result = EditorPaneView.clampOffset(0, in: "")
        XCTAssertEqual(result, 0, "Empty body has zero-length range; offset must be 0")
    }

    func testClampOffset_usesUTF16CountNotCharacterCount() throws {
        // "café 🎉" — 6 Characters, but 7 UTF-16 code units (emoji is surrogate pair = 2 units)
        // Per RESEARCH Pitfall 2 + Open Question 2: NSRange.location is UTF-16 units.
        let body = "café 🎉"
        XCTAssertEqual(body.utf16.count, 7, "Sanity: 'café 🎉' is 7 UTF-16 units (test premise)")
        let result = EditorPaneView.clampOffset(100, in: body)
        XCTAssertEqual(result, 7, "Clamp must use utf16.count (not Character count) to match NSRange semantics")
    }
}
