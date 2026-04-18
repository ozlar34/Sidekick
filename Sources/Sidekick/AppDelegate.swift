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

    func openSettings() {
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

        // App submenu — Quit Sidekick (Cmd+Q)
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Sidekick")
        appMenu.addItem(NSMenuItem(
            title: "Quit Sidekick",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

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

        NSApp.mainMenu = mainMenu
        NSLog("[Sidekick] mainMenu installed")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()                          // G-05: must run before any UI is shown
        NSApp.setActivationPolicy(.accessory)
        NSLog("[Sidekick] launched")

        // NoteStore root: read from UserDefaults if set, otherwise ~/Documents/Sidekick/
        let configuredPath = UserDefaults.standard.string(forKey: Defaults.notesFolder)
        let folder: URL = (configuredPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Sidekick")
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
}
