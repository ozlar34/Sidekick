import AppKit
import SwiftUI
import KeyboardShortcuts

/// The one-time welcome window. Any way of leaving it (either button or the close button) marks it as seen.
final class FirstRunWindowController: NSWindowController, NSWindowDelegate {
    private let defaults: UserDefaults

    init(folder: URL, defaults: UserDefaults = .standard,
         openSettings: @escaping () -> Void, startWriting: @escaping () -> Void) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Sidekick"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let view = FirstRunView(
            shortcut: KeyboardShortcuts.getShortcut(for: .togglePanel)?.description,
            folderPath: folder.path,
            onShowFolder: { NSWorkspace.shared.activateFileViewerSelecting([folder]) },
            onOpenSettings: { [weak self] in self?.dismiss(); openSettings() },
            onStart: { [weak self] in self?.dismiss(); startWriting() })
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() { window?.close() }

    func windowWillClose(_ notification: Notification) { FirstRun.markSeen(defaults: defaults) }
}
