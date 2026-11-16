import AppKit
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var panelState: PanelState
    let note: Note
    @Binding var selectedID: UUID?

    @State private var localTitle: String = ""
    @Environment(\.setDocumentEdited) private var setDocumentEdited
    /// The open note whose callbacks this pane currently listens to.
    @State private var boundOpenNote: OpenNote?

    /// Publishes the editor's text view (toolbar commands, focus) and what the toolbar shows for the caret.
    @StateObject private var editorController = EditorController()

    // F-10: title is an NSViewRepresentable wrapping NSTextField so we can
    // intercept Tab via NSTextFieldDelegate.control(_:textView:doCommandBy:).
    // SwiftUI's .onKeyPress(.tab) on TextField does not fire on macOS — the
    // underlying NSTextField field editor consumes Tab as `insertTab:` for
    // focus traversal before the SwiftUI modifier sees the key.
    @StateObject private var titleController = TitleFieldController()

    // Whether the open note has unsaved edits (reported by `OpenNote.onDirtyChange`). Decides external-change
    // handling: a note with nothing to lose reloads silently, the conflict banner shows only when a reload
    // would discard edits.
    @State private var hasPendingEdits: Bool = false

    /// Footer text below the editor body. "Edited 2:14 PM" — Created date
    /// is intentionally hidden because legacy notes pre-date the field and
    /// filesystem birth time isn't preserved across folder moves.
    private var metadataLine: String {
        guard let edited = note.modified else { return "" }
        return "Edited \(NoteRowFormatting.formattedModifiedTime(edited))"
    }

    /// The open note owns the text: nothing about it passes through view state.
    @ViewBuilder private var editorBody: some View {
        if let open = store.openNote(note.id) {
            NoteEditorView(openNote: open, controller: editorController)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = store.migrationNotice { MigrationNoticeStrip(text: notice) }
            // External-edit conflict banner, top of editor: shown when the file changed on disk and the open
            // note has unsaved edits (reloading would discard them). The safe case reloads silently via
            // autoReloadIfSafe(). A closing Divider separates the strip from the title zone.
            if let open = store.openNote(note.id) {
                ConflictBannerView(openNote: open)
            }

            // Header chrome: title + formatting toolbar grouped on a slightly
            // tinted surface (controlBackgroundColor) so they read as one
            // input zone distinct from the writing area below. A hairline
            // Divider closes off the zone — Mac-native treatment that frames
            // the orphaned "Aa" button without visually shouting.
            VStack(spacing: 0) {
                // Title field — discrete, replaces the v1.2 first-line auto-H1.
                // Padding aligns horizontally with the editor's text inset so the title and body text
                // share a left edge.
                TitleField(
                    text: $localTitle,
                    placeholder: "Untitled",
                    font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                    controller: titleController,
                    onTab: focusBody,
                    onSubmit: focusBody,
                    onCommit: commitTitle
                )
                    .frame(height: 28)
                    .onChange(of: localTitle) { _, newValue in
                        // Skip the onAppear / note-switch reseed — it would
                        // re-write the same body to disk and bump mtime.
                        guard newValue != note.title else { return }
                        // The title is the filename: typing renames nothing. The rename happens in `commitTitle`.
                        store.openNote(note.id)?.setTitle(newValue)
                    }
                    // The real name after a commit (a taken name gets a number suffix) or an outside rename.
                    .onChange(of: note.title) { _, newTitle in
                        if localTitle != newTitle { localTitle = newTitle }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 2)

                // Formatting toolbar: its commands act on the note document through the editor view.
                FormattingToolbarView(
                    perform: perform,
                    activeHeadingLevel: editorController.activeHeadingLevel,
                    activeLinePrefix: editorController.activeLinePrefix,
                    activeInlineKinds: editorController.activeInlineKinds
                )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .background(Color(.controlBackgroundColor))

            if let open = store.openNote(note.id) {
                OpenNoteStatusView(openNote: open)
            }

            // Soft inset shadow at body top — replaces translucent Divider() that bled through panel vibrancy.
            editorBody
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

            // Created / Edited footer — Apple Notes style. Sits inside the editor pane VStack so the
            // scroll view's clip bounds shrink by its height.
            HStack {
                Spacer()
                Text(metadataLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Color(.textBackgroundColor))

            // Save-failure toast, bottom of editor. Every note whose save failed counts, not only the one shown.
            if !store.failedSaveIDs.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text("Could not save — check disk permissions.").font(.system(size: 13))
                        Spacer()
                        Button("Retry") { Task { await store.retryFailedSaves() } }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor))
                }
            }
        }
        .onAppear {
            localTitle = note.title
            bindOpenNote()
            seedFocusForCurrentNote()
            // Shift-Tab at the start of the body returns focus to the title (Tab in the title does the reverse).
            editorController.onShiftTabAtBodyStart = { titleController.focus() }
            autoReloadIfSafe()
        }
        .onChange(of: note.id) { _, _ in
            // The open notes keep their own text and undo history; switching writes pending saves now.
            let storeRef = store
            Task { await storeRef.flushOpenNotes() }
            localTitle = note.title
            bindOpenNote()
            seedFocusForCurrentNote()
            autoReloadIfSafe()
        }
        .onChange(of: store.externallyChangedIDs) { _, _ in
            autoReloadIfSafe()
        }
    }

    // MARK: - Title commit

    /// The title field was committed (Return, Tab or focus left it): the file is renamed now, once. A
    /// name that is taken gets a number suffix and `note.title` then carries the real name.
    private func commitTitle() {
        guard localTitle != note.title else { return }
        guard let open = store.openNote(note.id) else { return }
        open.setTitle(localTitle)
        Task { await open.commitTitle() }
    }

    // MARK: - Focus management

    /// Pick the right starting field for the freshly-mounted note. Empty
    /// notes (newly-created via ⌘N) get title focus so the user can type a
    /// name immediately; otherwise let AppKit hand first-responder to the
    /// NSTextView naturally — no SwiftUI focus needed.
    private func seedFocusForCurrentNote() {
        if TitleRules.isPlaceholder(note.title) && note.body.isEmpty {
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

    /// Listen to the current open note's dirty reports. Save failures are not bound per
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
        guard let open = store.openNote(note.id) else { return }
        open.reload()
        store.acknowledgeExternalChange(id: note.id)
        hasPendingEdits = false
    }

    // MARK: - Formatting toolbar

    /// Hand a toolbar command to the editor view (it acts on the note document).
    private func perform(_ command: NoteFormatCommand) {
        editorController.textView?.perform(command)
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

/// The banner follows the open note's conflict state (changed on disk, unsaved edits).
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
