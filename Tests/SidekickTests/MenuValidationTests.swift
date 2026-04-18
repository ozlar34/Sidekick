import XCTest
import AppKit
@testable import Sidekick

/// Phase 8 Wave 0 scaffold. Wave 5 (Plan 05) fills in real assertions.
///
/// Coverage target: MENU-05 enable/disable rules via
/// `AppDelegate.validateUserInterfaceItem(_:)` — one parameterized
/// case per action (newNote / reloadNotes / togglePreview / formatBold
/// / formatItalic / formatInlineCode / formatLink / pinToggle /
/// deleteNote) across (panelVisible × hasSelection × editorFocused)
/// combinations. Also covers the Pin/Unpin dynamic-title flip
/// (D-U-02).
///
/// Pattern: SidebarSelectionTests (@MainActor integration style) +
/// TempFolder fixture for real NoteStore construction.
@MainActor
final class MenuValidationTests: XCTestCase {
    func test_scaffold_smoke() {
        // Wave 0 scaffold — replaced with real MENU-05 assertions in Plan 05.
        XCTAssertTrue(true)
    }
}
