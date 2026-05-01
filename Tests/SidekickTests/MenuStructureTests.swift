import XCTest
import AppKit
@testable import Sidekick

/// Covers MENU-01..04 + KBD-01 + KBD-02 structural assertions on the
/// NSApp.mainMenu produced by `AppDelegate.installMainMenu()`. Pins the
/// submenu order, titles, key equivalents, and modifier masks locked in
/// CONTEXT D-M-01..06.
@MainActor
final class MenuStructureTests: XCTestCase {

    /// Fresh delegate + installed menu for every test. NSApp.mainMenu is a
    /// shared global; tests set it via installMainMenu() each time.
    /// `NSApplication.shared` must be initialized before the first NSApp
    /// property access — in a `swift test` binary NSApp is nil until the
    /// shared instance is accessed at least once.
    private func install() -> AppDelegate {
        _ = NSApplication.shared   // ensure NSApp != nil before installMainMenu()
        let delegate = AppDelegate()
        delegate.installMainMenu()
        return delegate
    }

    // MARK: - D-M-01 — submenu order

    func test_mainMenu_hasAppFileEditFormatNoteInOrder() {
        _ = install()
        let mainMenu = NSApp.mainMenu
        XCTAssertNotNil(mainMenu, "installMainMenu() must set NSApp.mainMenu")
        XCTAssertEqual(mainMenu?.items.count, 5,
                       "mainMenu has 5 top-level items after Phase 11: App, File, Edit, Format, Note")

        let submenuTitles = mainMenu?.items.compactMap { $0.submenu?.title } ?? []
        XCTAssertEqual(submenuTitles, ["Sidekick", "File", "Edit", "Format", "Note"],
                       "Submenu order must be D-M-01: App → File → Edit → Format → Note")
    }

    // MARK: - D-M-02 — App submenu

    func test_appSubmenu_hasAboutBeforeQuit() {
        _ = install()
        let appSubmenu = NSApp.mainMenu?.items.first?.submenu
        XCTAssertNotNil(appSubmenu, "App submenu must exist")

        guard let items = appSubmenu?.items, items.count >= 3 else {
            XCTFail("App submenu must have at least About, separator, Quit")
            return
        }
        XCTAssertEqual(items[0].title, "About Sidekick", "First item: About Sidekick (D-M-02)")
        XCTAssertTrue(items[1].isSeparatorItem, "Separator between About and Quit")
        XCTAssertEqual(items[2].title, "Quit Sidekick", "Third item: Quit Sidekick")
        XCTAssertEqual(items[2].keyEquivalent, "q", "Quit keeps ⌘Q")
    }

    // MARK: - D-M-03 — File submenu (MENU-01 + KBD-02)

    func test_fileSubmenu_hasNewNoteCmdN_andReloadNotesCmdR() {
        _ = install()
        let fileSubmenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu
        XCTAssertNotNil(fileSubmenu, "File submenu must exist (MENU-01)")
        XCTAssertEqual(fileSubmenu?.items.count, 2, "File has exactly 2 items: New Note, Reload Notes")

        let newNote = fileSubmenu?.items[0]
        XCTAssertEqual(newNote?.title, "New Note", "MENU-01 title")
        XCTAssertEqual(newNote?.keyEquivalent, "n", "MENU-01 ⌘N")
        XCTAssertEqual(newNote?.keyEquivalentModifierMask, .command, "MENU-01 modifier is .command only")

        let reload = fileSubmenu?.items[1]
        XCTAssertEqual(reload?.title, "Reload Notes", "KBD-02 title")
        XCTAssertEqual(reload?.keyEquivalent, "r", "KBD-02 ⌘R")
        XCTAssertEqual(reload?.keyEquivalentModifierMask, .command, "KBD-02 modifier is .command only")
    }

    // MARK: - D-M-04 — Format submenu (MENU-02)

