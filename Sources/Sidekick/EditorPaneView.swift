import AppKit
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var panelState: PanelState
    let note: Note
    @Binding var selectedID: UUID?

    @State private var localBody: String = ""
    @State private var debouncer = Debouncer(interval: 0.5)
    @FocusState private var editorFocused: Bool
    @Environment(\.setDocumentEdited) private var setDocumentEdited

    // Phase 10 — controller bridge: publishes NSTextView ref from HybridEditorView
    // so toolbar callbacks can call FormattingToolbarView.performWrap(in:) directly
    // (D-TB-02, D-TB-03, D-TB-04).
    @StateObject private var editorController = HybridEditorController()

    // Phase 5 plan 03 — external-edit banner + disk-write toast (STORE-07, REL-01)
    // Banner state is derived from store.externallyChangedIDs (WR-06): a single
    // long-lived @Published Set on NoteStore means we don't miss events across
    // note switches or while the editor is unmounted (empty state).
    @State private var diskWriteError: Bool = false

    private var showExternalChangeBanner: Bool {
        store.externallyChangedIDs.contains(note.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // External-edit banner (STORE-07) — top of editor
            if showExternalChangeBanner {
                HStack {
                    Text("⚠ File changed on disk").font(.system(size: 13))
                    Spacer()
                    Button("Reload") {
                        Task { await reloadFromDisk() }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.15))
            }

            // Formatting toolbar (P7-TOOL-01, P7-TOOL-02). Matches the editor's
            // textBackground so toolbar + editor read as one continuous surface
            // — no hairline divider needed.
            FormattingToolbarView(
                wrapSelection: wrapSelection,
                applyLinePrefix: applyLinePrefix,
                activeInlineKind: editorController.activeInlineKind
            )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.textBackgroundColor))

            // Editor content — hybrid editor is the only surface (Phase 11 REMOVE-03/04)
            HybridEditorView(text: $localBody, controller: editorController)
                .onChange(of: localBody) { _, newValue in
                    scheduleAutoSave(body: newValue)
                }
                .background(Color(.textBackgroundColor))

            // Disk-write failure toast (REL-01) — bottom of editor
            if diskWriteError {
                HStack {
                    Text("Could not save — check disk permissions.").font(.system(size: 13))
                    Spacer()
                    Button("Retry") {
                        diskWriteError = false
                        scheduleAutoSave(body: localBody)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color(.controlBackgroundColor))
                .shadow(radius: 4)
            }
        }
        .onAppear {
            localBody = note.body
            focusEditorAfterDelay()
        }
        .onChange(of: note.id) { _, _ in
            localBody = note.body
            diskWriteError = false
            focusEditorAfterDelay()
        }
    }

    // MARK: - Auto-save (STORE-05, EDIT-04, EDIT-05)

    private func scheduleAutoSave(body: String) {
        // Immediate unsaved indicator (EDIT-05)
        setDocumentEdited(true)

        let id = note.id
        let noteTitle = note.title
        let editedSetter = setDocumentEdited
        let storeRef = store
        Task {
            await debouncer.schedule {
                do {
                    try await storeRef.update(id, title: noteTitle, body: body)
                    await MainActor.run { editedSetter(false) }
                } catch {
                    NSLog("[Sidekick] autosave failed: \(error.localizedDescription)")
                    await MainActor.run {
                        diskWriteError = true
                        editedSetter(false)
                    }
                    // IN-03: Fire-and-forget auto-dismiss outside the
                    // debouncer's cancellable chain. If the user types again
                    // or hits Retry within 5s, the debouncer cancels the
                    // active schedule — we do NOT want that cancellation to
                    // throw out of Task.sleep and clear the flag prematurely.
                    // A detached @MainActor task is immune to debouncer reset.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        diskWriteError = false
                    }
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

    // MARK: - External changes (Phase 5: banner trigger instead of silent reload)

    private func reloadFromDisk() async {
        await store.reloadNote(id: note.id)
        if let updated = store.notes.first(where: { $0.id == note.id }) {
            localBody = updated.body
        }
        store.acknowledgeExternalChange(id: note.id)
    }

    // MARK: - Phase 7 formatting toolbar (P7-TOOL-01, P7-TOOL-02)

    /// Bridge from FormattingToolbarView button taps to the editor's NSTextView.
    ///
    /// Routes through `editorController.textView` → `FormattingToolbarView.performWrap`
    /// (D-TB-01). All three surfaces (toolbar button, Format menu, ⌘B shortcut)
    /// converge on the same `performWrap` call — no $localBody mutation or
    /// DispatchQueue.main.async cursor-restore dance needed (Phase 10 unification).
    private func wrapSelection(prefix: String, suffix: String) {
        guard let tv = editorController.textView else { return }
        FormattingToolbarView.performWrap(prefix: prefix, suffix: suffix, in: tv)
    }

    /// Toolbar-button bridge for the bulleted-list toggle (⌘⇧8 equivalent).
    ///
    /// Routes through `editorController.textView` → `FormattingToolbarView.performLinePrefix`
    /// (D-TB-01). Mirrors the wrapSelection simplification — no $localBody mutation
    /// or DispatchQueue dance needed (Phase 10 unification).
    private func applyLinePrefix() {
        guard let tv = editorController.textView else { return }
        FormattingToolbarView.performLinePrefix(in: tv)
    }

}
