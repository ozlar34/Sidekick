import AppKit
import SwiftUI

/// Owns the `SidekickPanel` lifecycle: lazy creation, slide-in/slide-out
/// animation, panel-scoped Escape monitor, and screen-under-cursor anchoring.
///
/// Pattern sources:
///   - RESEARCH.md §Slide-In Animation / §Screen-Under-Cursor Frame / §Escape Handler
///   - StandingDeskTimer/Sources/StandingDeskTimer/AppDelegate.swift:332-338 (NSHostingView)
///   - StandingDeskTimer/Sources/StandingDeskTimer/AppDelegate.swift:374-390 (Escape monitor)
///
/// IN-07: `@MainActor`-isolated because `toggle()`, `resizePanel(to:)`,
/// `saveWidth()`, `slideIn(to:)`, and `installDismissHandlers()` all touch
/// `NSPanel` / `NSEvent` / `NSAnimationContext`, which must run on the main
/// thread. KeyboardShortcuts delivers callbacks on main today, so this works
/// in practice — the annotation makes it a compile-time guarantee and will
/// reject future misuse (e.g. calls from `Task.detached`).
@MainActor
final class PanelController {

    private(set) var panel: SidekickPanel?
    var store: NoteStore?
    let panelState = PanelState()
    private var escMonitor: Any?
    private var outsideClickMonitor: Any?

    var panelWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: Defaults.panelWidth)
        let raw = saved > 0 ? saved : 380
        return max(260, min(560, raw))
    }()
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
        installDismissHandlers()
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

    /// Pure helper extracted for unit testing (see OffScreenFrameTests).
    /// Returns the x-coordinate where the panel must start/end to be
    /// fully off-screen to the right of the target screen. Identity
    /// function on `targetScreenMaxX` — the value IS the answer. The
    /// point of the extraction is to pin the contract that we use
    /// `targetScreen.frame.maxX` (the physical edge) not
    /// `visibleFrame.maxX` or the input frame's maxX.
    internal nonisolated static func offScreenX(targetScreenMaxX: CGFloat) -> CGFloat {
        targetScreenMaxX
    }

    /// Just off the right edge of ALL screens — used as slide-in start and slide-out end.
    ///
    /// Multi-monitor correctness (P7-BUG-01): The start x must be beyond every
    /// connected display's right edge. Using only the target screen's `frame.maxX`
    /// is insufficient — when the target is not the rightmost display, `frame.maxX`
    /// is the LEFT edge of the next monitor, so the panel starts visibly on the
    /// neighbor. Taking the global max across all screens guarantees the panel
    /// is off-screen on every display before the animation begins.
    private func offScreenFrame(for frame: NSRect) -> NSRect {
        let rightmostX = NSScreen.screens.map { $0.frame.maxX }.max()
                       ?? NSScreen.main?.frame.maxX
                       ?? frame.maxX
        let offX = PanelController.offScreenX(targetScreenMaxX: rightmostX)
        return NSRect(x: offX,
                      y: frame.origin.y,
                      width: frame.width,
                      height: frame.height)
    }

    // MARK: - Panel construction

    private func makePanel() -> SidekickPanel {
        let initialFrame = anchoredFrame()
        let panel = SidekickPanel(contentRect: initialFrame)

        // IN-01: AppDelegate only registers the hotkey when the NoteStore is
        // non-nil, so this precondition is enforced at app startup. The
        // fatalError message is sufficient for crash-log diagnosis; the prior
        // NSLog was dead text that never appeared outside of the crash trace.
        guard let store = self.store else {
            fatalError("PanelController.store must be set before toggle() is invoked")
        }

        let rootView = SidebarView(store: store, panelState: panelState)
            .environment(\.setDocumentEdited) { [weak panel] edited in
                panel?.isDocumentEdited = edited
            }

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        return panel
    }

    // MARK: - Resize API

    /// Resizes the panel live, keeping the right edge anchored.
    /// Width is clamped to [260, 560] per CONTEXT.md P-04.
    func resizePanel(to newWidth: CGFloat) {
        guard let panel else { return }
        let clamped = max(260, min(560, newWidth))
        var f = panel.frame
        let rightEdge = f.maxX
        f.origin.x = rightEdge - clamped
        f.size.width = clamped
        panel.setFrame(f, display: true)
        panelWidth = clamped
    }

    /// Persists the current panel width to UserDefaults.
    /// Call on drag-end so writes are infrequent.
    func saveWidth() {
        guard let panel else { return }
        UserDefaults.standard.set(panel.frame.width, forKey: Defaults.panelWidth)
        NSLog("[Sidekick] panelWidth saved: \(panel.frame.width)")
    }

    // MARK: - Animation

    // Horizontal slide offset for show/hide animation. Small enough that the
    // brief overlap with an adjacent screen happens only at near-zero alpha,
    // making any bleed imperceptible, while still giving a clear right-to-left
    // slide feel.
    private let slideOffset: CGFloat = 20

    private func slideIn(to finalFrame: NSRect) {
        guard let panel else { return }
        let startFrame = NSRect(x: finalFrame.origin.x + slideOffset,
                                y: finalFrame.origin.y,
                                width: finalFrame.width,
                                height: finalFrame.height)
        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        // makeKey() is required so the local Escape monitor fires
        // (RESEARCH.md Pitfall #1).
        panel.makeKey()
        // Activate after the panel is key so the menu bar shows without
        // consuming the panel's first interactive click.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1.0
        }
    }

    private func slideOut() {
        guard let panel, panel.isVisible else { return }
        let endFrame = NSRect(x: panel.frame.origin.x + slideOffset,
                              y: panel.frame.origin.y,
                              width: panel.frame.width,
                              height: panel.frame.height)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1.0  // reset for next appearance
            self?.removeDismissHandlers()
        })
    }

    // MARK: - Dismiss handling (panel-scoped Escape + global outside-click)

    private func installDismissHandlers() {
        // Panel-scoped Escape — unchanged from prior installEscapeHandler().
        if escMonitor == nil {
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

        // G-01: click-outside dismissal. Global monitor only sees events
        // destined for OTHER apps/desktop — any mouse-down it observes is
        // by definition outside the panel, so no inside-click filtering is
        // required. SidekickPanel.hidesOnDeactivate remains false on purpose
        // (HUD UX survives brief clicks into another app to copy text); the
        // explicit monitor is the correct dismissal path for .nonactivatingPanel
        // + .accessory activation policy.
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.slideOut()
            }
        }
    }

    private func removeDismissHandlers() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }
}
