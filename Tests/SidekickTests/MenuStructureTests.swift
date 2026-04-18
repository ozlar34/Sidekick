import XCTest
import AppKit
@testable import Sidekick

/// Phase 8 Wave 0 scaffold. Wave 5 (Plan 05) fills in real assertions.
///
/// Coverage target: MENU-01..04 + KBD-01 structural assertions on the
/// NSApp.mainMenu installed by `AppDelegate.installMainMenu()` —
/// submenu titles (File / Format / View / Note), item counts, key
/// equivalents, modifier masks.
///
/// Pattern: FormattingToolbarTests (pure-function XCTest) +
/// `@MainActor` because NSMenu APIs are main-actor-bound.
@MainActor
final class MenuStructureTests: XCTestCase {
    func test_scaffold_smoke() {
        // Wave 0 scaffold — replaced with real MENU-01..04 assertions in Plan 05.
        XCTAssertTrue(true)
    }
}
