import XCTest
import AppKit
@testable import Sidekick

/// Phase 8 Wave 0 scaffold. Wave 3 (Plan 03) fills in real assertions.
///
/// Coverage target: `FormattingToolbarView.performWrap(prefix:suffix:in:)`
/// (the new static helper extracted from `EditorPaneView.wrapSelection`) —
/// the NSTextView edit sandwich (shouldChangeText → replaceCharacters →
/// didChangeText) must register on NSTextView.undoManager automatically
/// and leave the correct cursor position.
///
/// Pattern: FormattingToolbarTests (static-method style) + `@MainActor`
/// because NSTextView is main-actor-bound.
@MainActor
final class PerformWrapTests: XCTestCase {
    func test_scaffold_smoke() {
        // Wave 0 scaffold — replaced with real MENU-02 assertions in Plan 03.
        XCTAssertTrue(true)
    }
}
