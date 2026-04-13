import AppKit
import SwiftUI

/// Owns the `SidekickPanel` lifecycle: lazy creation, slide-in/slide-out
/// animation, panel-scoped Escape monitor, and screen-under-cursor anchoring.
///
/// Pattern sources:
///   - RESEARCH.md §Slide-In Animation / §Screen-Under-Cursor Frame / §Escape Handler
///   - StandingDeskTimer/Sources/StandingDeskTimer/AppDelegate.swift:332-338 (NSHostingView)
///   - StandingDeskTimer/Sources/StandingDeskTimer/AppDelegate.swift:374-390 (Escape monitor)
final class PanelController {

    private(set) var panel: SidekickPanel?
    private var escMonitor: Any?

    private let panelWidth: CGFloat = 380          // CONTEXT.md locks 380pt
    private let slideDuration: TimeInterval = 0.20 // CONTEXT.md locks 200ms

    // MARK: - Public API

    /// Toggles visibility with slide animation. Safe to call from the main
    /// queue (the expected caller is `HotkeyManager.onPress`).
    func toggle() {
        if let panel, panel.isVisible {
            slideOut()
            return
        }
        if panel == nil {
            panel = makePanel()
        }
        // Screens/resolutions may have changed since the last summon —
        // recompute the anchored frame every time.
        let target = anchoredFrame()
        slideIn(to: target)
        installEscapeHandler()
    }

    /// Exposed for downstream tests. True iff `window` is the panel instance.
    func panelIsKey(_ window: NSWindow?) -> Bool {
        window === panel
    }

    // MARK: - Frame math

    private func anchoredFrame() -> NSRect {
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) }
                   ?? NSScreen.main
                   ?? NSScreen.screens[0]

        let visible = screen.visibleFrame  // already accounts for menu bar/dock
        return NSRect(
            x: visible.maxX - panelWidth,
            y: visible.origin.y,
            width: panelWidth,
            height: visible.height
        )
    }

    /// Just off the right edge — used as slide-in start and slide-out end.
    private func offScreenFrame(for frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX, y: frame.origin.y, width: frame.width, height: frame.height)
    }

    // MARK: - Panel construction

    private func makePanel() -> SidekickPanel {
        let initialFrame = anchoredFrame()
        let panel = SidekickPanel(contentRect: initialFrame)

        let hosting = NSHostingView(rootView: PlaceholderView())
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        return panel
    }

    // MARK: - Animation

    private func slideIn(to finalFrame: NSRect) {
        guard let panel else { return }
        let start = offScreenFrame(for: finalFrame)
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        // makeKey() is required so the local Escape monitor fires
        // (RESEARCH.md Pitfall #1).
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    private func slideOut() {
        guard let panel, panel.isVisible else { return }
        let off = offScreenFrame(for: panel.frame)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(off, display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.removeEscapeHandler()
        })
    }

    // MARK: - Escape handling (panel-scoped, local monitor only)

    private func installEscapeHandler() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // keyCode 53 == Escape. Gate on panel identity so we don't swallow
            // Escape elsewhere in the process.
            if event.keyCode == 53, event.window === self?.panel {
                self?.slideOut()
                return nil   // swallow so Escape doesn't leak further
            }
            return event
        }
    }

    private func removeEscapeHandler() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
    }
}
