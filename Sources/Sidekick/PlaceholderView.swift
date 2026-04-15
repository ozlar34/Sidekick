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

