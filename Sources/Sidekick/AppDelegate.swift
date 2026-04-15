import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let hotkeyManager = HotkeyManager()
    private let panelController = PanelController()
    private var store: NoteStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSLog("[Sidekick] launched")

        // NoteStore root: ~/Documents/Sidekick/ — Phase 3 hardcoded; Phase 5 makes configurable via Settings.
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Sidekick")
        do {
            let s = try NoteStore(folder: folder)
            self.store = s
            panelController.store = s              // inject BEFORE first toggle()
            Task.detached { await s.reload() }     // CONTEXT.md: detached Task (NoteStore.reload is @MainActor)
            NSLog("[Sidekick] NoteStore initialised at \(folder.path)")
        } catch {
            NSLog("[Sidekick] NoteStore init failed: \(error.localizedDescription)")
        }

        hotkeyManager.onPress = { [weak self] in
            self?.panelController.toggle()
        }
        let ok = hotkeyManager.register()
        if !ok {
            NSLog("[Sidekick] failed to register ⌃⌥⌘N — is another app claiming it?")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }
}
