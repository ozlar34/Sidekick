import XCTest
import AppKit
@testable import Sidekick

/// Covers MENU-05 enable/disable rules via
/// `AppDelegate.validateUserInterfaceItem(_:)` and the D-U-02 Pin/Unpin
/// dynamic-title flip.
///
/// Test scope: negative cases (disabled when panel hidden / no selection /
/// editor not focused) are fully covered here because they depend only on
/// state readable without a real NSPanel (`panelController.panel == nil`
/// means panelVisible is false; `panelController.panelState.selectedNoteID
/// == nil` means hasSelection is false).
///
/// Positive cases (enabled when panel visible AND selection AND editor is
/// first responder) require a live NSPanel + NSTextView fixture which is
/// impractical for XCTest — those are covered by the manual checklist in
/// `.planning/phases/08-menu-bar-keyboard-shortcuts/08-VALIDATION.md`.
@MainActor
final class MenuValidationTests: XCTestCase {

    override func setUp() async throws {
        // Ensure NSApp != nil before any validateUserInterfaceItem calls.
        _ = NSApplication.shared
    }

    private func makeDelegate() throws -> (AppDelegate, TempFolder, NoteStore) {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let delegate = AppDelegate(store: store)
        return (delegate, tmp, store)
    }

    // Helper: construct an NSMenuItem targeting the given action selector.
    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    // MARK: - D-V-02: Format actions disabled when panel hidden / editor not focused

    func test_formatBold_disabled_whenPanelHidden() throws {
        let (delegate, _, _) = try makeDelegate()
        // panelController.panel is nil (never called toggle()); panelVisible = false.
        XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(#selector(AppDelegate.formatBold(_:)))),
                       "D-V-02: formatBold must be disabled when panel is hidden")
    }

    func test_formatAllFour_disabled_whenPanelHidden() throws {
        let (delegate, _, _) = try makeDelegate()
        for sel in [#selector(AppDelegate.formatBold(_:)),
                    #selector(AppDelegate.formatItalic(_:)),
                    #selector(AppDelegate.formatInlineCode(_:)),
                    #selector(AppDelegate.formatLink(_:))] {
            XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(sel)),
                           "D-V-02: \(sel) must be disabled when panel is hidden")
        }
    }

    // MARK: - D-V-03: Toggle Preview disabled without panel or selection

    func test_togglePreview_disabled_whenPanelHidden() throws {
        let (delegate, _, _) = try makeDelegate()
        XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(#selector(AppDelegate.togglePreview(_:)))),
                       "D-V-03: togglePreview disabled when panel hidden")
    }

    func test_togglePreview_disabled_whenNoSelection() throws {
        let (delegate, _, _) = try makeDelegate()
        // panelState.selectedNoteID = nil by default
        XCTAssertNil(delegate.panelController.panelState.selectedNoteID)
        XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(#selector(AppDelegate.togglePreview(_:)))),
                       "D-V-03: togglePreview disabled when no note selected")
    }

    // MARK: - D-V-04: Note actions disabled without selection

    func test_noteActions_disabled_whenNoSelection() throws {
        let (delegate, _, _) = try makeDelegate()
        XCTAssertNil(delegate.panelController.panelState.selectedNoteID)
        XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(#selector(AppDelegate.pinToggle(_:)))),
                       "D-V-04: pinToggle disabled when no selection")
        XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(#selector(AppDelegate.deleteNote(_:)))),
                       "D-V-04: deleteNote disabled when no selection")
    }

    // MARK: - D-V-05 + D-U-01: File actions disabled when panel hidden

    func test_newNote_and_reloadNotes_disabled_whenPanelHidden() throws {
        let (delegate, _, _) = try makeDelegate()
        XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(#selector(AppDelegate.newNote(_:)))),
                       "D-V-05 + D-U-01: newNote disabled when panel hidden — no auto-summon")
        XCTAssertFalse(delegate.validateUserInterfaceItem(menuItem(#selector(AppDelegate.reloadNotes(_:)))),
                       "D-V-05: reloadNotes disabled when panel hidden")
    }

    // MARK: - Default branch preserves Edit submenu

    func test_default_returnsTrue_forUnrecognizedAction() throws {
        let (delegate, _, _) = try makeDelegate()
        // Edit submenu Undo action selector — dispatches via responder chain.
        // AppDelegate's validateUserInterfaceItem switch default must return true
        // so Cocoa's NSText/NSTextView validation takes over.
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        XCTAssertTrue(delegate.validateUserInterfaceItem(undoItem),
                      "Default branch must return true so Edit submenu (nil-target) stays functional")
    }

    // MARK: - D-U-02: Pin/Unpin dynamic title flip

    func test_pinToggleItem_titleFlipsToUnpin_whenSelectedNoteIsPinned() async throws {
        // Keep tmp alive explicitly — TempFolder.deinit removes the directory;
        // if the tuple's unnamed element is discarded immediately the directory
        // is gone before store.create() can write the file.
        let (delegate, tmp, store) = try makeDelegate()
        _ = tmp  // retain TempFolder for the duration of the test
        let note = try await store.create()
        try await store.setPinned(note.id, true)
        delegate.panelController.panelState.selectedNoteID = note.id

        let item = NSMenuItem(title: "Pin", action: #selector(AppDelegate.pinToggle(_:)), keyEquivalent: "")
        let enabled = delegate.validateUserInterfaceItem(item)
        XCTAssertTrue(enabled, "D-V-04: pinToggle enabled when a note is selected")
        XCTAssertEqual(item.title, "Unpin",
                       "D-U-02: validateUserInterfaceItem flips title to 'Unpin' when selected note is pinned")
    }

    func test_pinToggleItem_titleStaysAsPin_whenSelectedNoteIsUnpinned() async throws {
        let (delegate, tmp, store) = try makeDelegate()
        _ = tmp  // retain TempFolder for the duration of the test
        let note = try await store.create()
        // note is unpinned by default
        delegate.panelController.panelState.selectedNoteID = note.id

        let item = NSMenuItem(title: "Pin", action: #selector(AppDelegate.pinToggle(_:)), keyEquivalent: "")
        let enabled = delegate.validateUserInterfaceItem(item)
        XCTAssertTrue(enabled, "D-V-04: pinToggle enabled when a note is selected")
        XCTAssertEqual(item.title, "Pin",
                       "D-U-02: validateUserInterfaceItem sets title to 'Pin' when selected note is unpinned")
    }
}
