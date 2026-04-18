import XCTest
@testable import Sidekick

/// Phase 8 Wave 0 scaffold. Wave 5 (Plan 05) fills in real assertions.
///
/// Coverage target: MENU-01..04 + KBD-02 action-method routing —
/// each `@objc` method on AppDelegate calls the right store / PanelState
/// mutator with the right args:
///   newNote(_:)        → store.create() + panelState.selectedNoteID = new.id
///   reloadNotes(_:)    → store.reload()
///   togglePreview(_:)  → panelState.isPreviewMode.toggle()
///   pinToggle(_:)      → store.setPinned(id, !current)
///   deleteNote(_:)     → store.delete(id) + panelState.selectedNoteID = successor
///   formatBold(_:)…    → FormattingToolbarView.performWrap(prefix:suffix:in:)
///
/// Pattern: NoteStoreIntegrationTests (@MainActor + TempFolder +
/// async store calls).
@MainActor
final class MenuActionRoutingTests: XCTestCase {
    func test_scaffold_smoke() {
        // Wave 0 scaffold — replaced with real MENU-01..04 + KBD-02 assertions in Plan 05.
        XCTAssertTrue(true)
    }
}
