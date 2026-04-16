/// Standalone NSWindow hosting the SwiftUI SettingsView.
///
/// Pattern sources:
///   - RESEARCH.md §Pattern 4 (Settings NSWindow)
///   - RESEARCH.md Pitfall 4 (isReleasedWhenClosed = false)
///   - CONTEXT.md: S-02 (standalone NSWindow, not popover/sheet)
///   - PanelController.swift (analog — both own an NSWindow hosting SwiftUI via NSHostingView)
import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidekick Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating // ensures Settings stays above the floating SidekickPanel but below system alerts
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        self.init(window: window)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("[Sidekick] Settings window shown")
    }
}
