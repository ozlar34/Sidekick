import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let hotkeyManager = HotkeyManager()
    private let panelController = PanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSLog("[Sidekick] launched")

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
