import XCTest
import AppKit
@testable import Sidekick

/// Covers KBD-01 and KBD-02 — the preview-toggle shortcut migration
/// ⌘R → ⌘⇧P.
///
/// KBD-01: The hidden `Button("") { togglePreviewMode() }.keyboardShortcut("r", .command)`
///         in EditorPaneView must be GONE. The four `.keyboardShortcut(...)` modifiers
///         on FormattingToolbarView buttons must ALSO be gone (D-S-01).
/// KBD-02: ⌘R now binds to File > Reload Notes → `AppDelegate.reloadNotes(_:)`,
///         NOT to `togglePreview:`.
///
/// Pattern: FormattingToolbarTests (pure-function style) + file-contents grep
/// for static regression checks + menu inspection for the binding check.
@MainActor
final class KeyboardShortcutMigrationTests: XCTestCase {

    // MARK: - KBD-01: EditorPaneView no longer carries the hidden ⌘R Button

    func test_editorPaneView_noHiddenRBinding() throws {
        let url = Self.repoSourceURL(subpath: "Sources/Sidekick/EditorPaneView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains(".keyboardShortcut(\"r\""),
                       "KBD-01: EditorPaneView must NOT contain .keyboardShortcut(\"r\" (hidden ⌘R Button deleted per D-K-01)")
        XCTAssertFalse(source.contains(".keyboardShortcut"),
                       "D-K-01 + D-S-01: EditorPaneView must NOT carry ANY .keyboardShortcut modifier after Phase 8")
    }

    // MARK: - D-S-01: FormattingToolbarView no longer carries toolbar-button shortcuts

    func test_formattingToolbarView_noKeyboardShortcutModifiers() throws {
        let url = Self.repoSourceURL(subpath: "Sources/Sidekick/FormattingToolbarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains(".keyboardShortcut("),
                       "D-S-01: FormattingToolbarView must NOT carry .keyboardShortcut modifiers — menu items own all shortcuts now")
    }

    // MARK: - KBD-02: ⌘R binds to reloadNotes, not togglePreview

    func test_reloadNotesMenuItem_hasCmdR_andActionIsReloadNotes() {
        _ = NSApplication.shared   // ensure NSApp != nil before installMainMenu()
        let delegate = AppDelegate()
        delegate.installMainMenu()

        let fileSubmenu = NSApp.mainMenu?
            .items.first(where: { $0.submenu?.title == "File" })?.submenu
        XCTAssertNotNil(fileSubmenu, "File submenu must exist")

        let reloadItem = fileSubmenu?.items.first(where: { $0.title == "Reload Notes" })
        XCTAssertNotNil(reloadItem, "KBD-02: File > Reload Notes must exist")
        XCTAssertEqual(reloadItem?.keyEquivalent, "r", "KBD-02: Reload Notes uses ⌘R")
        XCTAssertEqual(reloadItem?.keyEquivalentModifierMask, .command, "KBD-02: modifier is .command")
        XCTAssertEqual(reloadItem?.action, #selector(AppDelegate.reloadNotes(_:)),
                       "KBD-02: ⌘R action is reloadNotes:, NOT togglePreview:")

        // Sanity: togglePreview is wired only to View > Toggle Preview (⌘⇧P), NOT File > Reload Notes
        let viewSubmenu = NSApp.mainMenu?
            .items.first(where: { $0.submenu?.title == "View" })?.submenu
        let toggleItem = viewSubmenu?.items.first(where: { $0.title == "Toggle Preview" })
        XCTAssertEqual(toggleItem?.action, #selector(AppDelegate.togglePreview(_:)),
                       "KBD-01: togglePreview action is wired to View > Toggle Preview (⌘⇧P)")
        XCTAssertNotEqual(toggleItem?.keyEquivalent, "r",
                          "KBD-01: togglePreview is ⌘⇧P, not ⌘R")
    }

    // MARK: - Helper

    /// Resolve an absolute URL to a source file in the repo root, regardless
    /// of where `swift test` runs from. `#filePath` points at this test file
    /// inside Tests/SidekickTests/; walk up three directories to reach repo root,
    /// then append the relative subpath.
    private static func repoSourceURL(subpath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/SidekickTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(subpath)
    }
}
