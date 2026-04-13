import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSLog("[Sidekick] launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
    }
}
