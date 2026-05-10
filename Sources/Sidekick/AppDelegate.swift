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
        let editMenu = NSMenu(title: "Edit")

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
        let configuredPath = UserDefaults.standard.string(forKey: Defaults.notesFolder)
        let folder: URL = (configuredPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
            ?? StorageLocation.defaultNotesFolder
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }

    // MARK: - Menu action helpers (Phase 8 D-R-03)

    /// Walk the view hierarchy rooted at `view` to find the first NSTextView.
    /// Lifted verbatim from EditorPaneView (see Sources/Sidekick/EditorPaneView.swift:211-218).
    /// Duplication is intentional (D-R-03): two call sites, 8 lines, cheaper
    /// than a cross-cutting helper that would force a new file.
    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view = view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for subview in view.subviews {
            if let tv = findTextView(in: subview) { return tv }
        }
        return nil
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

    /// Format > Bold (⌘B). MENU-02. Edits the focused NSTextView via the
    /// shared performWrap helper (D-R-03). Prefix/suffix mirror the toolbar
    /// button at FormattingToolbarView.swift:13-21.
    @objc func formatBold(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
    }

    /// Format > Italic (⌘I). MENU-02.
    @objc func formatItalic(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performWrap(prefix: "*", suffix: "*", in: tv)
    }

    /// Format > Inline Code (⌘⌥C). MENU-02.
    @objc func formatInlineCode(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performWrap(prefix: "`", suffix: "`", in: tv)
    }

    /// Format > Link (⌘K). MENU-02. Mirrors the toolbar button's `[` / `]()`
    /// prefix/suffix at FormattingToolbarView.swift:43-51.
    @objc func formatLink(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: tv)
    }

    /// Format > Bulleted List (⌘⇧8). Apple Notes / Bear convention:
    /// toggles "- " prefix on every line in the selection (or the current
    /// line if selection is empty). Uses the shared line-prefix edit
    /// sandwich (FormattingToolbarView.performLinePrefix) — same responder
    /// discovery as formatBold/Italic/Code/Link.
    @objc func formatBulletedList(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performLinePrefix(in: tv)
    }

    /// Format > Heading 1/2/3 (⌘⌥1/2/3). Pressing the same shortcut while
    /// the caret is already on a line of that level strips the prefix
    /// back to body — handled by `performHeadingLevel`'s toggle rule.
    @objc func formatHeading1(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performHeadingLevel(in: tv, level: 1)
    }

    @objc func formatHeading2(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performHeadingLevel(in: tv, level: 2)
    }

    @objc func formatHeading3(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performHeadingLevel(in: tv, level: 3)
    }

    /// Format > Body (⌘⌥0). Strips any heading prefix from the line(s)
    /// containing the selection. No-op on already-plain lines.
    @objc func formatHeadingBody(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performHeadingLevel(in: tv, level: nil)
    }

    /// Format > Underline (⌘U). Markdown has no native underline syntax;
    /// `<u>...</u>` HTML round-trips through HTML-aware renderers and is
    /// the convention Apple Notes' Markdown export uses too.
    @objc func formatUnderline(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performWrap(prefix: "<u>", suffix: "</u>", in: tv)
    }

    /// Format > Strikethrough (⌘⇧X). GitHub-flavored markdown convention.
    @objc func formatStrikethrough(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performWrap(prefix: "~~", suffix: "~~", in: tv)
    }

    /// Format > Numbered List (⌘⇧7). Sequential numbering across the
    /// selected block; toggle-off when every non-empty line already has
    /// a `<digits>. ` prefix.
    @objc func formatNumberedList(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performNumberedList(in: tv)
    }

    /// Format > Block Quote (⌘⇧9). Mirrors bulleted-list shape with `> `.
    @objc func formatBlockQuote(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performBlockQuote(in: tv)
    }

    /// Format > Checklist (⌘⇧L). Apple Notes parity. Toggles a GFM
    /// task-list (`- [ ] `) prefix on the line(s) containing the selection.
    @objc func formatChecklist(_ sender: Any?) {
        guard let panel = panelController.panel,
              let tv = findTextView(in: panel.contentView) else { return }
        FormattingToolbarView.performChecklist(in: tv)
    }

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
        let editorFocused = (NSApp.keyWindow === panel)
            && (panel?.firstResponder is NSTextView)
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
