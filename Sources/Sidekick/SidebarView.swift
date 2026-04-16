import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: NoteStore
    @State private var selectedID: UUID?

    private var selectedNote: Note? {
        guard let id = selectedID else { return nil }
        return store.notes.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — 140pt, vibrancy via ZStack
            ZStack {
                VisualEffectBackground()
                VStack(spacing: 0) {
                    HStack {
                        Text("Notes")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    NoteListView(store: store, selectedID: $selectedID)

                    Divider()

                    HStack {
                        Button {
                            Task { @MainActor in
                                let note = await store.create()
                                selectedID = note.id
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .help("New Note")

                        Spacer()

                        Button(action: {
                            (NSApp.delegate as? AppDelegate)?.openSettings()
                        }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .help("Settings")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .frame(width: 140)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(.separatorColor))
                    .frame(width: 1)
            }

            // Editor — plain opaque background
            Group {
                if let note = selectedNote {
                    EditorPaneView(store: store, note: note, selectedID: $selectedID)
                } else {
                    VStack(spacing: 24) {
                        Text("No Notes Yet")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("Press + to create your first note.")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.textBackgroundColor))
                }
            }
        }
    }
}
