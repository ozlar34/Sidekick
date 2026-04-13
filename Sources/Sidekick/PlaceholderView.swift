import AppKit
import SwiftUI

/// Trivial SwiftUI view proving `NSHostingView` bridges correctly inside
/// `SidekickPanel`. Phase 1 surface only — real UI lands in Phase 3.
struct PlaceholderView: View {
    var body: some View {
        ZStack {
            // Subtle vibrancy so the panel reads as "present" even when empty.
            VisualEffectBackground()
            Text("Sidekick — Phase 1")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thin `NSVisualEffectView` bridge so the placeholder panel has a system
/// background instead of the clear `backgroundColor` set on the panel.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
