import AppKit
import Foundation

// IN-07: @MainActor propagation. `panelController = PanelController()` is a
// stored-property initializer; now that PanelController is @MainActor, its
// init is main-actor-isolated and the enclosing type must be too. NSApp
// delegate callbacks already run on main, so this matches the runtime reality.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let hotkeyManager = HotkeyManager()
    let panelController = PanelController()
    internal var store: NoteStore?
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    #if DEBUG
    /// Non-nil only when launched with `--debug-port` (see DebugHarness).
    private var debugHarness: DebugHarness?
    #endif

    /// Test-seam initializer. Skips the hotkey registration and NoteStore
    /// construction that happen in `applicationDidFinishLaunching(_:)` so
    /// tests can drive menu wiring and validation against a caller-supplied
    /// store. Production code continues to use `AppDelegate()` (designated
    /// NSObject init) + the `NSApplicationDelegate` lifecycle.
    internal convenience init(store: NoteStore) {
        self.init()
        self.store = store
        self.panelController.store = store
    }

    @objc func openSettings(_ sender: Any? = nil) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    /// G-05: Builds NSApp.mainMenu with an App submenu (Quit) and an Edit
    /// submenu (Undo / Redo / Cut / Copy / Paste / Select All). Without this,
    /// NSApp.mainMenu is nil — accessory-type apps ship no nib and Cocoa's
    /// key-equivalent dispatcher has no place to find undo:/redo:/terminate:.
    /// SAME FIX resolves Test 6 Cmd+Q observation (same root cause as G-05).
    internal func installMainMenu() {
        let mainMenu = NSMenu()

        // App submenu — About + Quit Sidekick
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Sidekick")

        // About Sidekick (D-M-02) — uses stock AppKit about panel (reads
        // CFBundleShortVersionString + CFBundleVersion from Info.plist).
        let aboutItem = NSMenuItem(
            title: "About Sidekick",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(
            title: "Quit Sidekick",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File submenu (D-M-03) — MENU-01 + KBD-02
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let newNoteItem = NSMenuItem(
            title: "New Note",
            action: #selector(newNote(_:)),
            keyEquivalent: "n"
        )
        newNoteItem.target = self
        fileMenu.addItem(newNoteItem)

        let reloadItem = NSMenuItem(
            title: "Reload Notes",
            action: #selector(reloadNotes(_:)),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        fileMenu.addItem(reloadItem)

        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit submenu — standard Cocoa editing actions dispatch to the
        // current first responder (NSTextView inside SwiftUI TextEditor).
        // Cocoa auto-enables/disables each item against the responder, so
        // TextEditor's NSUndoManager becomes reachable with no other code.
        let editItem = NSMenuItem()
        let editMenu = PlainCommandMenu(title: "Edit")

        editMenu.addItem(NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        // Cmd+Shift+Z — capital "Z" + default .command modifier is sufficient;
        // AppKit interprets uppercase key equivalents as requiring Shift.
        editMenu.addItem(NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        ))
        // Historical Cmd+Y redo (emacs-style yank). Some users expect it.
        let legacyRedo = NSMenuItem(
            title: "Redo (Alt)",
            action: Selector(("redo:")),
            keyEquivalent: "y"
        )
        legacyRedo.isHidden = true  // Cmd+Y fires the binding even when hidden
        editMenu.addItem(legacyRedo)

        editMenu.addItem(NSMenuItem.separator())

        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))

        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(Self.makeFindMenuItem())

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Format submenu (D-M-04) — MENU-02
        let formatItem = NSMenuItem()
        let formatMenu = NSMenu(title: "Format")

        let boldItem = NSMenuItem(
            title: "Bold",
            action: #selector(formatBold(_:)),
            keyEquivalent: "b"
        )
        boldItem.target = self
        formatMenu.addItem(boldItem)

        let italicItem = NSMenuItem(
            title: "Italic",
            action: #selector(formatItalic(_:)),
            keyEquivalent: "i"
        )
        italicItem.target = self
        formatMenu.addItem(italicItem)

        let underlineItem = NSMenuItem(
            title: "Underline",
            action: #selector(formatUnderline(_:)),
            keyEquivalent: "u"
        )
        underlineItem.target = self
        formatMenu.addItem(underlineItem)

        let strikethroughItem = NSMenuItem(
            title: "Strikethrough",
            action: #selector(formatStrikethrough(_:)),
            keyEquivalent: "x"
        )
        // ⌘⇧X — letter keys would auto-imply Shift via uppercase, but we set
        // explicit modifier mask to mirror non-letter shortcuts and stay
        // robust if the keyEquivalent ever changes to a digit (D-S-02).
        strikethroughItem.keyEquivalentModifierMask = [.command, .shift]
        strikethroughItem.target = self
        formatMenu.addItem(strikethroughItem)

        let inlineCodeItem = NSMenuItem(
            title: "Inline Code",
            action: #selector(formatInlineCode(_:)),
            keyEquivalent: "c"
        )
        inlineCodeItem.keyEquivalentModifierMask = [.command, .option]   // ⌘⌥C explicit union (D-S-02)
        inlineCodeItem.target = self
        formatMenu.addItem(inlineCodeItem)

        let linkItem = NSMenuItem(
            title: "Link",
            action: #selector(formatLink(_:)),
            keyEquivalent: "k"
        )
        linkItem.target = self
        formatMenu.addItem(linkItem)

        let bulletedListItem = NSMenuItem(
            title: "Bulleted List",
            action: #selector(formatBulletedList(_:)),
            keyEquivalent: "8"
        )
        // ⌘⇧8 — "8" is a non-letter key, so uppercase doesn't auto-imply Shift.
        // Set an explicit modifier union (mirror inlineCodeItem, line 168).
        bulletedListItem.keyEquivalentModifierMask = [.command, .shift]
        bulletedListItem.target = self
        formatMenu.addItem(bulletedListItem)

        let numberedListItem = NSMenuItem(
            title: "Numbered List",
            action: #selector(formatNumberedList(_:)),
            keyEquivalent: "7"
        )
        numberedListItem.keyEquivalentModifierMask = [.command, .shift]
        numberedListItem.target = self
        formatMenu.addItem(numberedListItem)

        let blockQuoteItem = NSMenuItem(
            title: "Block Quote",
            action: #selector(formatBlockQuote(_:)),
            keyEquivalent: "9"
        )
        blockQuoteItem.keyEquivalentModifierMask = [.command, .shift]
        blockQuoteItem.target = self
        formatMenu.addItem(blockQuoteItem)

        let checklistItem = NSMenuItem(
            title: "Checklist",
            action: #selector(formatChecklist(_:)),
            keyEquivalent: "l"
        )
        // ⌘⇧L — letter key, but set the explicit modifier mask so the
        // shortcut requires Shift (without it, plain "l" would auto-imply
        // ⌘L which AppKit reserves for "Show Last Search" in some contexts).
        checklistItem.keyEquivalentModifierMask = [.command, .shift]
        checklistItem.target = self
        formatMenu.addItem(checklistItem)

        formatMenu.addItem(NSMenuItem.separator())

        // Heading levels — ⌘⌥1/2/3 apply or toggle-off the corresponding
        // level; ⌘⌥0 forces Body. Numbers are non-letter keys so the
        // modifier mask must be set explicitly (same pattern as ⌘⌥C).
        let heading1Item = NSMenuItem(
            title: "Heading 1",
            action: #selector(formatHeading1(_:)),
            keyEquivalent: "1"
        )
        heading1Item.keyEquivalentModifierMask = [.command, .option]
        heading1Item.target = self
        formatMenu.addItem(heading1Item)

        let heading2Item = NSMenuItem(
            title: "Heading 2",
            action: #selector(formatHeading2(_:)),
            keyEquivalent: "2"
        )
        heading2Item.keyEquivalentModifierMask = [.command, .option]
        heading2Item.target = self
        formatMenu.addItem(heading2Item)

        let heading3Item = NSMenuItem(
            title: "Heading 3",
            action: #selector(formatHeading3(_:)),
            keyEquivalent: "3"
        )
        heading3Item.keyEquivalentModifierMask = [.command, .option]
        heading3Item.target = self
        formatMenu.addItem(heading3Item)

        let bodyItem = NSMenuItem(
            title: "Body",
            action: #selector(formatHeadingBody(_:)),
            keyEquivalent: "0"
        )
        bodyItem.keyEquivalentModifierMask = [.command, .option]
        bodyItem.target = self
        formatMenu.addItem(bodyItem)

        formatItem.submenu = formatMenu
        mainMenu.addItem(formatItem)

        // Note submenu (D-M-06) — MENU-04
        let noteItem = NSMenuItem()
        let noteMenu = NSMenu(title: "Note")

        // Single dynamic Pin/Unpin item — title flipped by validateUserInterfaceItem (D-U-02).
        // Initial title "Pin" is a best-guess default; validation rewrites on every menu open.
        let pinToggleItem = NSMenuItem(
            title: "Pin",
            action: #selector(pinToggle(_:)),
            keyEquivalent: ""
        )
        pinToggleItem.target = self
        noteMenu.addItem(pinToggleItem)

        // Delete — NO keyboard shortcut (D-M-06 prevents keyboard accidents).
        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(deleteNote(_:)),
            keyEquivalent: ""
        )
        deleteItem.keyEquivalentModifierMask = []
        deleteItem.target = self
        noteMenu.addItem(deleteItem)

        noteItem.submenu = noteMenu
        mainMenu.addItem(noteItem)

        NSApp.mainMenu = mainMenu
        NSLog("[Sidekick] mainMenu installed")
    }

    /// Installs a persistent NSStatusItem in the right-side system menu bar.
    /// Left-click toggles the panel immediately (no intermediate dropdown);
    /// right-click shows a one-item "Quit Sidekick" menu.
    /// The status item survives activation-policy flips (.accessory ↔ .regular) that
    /// PanelController performs in slideIn/slideOut.
    internal func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Prefer the bundled template (card + slide-in strip silhouette — matches
            // the app icon). Fall back to an SF Symbol if the resource is missing
            // (dev-build without the install-script copy).
            let bundled = Bundle.main.url(forResource: "StatusBarIconTemplate", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
            if let image = bundled {
                image.isTemplate = true
                image.accessibilityDescription = "Sidekick"
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "sidebar.right",
                                       accessibilityDescription: "Sidekick")
                           ?? NSImage(systemSymbolName: "note.text",
                                      accessibilityDescription: "Sidekick")
                button.image?.isTemplate = true
            }

            // Wire button to a click handler instead of assigning item.menu —
            // setting .menu makes AppKit show the menu on any click and swallows
            // the action, forcing two clicks to open the panel.
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        self.statusItem = item
        NSLog("[Sidekick] statusItem installed")
    }

    /// Single click handler for the status-bar button. Branches on the event
    /// type from `NSApp.currentEvent`: right-click attaches a transient
    /// quit-only menu and pops it via `performClick`, then detaches; left-click
    /// (and any other button) toggles the panel through the same code path as
    /// the ⌃⌥⌘N hotkey.
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let settingsMenuItem = NSMenuItem(
                title: "Settings",
                action: #selector(openSettings(_:)),
                keyEquivalent: ""
            )
            settingsMenuItem.target = self
            menu.addItem(settingsMenuItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(
                title: "Quit Sidekick",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: ""
            ))
            // Attach the menu only for this pop, then detach so the next
            // left-click reaches `action` instead of being swallowed by AppKit's
            // built-in menu-on-click behavior.
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            panelController.toggle()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Shorten AppKit's default ~1.5s tooltip delay app-wide. Affects every
        // .help()/NSView.toolTip site. register() sets the in-memory default
        // for this run only — does NOT persist to the user's plist.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1.0])

        installMainMenu()                          // G-05: must run before any UI is shown
        installStatusItem()                        // NEW — install menu bar icon
        NSApp.setActivationPolicy(.accessory)
        NSLog("[Sidekick] launched")

        // One-shot move of legacy ~/Documents/Sidekick/ → ~/Library/Application Support/Sidekick/.
        // Must run BEFORE NoteStore init so the path resolution below sees the migrated location.
        StorageLocation.migrateDefaultLocationIfNeeded()

        // NoteStore root: read from UserDefaults if set, otherwise the App Support default.
        // `--debug-notes-folder` (DebugHarness) wins for this process only —
        // never persisted, so a harness run can't touch the real notes.
        let configuredPath = Defaults.store.string(forKey: Defaults.notesFolder)
        var folder: URL = (configuredPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
            ?? StorageLocation.defaultNotesFolder
        #if DEBUG
        if let override = DebugHarness.notesFolderOverride { folder = override }
        #endif
        do {
            let s = try NoteStore(folder: folder)
            self.store = s
            panelController.store = s              // inject BEFORE first toggle()
            Task.detached { await s.reload() }     // CONTEXT.md: detached Task (NoteStore.reload is @MainActor)
            NSLog("[Sidekick] NoteStore initialised at \(folder.path)")

            // Only register the hotkey if the store is available — toggle()
            // requires a non-nil store (IN-01). Without this guard, a hotkey
            // press after NoteStore init failure would reach a nil store and
            // trigger the fatalError in PanelController.makePanel.
            hotkeyManager.onPress = { [weak self] in
                self?.panelController.toggle()
            }
            let ok = hotkeyManager.register()
            if !ok {
                NSLog("[Sidekick] failed to register ⌃⌥⌘N — is another app claiming it?")
            }
        } catch {
            NSLog("[Sidekick] NoteStore init failed: \(error.localizedDescription) — hotkey not registered")
        }

        #if DEBUG
        if let port = DebugHarness.port {
            let harness = DebugHarness(app: self)
            harness.start(port: port)
            debugHarness = harness
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Write the open notes' pending saves before exiting; replying later keeps
        // the app alive until they have landed.
        guard let store else { return .terminateNow }
        // A title still being typed is committed (renamed) first: ending the edit fires the title field's commit.
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { @MainActor in
            await store.flushOpenNotes()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }

    // MARK: - Menu action helpers (Phase 8 D-R-03)

    /// Walk the view hierarchy rooted at `view` to find the editor's text view.
    private func findEditor(in view: NSView?) -> NoteTextView? {
        guard let view = view else { return nil }
        if let tv = view as? NoteTextView { return tv }
        for subview in view.subviews {
            if let tv = findEditor(in: subview) { return tv }
        }
        return nil
    }

    /// Test seam: the text view the Format actions and their validation use instead of the one in the panel.
    internal var formatTargetOverride: (() -> NoteTextView?)?

    /// The text view the Format actions edit: the panel's editor, or the test seam's.
    private func formatTarget() -> NoteTextView? {
        if let override = formatTargetOverride { return override() }
        guard let panel = panelController.panel else { return nil }
        return findEditor(in: panel.contentView)
    }

    // MARK: - Menu actions (Phase 8 D-R-01)

    /// File > New Note (⌘N). MENU-01. Creates a note via the same path as
    /// the sidebar "+" button (SidebarView.swift:43-52) and selects it.
    @objc func newNote(_ sender: Any?) {
        guard let store = self.store else { return }
        Task { @MainActor in
            do {
                let note = try await store.create()
                panelController.panelState.selectedNoteID = note.id
            } catch {
                NSLog("[Sidekick] menu newNote failed: \(error.localizedDescription)")
            }
        }
    }

    /// File > Reload Notes (⌘R). KBD-02. Mirrors the existing sidebar-footer
    /// refresh button (SidebarView.swift:62-64).
    @objc func reloadNotes(_ sender: Any?) {
        guard let store = self.store else { return }
        Task { @MainActor in
            await store.reload()
        }
    }

    /// Status-bar > Toggle Sidekick Panel. Invokes the SAME code path as the
    /// ⌃⌥⌘N hotkey (HotkeyManager.onPress -> panelController.toggle).
    /// Do NOT add any NSApp activation-policy manipulation here —
    /// panelController.toggle() already handles the .accessory ↔ .regular flip
    /// in slideIn (line 174) and slideOut's completion (line 205).
    @objc func toggleSidekickPanel(_ sender: Any?) {
        panelController.toggle()
    }

    /// Note > Pin/Unpin (no shortcut). MENU-04. Single dynamic item — the
    /// title is flipped between "Pin" and "Unpin" inside
    /// validateUserInterfaceItem based on the selected note's pinned state
    /// (D-U-02). Action body toggles the pinned flag via store.setPinned.
    @objc func pinToggle(_ sender: Any?) {
        guard let store = self.store,
              let id = panelController.panelState.selectedNoteID,
              let note = store.notes.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            try? await store.setPinned(id, !note.pinned)
        }
    }

    /// Note > Delete (no shortcut — D-M-06 prevents keyboard accidents).
    /// MENU-04 + D-U-03. Routes through store.delete → macOS Trash
    /// (recoverable). Mirrors NoteRowView.contextMenu Delete (Sources/Sidekick/NoteRowView.swift:97-106).
    @objc func deleteNote(_ sender: Any?) {
        guard let store = self.store,
              let id = panelController.panelState.selectedNoteID else { return }
        let successor = NoteRowFormatting.successorID(afterDeleting: id, in: store.notes)
        Task { @MainActor in
            try? await store.delete(id)
            panelController.panelState.selectedNoteID = successor
        }
    }

    // Format actions: each hands one command to the editor view, which changes the note document
    // (`NoteTextView.perform(_:)`). Heading shortcuts toggle: the same level again gives back a body line.

    /// Format action (⌘B).
    @objc func formatBold(_ sender: Any?) { formatTarget()?.perform(.bold) }

    /// Format action (⌘I).
    @objc func formatItalic(_ sender: Any?) { formatTarget()?.perform(.italic) }

    /// Format action (⌘⌥C).
    @objc func formatInlineCode(_ sender: Any?) { formatTarget()?.perform(.code) }

    /// Format action (⌘U).
    @objc func formatUnderline(_ sender: Any?) { formatTarget()?.perform(.underline) }

    /// Format action (⌘⇧X).
    @objc func formatStrikethrough(_ sender: Any?) { formatTarget()?.perform(.strikethrough) }

    /// Format action (⌘⇧8).
    @objc func formatBulletedList(_ sender: Any?) { formatTarget()?.perform(.bullet) }

    /// Format action (⌘⌥1).
    @objc func formatHeading1(_ sender: Any?) { formatTarget()?.perform(.heading(1)) }

    /// Format action (⌘⌥2).
    @objc func formatHeading2(_ sender: Any?) { formatTarget()?.perform(.heading(2)) }

    /// Format action (⌘⌥3).
    @objc func formatHeading3(_ sender: Any?) { formatTarget()?.perform(.heading(3)) }

    /// Format action (⌘⌥0).
    @objc func formatHeadingBody(_ sender: Any?) { formatTarget()?.perform(.heading(nil)) }

    /// Format action (⌘⇧7).
    @objc func formatNumberedList(_ sender: Any?) { formatTarget()?.perform(.numbered) }

    /// Format action (⌘⇧9).
    @objc func formatBlockQuote(_ sender: Any?) { formatTarget()?.perform(.quote) }

    /// Format action (⌘⇧L).
    @objc func formatChecklist(_ sender: Any?) { formatTarget()?.perform(.checklist) }

    /// Format > Link (⌘K): asks for the address in a field over the selection.
    @objc func formatLink(_ sender: Any?) { formatTarget()?.beginLinkEdit() }

    /// App > About Sidekick (D-M-02). Uses the stock AppKit about panel,
    /// which reads CFBundleShortVersionString + CFBundleVersion from
    /// Info.plist (build-and-run.sh:38-67 already writes both keys).
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

// MARK: - Menu item validation (Phase 8 D-V-01..06)

/// AppKit re-polls `validateUserInterfaceItem(_:)` on every menu open AND
/// before dispatching a keyboard shortcut — one method handles both menu UI
/// gating and ⌘-key gating (RESEARCH Pattern 2). Rules per CONTEXT D-V-01..06:
///
///   - File > New Note / Reload Notes:           enable iff panel visible              (D-V-05, D-U-01)
///   - Format > Bold / Italic / Code / Link:      enable iff editor is first responder (D-V-02)
///   - Note > Pin/Unpin + Delete:                 enable iff note selected             (D-V-04)
///   - Pin/Unpin also mutates item.title (D-U-02): "Pin" or "Unpin" based on pinned state
///   - Default (Edit submenu nil-target items):   return true — NSText/NSTextView handles its own validation
extension AppDelegate: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return false }
        let panel = panelController.panel
        let panelVisible = panel?.isVisible == true
        let editorFocused: Bool
        if let target = formatTargetOverride?() {
            editorFocused = target.window?.firstResponder === target
        } else {
            editorFocused = (NSApp.keyWindow === panel) && (panel?.firstResponder is NSTextView)
        }
        let hasSelection = panelController.panelState.selectedNoteID != nil

        switch action {
        case #selector(newNote(_:)),
             #selector(reloadNotes(_:)):
            return panelVisible                                   // D-V-05 + D-U-01

        case #selector(toggleSidekickPanel(_:)),
             #selector(openSettings(_:)):
            return true                    // always enabled — status bar must work whether panel is open or closed

        case #selector(formatBold(_:)),
             #selector(formatItalic(_:)),
             #selector(formatUnderline(_:)),
             #selector(formatStrikethrough(_:)),
             #selector(formatInlineCode(_:)),
             #selector(formatLink(_:)),
             #selector(formatBulletedList(_:)),
             #selector(formatNumberedList(_:)),
             #selector(formatBlockQuote(_:)),
             #selector(formatChecklist(_:)),
             #selector(formatHeading1(_:)),
             #selector(formatHeading2(_:)),
             #selector(formatHeading3(_:)),
             #selector(formatHeadingBody(_:)):
            return editorFocused                                  // D-V-02

        case #selector(pinToggle(_:)):
            // D-U-02 dynamic title flip inside validation — Apple-documented
            // use of validateMenuItem ("good place to toggle titles or set
            // state on menu items" — Enabling Menu Items archive doc).
            if let menuItem = item as? NSMenuItem,
               let id = panelController.panelState.selectedNoteID,
               let note = self.store?.notes.first(where: { $0.id == id }) {
                menuItem.title = note.pinned ? "Unpin" : "Pin"
            }
            return hasSelection                                   // D-V-04

        case #selector(deleteNote(_:)):
            return hasSelection                                   // D-V-04

        default:
            // Edit submenu (Undo/Redo/Cut/Copy/Paste/Select All) uses
            // nil-target + responder-chain dispatch; their validation lives
            // on NSText/NSTextView. Returning true here keeps them enabled
            // by default; Cocoa's own validation disables them when the
            // responder chain doesn't support the action.
            return true
        }
    }
}


