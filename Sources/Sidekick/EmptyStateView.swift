import SwiftUI

/// What the panel shows where there is nothing to show (no notes, no note selected, no search matches): a symbol, a
/// title, one line on what to do, and optionally one button that does it. One view, so the three look alike.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var action: (label: String, perform: () -> Void)? = nil
    /// Smaller symbol and spacing, near the top: for the sidebar's narrow column.
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 22 : 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, compact ? 2 : 4)
            Text(title)
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.label, action: action.perform)
                    .controlSize(.small)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        // Compact sits near the top, close to what caused it (the search field); the full size is centred.
        .padding(.top, compact ? 40 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .top : .center)
    }
}
