import SwiftUI

struct NoteListView: View {
    @ObservedObject var store: NoteStore
    @Binding var selectedID: UUID?

    private var pinnedNotes: [Note] { store.notes.filter(\.pinned) }
    private var regularNotes: [Note] { store.notes.filter { !$0.pinned } }

    var body: some View {
        List(selection: $selectedID) {
            if !pinnedNotes.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedNotes) { note in
                        NoteRowView(note: note, store: store, selectedID: $selectedID)
                            .tag(note.id)
                    }
                    .onMove { source, destination in
                        var pinnedIDs = pinnedNotes.map(\.id)
                        pinnedIDs.move(fromOffsets: source, toOffset: destination)
                        let regularIDs = regularNotes.map(\.id)
                        let fullOrder = pinnedIDs + regularIDs
                        Task { try? await store.reorder(fullOrder) }
                    }
                }
            }
            if pinnedNotes.isEmpty {
                ForEach(regularNotes) { note in
                    NoteRowView(note: note, store: store, selectedID: $selectedID)
                        .tag(note.id)
                }
                .onMove { source, destination in
                    var regularIDs = regularNotes.map(\.id)
                    regularIDs.move(fromOffsets: source, toOffset: destination)
                    Task { try? await store.reorder(regularIDs) }
                }
            } else {
                Section("Notes") {
                    ForEach(regularNotes) { note in
                        NoteRowView(note: note, store: store, selectedID: $selectedID)
                            .tag(note.id)
                    }
                    .onMove { source, destination in
                        var regularIDs = regularNotes.map(\.id)
                        regularIDs.move(fromOffsets: source, toOffset: destination)
                        let pinnedIDs = pinnedNotes.map(\.id)
                        let fullOrder = pinnedIDs + regularIDs
                        Task { try? await store.reorder(fullOrder) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)   // RESEARCH Pitfall 5 — let sidebar vibrancy show through
        .animation(.easeInOut(duration: 0.15), value: selectedID)
    }
}
