import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: NoteStore
    let note: Note
    @Binding var selectedID: UUID?

    @State private var localBody: String = ""
    @State private var debouncer = Debouncer(interval: 0.5)
    @FocusState private var editorFocused: Bool
    @Environment(\.setDocumentEdited) private var setDocumentEdited

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $localBody)
                .focused($editorFocused)
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .onChange(of: localBody) { _, newValue in
                    scheduleAutoSave(body: newValue)
                }

            if localBody.isEmpty {
                Text("Start writing...")
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .padding(.leading, 13)   // TextEditor internal inset (~5pt) + 8pt outer pad
                    .padding(.top, 16)        // TextEditor internal inset (~8pt) + 8pt outer pad
                    .allowsHitTesting(false)
            }
        }
        .background(Color(.textBackgroundColor))
        .onAppear {
            localBody = note.body
            focusEditorAfterDelay()
        }
        .onChange(of: note.id) { _, _ in
            localBody = note.body
            focusEditorAfterDelay()
        }
        .task(id: note.id) {
            await consumeExternalChanges()
        }
    }

    // MARK: - Auto-save (STORE-05, EDIT-04, EDIT-05)

    private func scheduleAutoSave(body: String) {
        // Immediate unsaved indicator (EDIT-05)
        setDocumentEdited(true)

        let id = note.id
        let editedSetter = setDocumentEdited
        let storeRef = store
        Task {
            await debouncer.schedule {
                try? await storeRef.update(id, body: body)
                await MainActor.run {
                    editedSetter(false)
                }
            }
        }
    }

    // MARK: - Auto-focus (RESEARCH Pitfall 2: 50ms delay required)

    private func focusEditorAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            editorFocused = true
        }
    }

    // MARK: - External changes (CONTEXT.md: silent reload, no banner in Phase 3)

    private func consumeExternalChanges() async {
        for await event in store.externalChanges {
            if case .externalModification(let ids) = event,
               ids.contains(note.id),
               let updated = store.notes.first(where: { $0.id == note.id }) {
                localBody = updated.body
            }
        }
    }
}
