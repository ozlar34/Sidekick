import AppKit
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var panelState: PanelState
    let note: Note
    @Binding var selectedID: UUID?

    @State private var localTitle: String = ""
    @State private var localBody: String = ""
    @State private var debouncer = Debouncer(interval: 0.5)
    @FocusState private var focus: EditorField?
    @Environment(\.setDocumentEdited) private var setDocumentEdited

    private enum EditorField: Hashable { case title, body }

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

            // Header chrome: title + formatting toolbar grouped on a slightly
            // tinted surface (controlBackgroundColor) so they read as one
            // input zone distinct from the writing area below. A hairline
            // Divider closes off the zone — Mac-native treatment that frames
            // the orphaned "Aa" button without visually shouting.
            VStack(spacing: 0) {
                // Title field — discrete, replaces the v1.2 first-line auto-H1.
                // Padding aligns horizontally with the editor's textContainerInset
                // (20pt h, HybridEditorView.swift) so the title and body text
                // share a left edge.
                TextField("Untitled", text: $localTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focusBody() }
                    .onKeyPress(.tab) {
                        focusBody()
                        return .handled
                    }
                    .onChange(of: localTitle) { _, newValue in
                        scheduleAutoSave(title: newValue, body: localBody)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                // Formatting toolbar (P7-TOOL-01, P7-TOOL-02).
                FormattingToolbarView(
                    wrapSelection: wrapSelection,
                    applyLinePrefix: applyLinePrefix,
                    applyHeading: applyHeadingLevel,
                    applyNumberedList: applyNumberedList,
                    applyBlockQuote: applyBlockQuote,
                    activeInlineKind: editorController.activeInlineKind,
                    activeHeadingLevel: editorController.activeHeadingLevel
                )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .background(Color(.controlBackgroundColor))

            Divider()

            // Editor content — hybrid editor is the only surface (Phase 11 REMOVE-03/04)
            HybridEditorView(text: $localBody, controller: editorController)
                .onChange(of: localBody) { _, newValue in
                    scheduleAutoSave(title: localTitle, body: newValue)
                }
                .background(Color(.textBackgroundColor))

            // Disk-write failure toast (REL-01) — bottom of editor
            if diskWriteError {
                HStack {
                    Text("Could not save — check disk permissions.").font(.system(size: 13))
                    Spacer()
                    Button("Retry") {
                        diskWriteError = false
                        scheduleAutoSave(title: localTitle, body: localBody)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color(.controlBackgroundColor))
                .shadow(radius: 4)
            }
        }
        .onAppear {
            localTitle = note.title
            localBody = note.body
            seedFocusForCurrentNote()
        }
        .onChange(of: note.id) { _, _ in
            localTitle = note.title
            localBody = note.body
            diskWriteError = false
            seedFocusForCurrentNote()
        }
    }

    // MARK: - Auto-save (STORE-05, EDIT-04, EDIT-05)

    private func scheduleAutoSave(title: String, body: String) {
        // Immediate unsaved indicator (EDIT-05)
        setDocumentEdited(true)

        let id = note.id
        let editedSetter = setDocumentEdited
        let storeRef = store
        Task {
            await debouncer.schedule {
                do {
                    try await storeRef.update(id, title: title, body: body)
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

    // MARK: - Focus management

    /// Pick the right starting field for the freshly-mounted note. Empty
    /// notes (newly-created via ⌘N) get title focus so the user can type a
    /// name immediately; otherwise let AppKit hand first-responder to the
    /// NSTextView naturally — no SwiftUI focus needed.
    private func seedFocusForCurrentNote() {
        if note.title.isEmpty && note.body.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focus = .title
            }
        }
    }

    /// Hand off from the SwiftUI title field to the AppKit body editor.
    /// Releases SwiftUI focus first so .focused() doesn't fight AppKit's
    /// makeFirstResponder.
    private func focusBody() {
        focus = nil
        if let tv = editorController.textView {
            tv.window?.makeFirstResponder(tv)
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

    /// Toolbar-dropdown bridge for the heading-level picker. `level` is
    /// `nil` for Body or `1…3` for the heading levels offered by the
    /// dropdown. Toggle-off (re-pick same level → strip) is handled
    /// inside `applyHeadingLevel` / `performHeadingLevel`.
    private func applyHeadingLevel(level: Int?) {
        guard let tv = editorController.textView else { return }
        FormattingToolbarView.performHeadingLevel(in: tv, level: level)
    }

    /// Toolbar-popover bridge for the numbered-list toggle (⌘⇧7 equivalent).
    /// Mirrors `applyLinePrefix` exactly — same routing pattern.
    private func applyNumberedList() {
        guard let tv = editorController.textView else { return }
        FormattingToolbarView.performNumberedList(in: tv)
    }

    /// Toolbar-popover bridge for the block-quote toggle (⌘⇧9 equivalent).
    private func applyBlockQuote() {
        guard let tv = editorController.textView else { return }
        FormattingToolbarView.performBlockQuote(in: tv)
    }

}