    func test_formatSubmenu_hasBoldItalicInlineCodeLinkBullet_withCorrectShortcuts() {
        _ = install()
        let formatSubmenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Format" })?.submenu
        XCTAssertNotNil(formatSubmenu, "Format submenu must exist (MENU-02)")
        XCTAssertEqual(formatSubmenu?.items.count, 10,
                       "Format has 10 items: Bold, Italic, Inline Code, Link, Bulleted List, separator, Heading 1, Heading 2, Heading 3, Body")

        let byTitle: (String) -> NSMenuItem? = { title in
            formatSubmenu?.items.first { $0.title == title }
        }

        let bold = byTitle("Bold")
        XCTAssertEqual(bold?.keyEquivalent, "b", "⌘B")
        XCTAssertEqual(bold?.keyEquivalentModifierMask, .command)

        let italic = byTitle("Italic")
        XCTAssertEqual(italic?.keyEquivalent, "i", "⌘I")
        XCTAssertEqual(italic?.keyEquivalentModifierMask, .command)

        let inlineCode = byTitle("Inline Code")
        XCTAssertEqual(inlineCode?.keyEquivalent, "c", "⌘⌥C uses lowercase c + [.command, .option]")
        XCTAssertEqual(inlineCode?.keyEquivalentModifierMask, [.command, .option],
                       "Inline Code modifier mask is explicit [.command, .option] union (D-S-02)")

        let link = byTitle("Link")
        XCTAssertEqual(link?.keyEquivalent, "k", "⌘K")
        XCTAssertEqual(link?.keyEquivalentModifierMask, .command)

        // Bulleted List (quick/260419-hca) — ⌘⇧8 with explicit
        // [.command, .shift] modifier mask (non-letter key — uppercase
        // "8" does NOT auto-imply Shift; mirror Inline Code's explicit union).
        let bulleted = byTitle("Bulleted List")
        XCTAssertNotNil(bulleted, "Bulleted List menu item must exist")
        XCTAssertEqual(bulleted?.keyEquivalent, "8", "⌘⇧8")
        XCTAssertEqual(bulleted?.keyEquivalentModifierMask, [.command, .shift],
                       "Bulleted List modifier mask is explicit [.command, .shift] (non-letter key needs explicit Shift)")

        // Headings — ⌘⌥1/2/3 + ⌘⌥0 for Body. Numbers are non-letter keys
        // so the modifier mask must be set explicitly (same pattern as ⌘⌥C).
        // A separator sits between Bulleted List and Heading 1.
        let separatorIndex = formatSubmenu?.items.firstIndex(where: { $0.isSeparatorItem })
        XCTAssertNotNil(separatorIndex, "Separator must exist between inline tools and headings")

        let h1 = byTitle("Heading 1")
        XCTAssertEqual(h1?.keyEquivalent, "1", "⌘⌥1")
        XCTAssertEqual(h1?.keyEquivalentModifierMask, [.command, .option],
                       "Heading 1 modifier mask is explicit [.command, .option]")

        let h2 = byTitle("Heading 2")
        XCTAssertEqual(h2?.keyEquivalent, "2", "⌘⌥2")
        XCTAssertEqual(h2?.keyEquivalentModifierMask, [.command, .option],
                       "Heading 2 modifier mask is explicit [.command, .option]")

        let h3 = byTitle("Heading 3")
        XCTAssertEqual(h3?.keyEquivalent, "3", "⌘⌥3")
        XCTAssertEqual(h3?.keyEquivalentModifierMask, [.command, .option],
                       "Heading 3 modifier mask is explicit [.command, .option]")

        let body = byTitle("Body")
        XCTAssertEqual(body?.keyEquivalent, "0", "⌘⌥0")
        XCTAssertEqual(body?.keyEquivalentModifierMask, [.command, .option],
                       "Body modifier mask is explicit [.command, .option]")
    }

    // MARK: - D-M-06 — Note submenu (MENU-04)

    func test_noteSubmenu_hasPinAndDelete_noShortcutOnDelete() {
        _ = install()
        let noteSubmenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Note" })?.submenu
        XCTAssertNotNil(noteSubmenu, "Note submenu must exist (MENU-04)")
        XCTAssertEqual(noteSubmenu?.items.count, 2, "Note has exactly 2 items: Pin (dynamic title), Delete")

        let pin = noteSubmenu?.items[0]
        XCTAssertEqual(pin?.title, "Pin",
                       "Initial title 'Pin' (validateUserInterfaceItem flips to 'Unpin' per D-U-02)")
        XCTAssertEqual(pin?.keyEquivalent, "", "Pin has no keyboard shortcut")

        let del = noteSubmenu?.items[1]
        XCTAssertEqual(del?.title, "Delete", "MENU-04 title")
        XCTAssertEqual(del?.keyEquivalent, "",
                       "Delete has NO shortcut (D-M-06 prevents keyboard accidents)")
        XCTAssertEqual(del?.keyEquivalentModifierMask, [],
                       "Delete modifier mask explicitly empty (D-M-06)")
    }
}
