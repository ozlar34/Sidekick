import AppKit

/// Borderless, nonactivating, always-on-top `NSPanel` subclass that hosts
/// Sidekick's sliding content. `canBecomeKey` must return `true` so that the
/// local Escape monitor in `PanelController` receives key events; `canBecomeMain`
/// stays `false` so the panel never claims main-window status.
///
/// Pattern source: RESEARCH.md §Pattern 3 / Cindori tutorial / StandingDeskTimer MenuPanel.
final class SidekickPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // required so Escape reaches us
    override var canBecomeMain: Bool { false } // stays a utility window

    /// G-05: nonactivating panels bypass Cocoa's global menu-bar key-equivalent
    /// dispatcher — Cmd+Z / Cmd+Shift+Z / Cmd+Q reach the *previously active*
    /// app's menu bar, not ours. Manually scan NSApp.mainMenu so items like
    /// Undo/Redo/Cut/Copy/Paste/Quit route to our first responder (the
    /// NSTextView inside SwiftUI TextEditor).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false           // required for vibrancy to composite behind the window
        hasShadow = true
        animationBehavior = .none  // we animate frame manually
    }
}
