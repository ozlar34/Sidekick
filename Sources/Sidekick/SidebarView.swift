import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: NoteStore
    @State private var selectedID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            NoteListView(store: store, selectedID: $selectedID)
                .navigationSplitViewColumnWidth(min: 140, ideal: 140, max: 140)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { @MainActor in
                                let note = await store.create()
                                selectedID = note.id
                            }
                        } label: {
                            Label("New Note", systemImage: "plus")
                        }
                        .help("New Note")
                    }
                }
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if let id = selectedID,
               store.notes.first(where: { $0.id == id }) != nil {
                // Plan 02 replaces this stub with EditorPaneView(store:note:selectedID:)
                Text("Editor pane — wired in Plan 02")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.textBackgroundColor))
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
