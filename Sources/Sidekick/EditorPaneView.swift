import AppKit
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: NoteStore
    let note: Note
    @Binding var selectedID: UUID?

    @State private var localBody: String = ""
    @State private var debouncer = Debouncer(interval: 0.5)
    @FocusState private var editorFocused: Bool
    @Environment(\.setDocumentEdited) private var setDocumentEdited

    // Phase 4 — markdown preview toggle (EDIT-02, D-04)
    @State private var isPreviewMode: Bool = false
    @State private var cursorOffset: Int = 0

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
                    Text("⚠ File changed on disk").font(.body)
                    Spacer()
                    Button("Reload") {
                        Task { await reloadFromDisk() }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.15))
            }

            // Editor / preview content
            ZStack(alignment: .topLeading) {
                if isPreviewMode {
                    MarkdownPreviewView(content: localBody)
                } else {
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

                // Hidden ⌘R carrier — must remain in hierarchy in both modes
                // (RESEARCH Pitfall 4: ScrollView holds focus in preview; ZStack-embedded
                // Button still receives the shortcut). D-03: no visible mode indicator.
                Button("") { togglePreviewMode() }
                    .keyboardShortcut("r", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            .background(Color(.textBackgroundColor))

            // Disk-write failure toast (REL-01) — bottom of editor
            if diskWriteError {
                HStack {
                    Text("Could not save — check disk permissions.").font(.body)
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
            cursorOffset = 0          // reset stale offset on note switch
            isPreviewMode = false     // return to edit mode on note switch
            diskWriteError = false
            focusEditorAfterDelay()
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
                do {
                    try await storeRef.update(id, body: body)
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

    // MARK: - Phase 4 markdown preview toggle (EDIT-02, D-04)

    /// Clamp a UTF-16 cursor offset to the bounds of `body`. D-04 fallback:
    /// when cursorOffset is out of range (e.g. note body shrank externally),
    /// return `body.utf16.count` (end of document). NSRange.location is in
    /// UTF-16 code units, so we MUST use `utf16.count` not `count`
    /// (RESEARCH Pitfall 2 + Open Question 2).
    internal static func clampOffset(_ offset: Int, in body: String) -> Int {
        let upper = body.utf16.count
        if offset < 0 { return 0 }
        if offset > upper { return upper }
        return offset
    }

    private func captureCursorOffset() {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        cursorOffset = tv.selectedRange().location
    }

    private func restoreCursorOffset() {
        // 50ms delay — matches focusEditorAfterDelay; gives SwiftUI time to re-mount
        // the TextEditor and AppKit responder chain to settle (RESEARCH Pitfall 3).
        Task { @MainActor in
            editorFocused = true
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let safeOffset = EditorPaneView.clampOffset(cursorOffset, in: localBody)
            tv.setSelectedRange(NSRange(location: safeOffset, length: 0))
        }
    }

    private func togglePreviewMode() {
        if isPreviewMode {
            isPreviewMode = false
            restoreCursorOffset()
        } else {
            captureCursorOffset()
            isPreviewMode = true
        }
    }
}
