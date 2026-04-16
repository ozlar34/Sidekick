import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let hotkeyManager = HotkeyManager()
    let panelController = PanelController()
    private var store: NoteStore?
    private var settingsWindowController: SettingsWindowController?

    func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
