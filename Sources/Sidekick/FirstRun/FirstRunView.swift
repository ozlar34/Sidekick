import SwiftUI

/// The content of the welcome window. It only shows values it is given, so the window controller decides what is live.
struct FirstRunView: View {
    /// The current global shortcut as text (for example "⌃⌥⌘N"), or nil when none is set.
    let shortcut: String?
    let folderPath: String
    let onShowFolder: () -> Void
    let onOpenSettings: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hi, welcome to Sidekick!").font(.title2.weight(.semibold))
                Text("Your notes are always one keystroke away.").foregroundStyle(.secondary)
            }

            section(title: shortcut.map { "Summon it: \($0)" } ?? "Summon it from the menu bar icon") {
                Text(shortcut == nil
                     ? "No shortcut is set. Choose one in Settings."
                     : "Works from any app. Press again to hide. Prefer another key? Change it in Settings.")
            }

            section(title: "Your notes") {
                Text(folderPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                Text("Every note is a plain .md file you own.")
                Button("Show in Finder", action: onShowFolder)
            }

            section(title: "Settings") {
                Text("⌘, or the gear in the panel.")
            }

            HStack {
                Spacer()
                Button("Open Settings", action: onOpenSettings)
                Button("Start writing", action: onStart).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
