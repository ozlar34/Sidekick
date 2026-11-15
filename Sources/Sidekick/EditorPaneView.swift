import AppKit
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var panelState: PanelState
    let note: Note
    @Binding var selectedID: UUID?

    @State private var localTitle: String = ""
    @State private var localBody: String = ""
    /// The latest edit whose save has not landed yet (scheduled or in flight).
    private struct PendingEdit: Equatable {
        let id: UUID
        let title: String
        let body: String
    }
    @State private var pendingEdit: PendingEdit?
    @Environment(\.setDocumentEdited) private var setDocumentEdited
    /// New editor only: the open note whose callbacks this pane currently listens to.
    @State private var boundOpenNote: OpenNote?

    // Phase 10 — controller bridge: publishes NSTextView ref from HybridEditorView
    // so toolbar callbacks can call FormattingToolbarView.performWrap(in:) directly
    // (D-TB-02, D-TB-03, D-TB-04).
    @StateObject private var editorController = HybridEditorController()

    // F-10: title is an NSViewRepresentable wrapping NSTextField so we can
    // intercept Tab via NSTextFieldDelegate.control(_:textView:doCommandBy:).
    // SwiftUI's .onKeyPress(.tab) on TextField does not fire on macOS — the
    // underlying NSTextField field editor consumes Tab as `insertTab:` for
    // focus traversal before the SwiftUI modifier sees the key.
    @StateObject private var titleController = TitleFieldController()

    // Phase 5 plan 03 — external-edit banner + disk-write toast (STORE-07, REL-01)
    // Banner state is derived from store.externallyChangedIDs (WR-06): a single
    // long-lived @Published Set on NoteStore means we don't miss events across
    // note switches or while the editor is unmounted (empty state).
    @State private var diskWriteError: Bool = false

    // Tracks whether the open note has unsaved local edits. Mirrors the
    // setDocumentEdited signal already wired through scheduleAutoSave — used to
    // decide external-change handling: silently auto-reload when there's nothing
    // to lose, show the conflict banner only when reloading would clobber edits.
    @State private var hasPendingEdits: Bool = false

    /// True only for a genuine conflict: the file changed on disk AND the user
    /// has unsaved local edits that an auto-reload would discard. The no-pending-
    /// edits case is handled silently by `autoReloadIfSafe()`, so the banner
    /// never appears for it (no transient flash either).
    private var showExternalChangeBanner: Bool {
        store.externallyChangedIDs.contains(note.id) && hasPendingEdits
    }

    /// Footer text below the editor body. "Edited 2:14 PM" — Created date
    /// is intentionally hidden because legacy notes pre-date the field and
    /// filesystem birth time isn't preserved across folder moves.
    private var metadataLine: String {
        guard let edited = note.modified else { return "" }
        return "Edited \(NoteRowFormatting.formattedModifiedTime(edited))"
    }

    /// The old hybrid editor, or the new editor view when `NewEditorSwitch` is on.
    @ViewBuilder private var editorBody: some View {
        if NewEditorSwitch.isOn, let open = store.openNote(note.id) {
            // The open note owns the text: nothing about it passes through view state.
            NoteEditorView(openNote: open, controller: editorController)
        } else {
            HybridEditorView(text: $localBody, controller: editorController)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // External-edit conflict banner (STORE-07) — top of editor. Only
            // shown when the on-disk file changed AND there are unsaved local
            // edits (reloading would discard them). The safe case auto-reloads
            // silently via autoReloadIfSafe(). A closing Divider separates the
            // strip from the title zone so it doesn't crowd the rounded panel top.
            if NewEditorSwitch.isOn, let open = store.openNote(note.id) {
                ConflictBannerView(openNote: open)
            } else if showExternalChangeBanner {
                VStack(spacing: 0) {
                    ExternalChangeBannerContent(
                        reload: { Task { await reloadFromDisk() } },
                        keepMine: {
                            // The old editor has no disk baseline: acknowledging the change and saving
                            // again writes this note's text over the file.
                            store.acknowledgeExternalChange(id: note.id)
                            scheduleAutoSave(title: localTitle, body: localBody)
                        })
                    Divider()
                }
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
                TitleField(
                    text: $localTitle,
                    placeholder: "Untitled",
                    font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                    controller: titleController,
                    onTab: focusBody,
                    onSubmit: focusBody
                )
                    .frame(height: 28)
                    .onChange(of: localTitle) { _, newValue in
                        // Skip the onAppear / note-switch reseed — it would
                        // re-write the same body to disk and bump mtime.
                        guard newValue != note.title else { return }
                        if NewEditorSwitch.isOn {
                            store.openNote(note.id)?.setTitle(newValue)
                            return
                        }
                        scheduleAutoSave(title: newValue, body: localBody)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 2)

                // Formatting toolbar (P7-TOOL-01, P7-TOOL-02). Hidden with the new editor on:
                // its commands rewrite markdown in the buffer, which the new editor does not hold.
                if !NewEditorSwitch.isOn {
                FormattingToolbarView(
                    wrapSelection: wrapSelection,
                    applyLinePrefix: applyLinePrefix,
                    applyHeading: applyHeadingLevel,
                    applyNumberedList: applyNumberedList,
                    applyBlockQuote: applyBlockQuote,
                    applyChecklist: applyChecklist,
                    insertThematicBreak: insertThematicBreak,
                    activeInlineKind: editorController.activeInlineKind,
                    activeHeadingLevel: editorController.activeHeadingLevel,
                    activeLinePrefix: editorController.activeLinePrefix,
                    armedInlineKinds: editorController.armedInlineKinds
                )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .background(Color(.controlBackgroundColor))

            if NewEditorSwitch.isOn, let open = store.openNote(note.id) {
                OpenNoteStatusView(openNote: open)
            }

            // Soft inset shadow at body top — replaces translucent Divider() that bled through panel vibrancy.
            editorBody
                .onChange(of: localBody) { _, newValue in
                    // Skip the onAppear / note-switch reseed — it would
                    // re-write the same body to disk and bump mtime.
                    guard newValue != note.body else { return }
                    scheduleAutoSave(title: localTitle, body: newValue)
                }
                .background(Color(.textBackgroundColor))
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 2)
                    .allowsHitTesting(false)
                }

            // Created / Edited footer — Apple Notes style. Sits inside the
            // editor pane VStack so the scroll view's clip bounds shrink by
            // ~24pt; HybridEditorView.clipFrameChanged adapts automatically.
            HStack {
                Spacer()
                Text(metadataLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Color(.textBackgroundColor))

            // Disk-write failure toast (REL-01) — bottom of editor. A top
            // Divider separates it from the footer, mirroring the external-edit
            // banner treatment at the top of the pane.
            if diskWriteError || (NewEditorSwitch.isOn && !store.failedSaveIDs.isEmpty) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text("Could not save — check disk permissions.").font(.system(size: 13))
                        Spacer()
                        Button("Retry") {
                            diskWriteError = false
                            if NewEditorSwitch.isOn {
                                // Every note whose save failed, not only the one shown.
                                Task { await store.retryFailedSaves() }
                            } else {
                                scheduleAutoSave(title: localTitle, body: localBody)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor))
                }
            }
        }
        .onAppear {
            // Same echo-guard rule as the note-switch path below: the child
            // HybridEditorView may already have mounted (makeNSView) against
            // the still-empty localBody, so the seed we write here reaches
            // updateNSView as a binding change. Without a token bump it is
            // classified as a reflexive echo and DROPPED — the launch-time
            // "note body invisible until you switch notes" bug.
            localTitle = note.title
            if NewEditorSwitch.isOn {
                bindOpenNote()
            } else {
                editorController.externalPushToken += 1
                localBody = note.body
            }
            seedFocusForCurrentNote()
            // Wire Shift-Tab @ body offset 0 → return focus to title.
            // Counterpart to title→body Tab handled by TitleField's delegate.
            editorController.onShiftTabAtBodyStart = { titleController.focus() }
            autoReloadIfSafe()
        }
        .onChange(of: note.id) { _, _ in
            if NewEditorSwitch.isOn {
                // The open notes keep their own text and undo history; switching writes pending saves now.
                let storeRef = store
                Task { await storeRef.flushOpenNotes() }
                localTitle = note.title
                diskWriteError = false
                bindOpenNote()
                seedFocusForCurrentNote()
                autoReloadIfSafe()
                return
            }
            // Save the old note's pending edit now instead of letting the
            // next note's keystrokes replace it in the shared debouncer.
            // An edit for the note we are returning to is kept pending and
            // re-seeded below, since the store's copy may not have caught up.
            let returning = pendingEdit?.id == note.id ? pendingEdit : nil
            if returning == nil {
                let autosave = store.autosave
                Task { await autosave.flush() }
            }
            // EDIT-02 echo guard: bump the push token BEFORE reseeding
            // localBody so HybridEditorView.updateNSView sees the advanced
            // token and classifies the new body as a genuine external push.
            editorController.externalPushToken += 1
            localTitle = returning?.title ?? note.title
            localBody = returning?.body ?? note.body
            diskWriteError = false
            // Freshly-mounted note has no unsaved local edits yet, unless its
            // last edit is still being saved.
            hasPendingEdits = returning != nil
            seedFocusForCurrentNote()
            autoReloadIfSafe()
        }
        .onChange(of: store.externallyChangedIDs) { _, _ in
            autoReloadIfSafe()
        }
    }

    // MARK: - Auto-save (STORE-05, EDIT-04, EDIT-05)

    private func scheduleAutoSave(title: String, body: String) {
        // Immediate unsaved indicator (EDIT-05)
        setDocumentEdited(true)
        hasPendingEdits = true

        let id = note.id
        let edit = PendingEdit(id: id, title: title, body: body)
        pendingEdit = edit
        let editedSetter = setDocumentEdited
        let storeRef = store
        Task {
            await storeRef.autosave.schedule {
                do {
                    try await storeRef.update(id, title: title, body: body)
                    await MainActor.run {
                        // A newer edit (this note or another) owns the flags.
                        guard pendingEdit == edit else { return }
                        pendingEdit = nil
                        editedSetter(false)
                        hasPendingEdits = false
                    }
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
                titleController.focus()
            }
        }
    }

    /// Hand off from the title field to the AppKit body editor. Both fields
    /// are AppKit-native, so this is a single makeFirstResponder hop.
    private func focusBody() {
        if let tv = editorController.textView {
            tv.window?.makeFirstResponder(tv)
        }
    }

    // MARK: - External changes (Phase 5: banner trigger instead of silent reload)

    /// Silently reload the open note from disk when an external change arrived
    /// and there's nothing local to lose. If the user has unsaved edits the
    /// reload would discard, we leave `externallyChangedIDs` set so the conflict
    /// banner surfaces instead — the user decides via the Reload button.
    private func autoReloadIfSafe() {
        guard store.externallyChangedIDs.contains(note.id) else { return }
        guard !hasPendingEdits else { return }
        Task { await reloadFromDisk() }
    }

    /// New editor: listen to the current open note's dirty reports. Save failures are not bound per
    /// note: the store keeps them (`failedSaveIDs`), so a failure of a note that is no longer shown
    /// still reaches the retry message.
    private func bindOpenNote() {
        boundOpenNote?.onDirtyChange = nil
        guard let open = store.openNote(note.id) else { boundOpenNote = nil; return }
        let setter = setDocumentEdited
        open.onDirtyChange = { dirty in
            setter(dirty)
            hasPendingEdits = dirty
        }
        boundOpenNote = open
        setter(open.isDirty)
        hasPendingEdits = open.isDirty
    }

    private func reloadFromDisk() async {
        await store.reloadNote(id: note.id)
        if NewEditorSwitch.isOn, let open = store.openNote(note.id) {
            open.reload()
            store.acknowledgeExternalChange(id: note.id)
            hasPendingEdits = false
            return
        }
        if let updated = store.notes.first(where: { $0.id == note.id }) {
            // EDIT-02 echo guard: bump the push token before reseeding the
            // editor body from on-disk content so updateNSView classifies it
            // as a genuine external push.
            editorController.externalPushToken += 1
            localBody = updated.body
        }
        store.acknowledgeExternalChange(id: note.id)
        // On-disk content is now the local content — nothing left unsaved.
        hasPendingEdits = false
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

    /// Toolbar/menu bridge for the GFM task-list toggle (⌘⇧L). Mirrors
    /// `applyBlockQuote` — same routing pattern.
    private func applyChecklist() {
        guard let tv = editorController.textView else { return }
        FormattingToolbarView.performChecklist(in: tv)
    }

    /// Toolbar bridge for inserting a markdown thematic break (`---`).
    /// One-shot insert — no toggle-off path. Mirrors the other perform*
    /// bridges in shape.
    private func insertThematicBreak() {
        guard let tv = editorController.textView else { return }
        FormattingToolbarView.performInsertThematicBreak(in: tv)
    }

}

/// "File changed on disk" strip with both choices.
private struct ExternalChangeBannerContent: View {
    let reload: () -> Void
    let keepMine: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text("File changed on disk")
                .font(.system(size: 13))
            Text("— Reload discards your unsaved edits")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Keep mine", action: keepMine)
            Button("Reload", action: reload)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
    }
}

/// New editor: the banner follows the open note's conflict state (changed on disk, unsaved edits).
private struct ConflictBannerView: View {
    @ObservedObject var openNote: OpenNote

    var body: some View {
        if openNote.hasConflict {
            VStack(spacing: 0) {
                ExternalChangeBannerContent(
                    reload: { openNote.reload() },
                    keepMine: { Task { await openNote.keepMine() } })
                Divider()
            }
        }
    }
}
