import AppKit
import SwiftUI

/// Bridges `NSVisualEffectView` into SwiftUI for the sidebar pane background.
/// Material `.sidebar`, `.behindWindow` blending — see CONTEXT.md theme decision.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        v.alphaValue = 1.0
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
