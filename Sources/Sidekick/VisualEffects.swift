import AppKit
import SwiftUI

/// Bridges `NSVisualEffectView` into SwiftUI for the sidebar pane background.
/// `.sidebar` material + `.behindWindow` blending — matches Notes / Mail and
/// gives the panel a saturated, sidebar-native feel rather than the more
/// translucent `.underWindowBackground` that lets the desktop bleed through.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        v.alphaValue = 1.0
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
