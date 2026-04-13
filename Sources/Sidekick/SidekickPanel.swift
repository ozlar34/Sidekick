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
        hasShadow = true
        animationBehavior = .none  // we animate frame manually
    }
}
