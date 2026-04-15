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
                        NoteRowView(note: note, store: store)
                            .tag(note.id)
                    }
                }
            }
            Section("Notes") {
                ForEach(regularNotes) { note in
                    NoteRowView(note: note, store: store)
                        .tag(note.id)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)   // RESEARCH Pitfall 5 — let sidebar vibrancy show through
    }
}
