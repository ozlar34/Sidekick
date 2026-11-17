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
        let hostingView = NSHostingView(rootView: SettingsView())
        window.contentView = hostingView
        // As tall as the form, so all five rows show without scrolling.
        window.setContentSize(hostingView.fittingSize)
        window.center()
        self.init(window: window)
        hostingView.rootView = SettingsView(onHeightChange: { [weak self] in self?.fitToForm() })
    }

    /// Sets the window to the form's height again, keeping its top edge in place. Runs on the next turn of the
    /// main loop, after SwiftUI has laid out the changed form.
    private func fitToForm() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, let content = window.contentView else { return }
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: true)
        }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("[Sidekick] Settings window shown")
    }
}