extension AppDelegate {
    /// Edit > Find: the editor's find bar (⌘F), next and previous match (⌘G, ⇧⌘G), and Use Selection for Find (⌘E).
    /// Each item sends performFindPanelAction: down the responder chain; its tag names the NSTextFinder action.
    static func makeFindMenuItem() -> NSMenuItem {
        let findMenu = NSMenu(title: "Find")
        // Command-Shift-G would also match Find Next; PlainCommandMenu sends it to Find Previous.
        let entries: [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
            ("Find…", "f", [.command], .showFindInterface),
            ("Find Next", "g", [.command], .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", [.command], .setSearchString),
        ]
        for (title, key, mods, action) in entries {
            let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = action.rawValue
            findMenu.addItem(item)
        }
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findMenu
        return findItem
    }
}

/// The Edit menu answers Command plus a letter only. AppKit also matches Command-Shift-X, -C, -V and -A to the plain
/// items (their key equivalent is lowercase), and Edit comes before Format, so Command-Shift-X cut text instead of
/// reaching Format > Strikethrough. With Shift held the Edit menu declines, except for Redo (Command-Shift-Z) and
/// Find Previous (Command-Shift-G). AppKit would match Command-Shift-G to Find Next (Command-G), which comes first, so
/// this menu sends it to Find Previous itself.
final class PlainCommandMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.shift) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": break
            case "g": return findPrevious()
            default: return false
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func findPrevious() -> Bool {
        let tag = NSTextFinder.Action.previousMatch.rawValue
        guard let item = items.lazy.compactMap({ $0.submenu?.items.first { $0.tag == tag } }).first,
              let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
}
