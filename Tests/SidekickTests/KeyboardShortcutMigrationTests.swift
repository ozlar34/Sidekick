import XCTest
import AppKit
@testable import Sidekick

/// Phase 8 Wave 0 scaffold. Wave 5 (Plan 05) fills in real assertions.
///
/// Coverage target:
///   KBD-01 — the hidden `Button("") { togglePreviewMode() }
///            .keyboardShortcut("r", .command)` in EditorPaneView is
///            deleted; View > Toggle Preview owns ⌘⇧P.
///   KBD-02 — File > Reload Notes has keyEquivalent "r" + .command;
///            ⌘R action is `reloadNotes:` (not `togglePreview:`).
///
/// Pattern: FormattingToolbarTests (pure-function style) +
/// `@MainActor` for NSMenu inspection.
@MainActor
final class KeyboardShortcutMigrationTests: XCTestCase {
    func test_scaffold_smoke() {
        // Wave 0 scaffold — replaced with real KBD-01/KBD-02 assertions in Plan 05.
        XCTAssertTrue(true)
    }
}
