import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var panelState: PanelState
    @AppStorage(Defaults.lastSelectedNoteFilename) private var lastSelectedNoteFilename: String = ""
    @AppStorage(Defaults.sidebarWidth) private var sidebarWidth: Double = Double(PanelSizes.defaultSidebarWidth)
    @State private var showMissingFolderSheet = false
    @State private var createError: Bool = false
    @FocusState private var searchFocused: Bool

    private var panelController: PanelController? {
        (NSApp.delegate as? AppDelegate)?.panelController
    }

    private var selectedNote: Note? {
        guard let id = panelState.selectedNoteID else { return nil }
        return store.notes.first(where: { $0.id == id })
    }

    private func sidebarDividerHandle(panelWidth: CGFloat) -> some View {
        let handle = ResizeHandleView(
            onDrag: { (newWidth: CGFloat) in
                sidebarWidth = Double(PanelSizes.sidebarWidth(wanted: newWidth, panelWidth: panelWidth))
            },
            onDragEnd: {},
            // The drag starts from the width that is shown, which a narrow panel can make smaller than the saved one.
            startWidthProvider: { PanelSizes.sidebarWidth(wanted: CGFloat(sidebarWidth), panelWidth: panelWidth) },
            growsRight: true
        )
        return handle.frame(width: 6)
    }

    /// Filters the sidebar to the notes that match (see NoteSearch). Return opens the first match.
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $panelState.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit(openFirstMatch)
            if !panelState.searchQuery.isEmpty {
                Button {
                    panelState.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .onChange(of: panelState.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private func openFirstMatch() {
        guard let first = NoteSearch.results(store.notes, query: panelState.searchQuery).first else { return }
        panelState.selectedNoteID = first.id
        DispatchQueue.main.async { panelController?.focusEditor() }   // after the editor shows the note
    }

    var body: some View {
        // The sidebar's width depends on the panel's width: a narrow panel takes room from the sidebar, not the editor.
        GeometryReader { geometry in
            content(panelWidth: geometry.size.width)
        }
    }

    private func content(panelWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // ResizeHandleView is attached as .overlay(alignment: .leading) below
            ZStack {
                SidebarSurface()
                VStack(spacing: 0) {
                    HStack {
                        Text("Notes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        SettingsButton()
                        Button(action: createNote) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("New Note")
                        .accessibilityLabel("New Note")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    searchField
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)

                    Divider()

                    NoteListView(store: store, selectedID: $panelState.selectedNoteID, query: panelState.searchQuery)
                }
            }
            .frame(width: PanelSizes.sidebarWidth(wanted: CGFloat(sidebarWidth), panelWidth: panelWidth))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(.separatorColor))
                    .frame(width: 1)
            }
            .overlay(alignment: .trailing) {
                sidebarDividerHandle(panelWidth: panelWidth)
            }

            // Editor — plain opaque background, with the undo bar of a delete under it
            VStack(spacing: 0) {
                Group {
                    if store.notes.isEmpty {
                        // True empty-state — no notes exist.
                        EmptyStateView(symbol: "note.text", title: "No Notes Yet",
                                       message: "Your notes are plain Markdown files in one folder.",
                                       action: (label: "New Note (⌘N)", perform: createNote))
                            .background(Color(.textBackgroundColor))
                    } else if let note = selectedNote {
                        EditorPaneView(store: store, panelState: panelState, note: note, selectedID: $panelState.selectedNoteID)
                    } else {
                        // Notes exist but none selected (stale UUID mid-reassignment, or
                        // transient between delete → onChange reassign).
                        EmptyStateView(symbol: "sidebar.left", title: "No Note Selected",
                                       message: "Pick a note from the sidebar.")
                            .background(Color(.textBackgroundColor))
                    }
                }
                if let deleted = store.lastDeleted {
                    UndoDeleteBar(deleted: deleted) { undoLastDelete(store: store, panelState: panelState) }
                        .task(id: deleted.id) {
                            try? await Task.sleep(for: UndoDeleteBar.shownFor)
                            if !Task.isCancelled { store.forgetDeleted(deleted.id) }
                        }
                }
            }
        }
        .overlay(alignment: .leading) {
            ResizeHandleView(
                onDrag: { newWidth in panelController?.resizePanel(to: newWidth) },
                onDragEnd: { panelController?.saveWidth() }
            )
            .frame(width: 6)
        }
        .onAppear {
            if let restored = SelectionMemory.restored(lastFilename: lastSelectedNoteFilename, in: store.notes) {
                panelState.selectedNoteID = restored
            } else if panelState.selectedNoteID == nil {
                panelState.selectedNoteID = store.notes.first?.id
            }
            // Check whether the configured notes folder exists (STORE-04 / MF-01)
            let configured = Defaults.store.string(forKey: Defaults.notesFolder) ?? ""
            let folder = configured.isEmpty
                ? StorageLocation.defaultNotesFolder
                : URL(fileURLWithPath: configured)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir)
            if !exists || !isDir.boolValue {
                showMissingFolderSheet = true
            }
        }
        // Remembered by filename, so a rename of the selected note updates it too.
        .onChange(of: selectedNote?.filename) { _, new in
            if let new { lastSelectedNoteFilename = new }   // a momentarily empty list must not forget it
        }
        // A note selected outside the search results (a new note, a delete's successor) must show in the sidebar.
        .onChange(of: panelState.selectedNoteID) { _, id in
            guard let id, !NoteSearch.terms(panelState.searchQuery).isEmpty,
                  !NoteSearch.results(store.notes, query: panelState.searchQuery).contains(where: { $0.id == id })
            else { return }
            panelState.searchQuery = ""
        }
        .onChange(of: store.folderMissing) { _, missing in
            if missing { showMissingFolderSheet = true }
        }
        // IN-04: store.notes is empty on first appearance because
        // applicationDidFinishLaunching kicks off reload() in a detached
        // Task. Without this, the last selected note can never be restored —
        // the onAppear contains(where:) check already failed against an
        // empty array. Restore on the first non-empty publish.
        // G-03: guard relaxed to also reassign when selectedID references a
        // UUID no longer in newNotes (post-delete or post-external-deletion
        // reconcile). Belt-and-suspenders on top of the NoteRowView delete
        // action's successor write — covers external deletions via watcher.
        .onChange(of: store.notes) { _, newNotes in
            let isStale = panelState.selectedNoteID != nil && !newNotes.contains(where: { $0.id == panelState.selectedNoteID })
            guard panelState.selectedNoteID == nil || isStale else { return }
            if !newNotes.isEmpty {
                if let restored = SelectionMemory.restored(lastFilename: lastSelectedNoteFilename, in: newNotes) {
                    panelState.selectedNoteID = restored
                } else {
                    panelState.selectedNoteID = newNotes.first?.id
                }
            } else {
                panelState.selectedNoteID = nil
            }
        }
        .alert("Could not create note", isPresented: $createError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check disk permissions and that the notes folder is writable.")
        }
        .sheet(isPresented: $showMissingFolderSheet) {
            VStack(spacing: 16) {
                Text("Notes Folder Not Found").font(.system(size: 13, weight: .semibold))
                Text("The notes folder could not be found. Create it now or choose a different location.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Choose Folder...") { chooseFolder() }
                        .buttonStyle(.bordered)
                    Button("Create Folder") { createFolder() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
    }

    private func createNote() {
        Task { @MainActor in
            do {
                let note = try await store.create()
                panelState.selectedNoteID = note.id
            } catch {
                NSLog("[Sidekick] create failed: \(error.localizedDescription)")
                createError = true
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            showMissingFolderSheet = false
            Task {
                do {
                    try await store.rebind(to: url)
                } catch {
                    NSLog("[Sidekick] chooseFolder rebind failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func createFolder() {
        let target = StorageLocation.defaultNotesFolder
        showMissingFolderSheet = false
        Task {
            do {
                try await store.rebind(to: target)
            } catch {
                NSLog("[Sidekick] createFolder rebind failed: \(error.localizedDescription)")
            }
        }
    }
}

/// The sidebar's background: the frosted sidebar material, which shows what is behind the panel blurred and tinted.
/// Behind-window blending works in a borderless panel because the panel is not opaque (`SidekickPanel`). The state is
/// forced to active: a non-activating panel would otherwise draw the flat gray inactive look.
struct SidebarSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Opens the Settings window.
struct SettingsButton: View {
    var body: some View {
        Button {
            (NSApp.delegate as? AppDelegate)?.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Empty") {
    let store = PreviewFixtures.makeStore()
    let panelState = PanelState()
    return SidebarView(store: store, panelState: panelState)
}

#Preview("Populated") {
    let store = PreviewFixtures.makeStore(notes: PreviewFixtures.sampleNotes())
    let panelState = PanelState()
    panelState.selectedNoteID = store.notes.first?.id
    return SidebarView(store: store, panelState: panelState)
}
#endif
