import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var panelState: PanelState
    @AppStorage(Defaults.lastSelectedNoteID) private var lastSelectedNoteID: String = ""
    @State private var showMissingFolderSheet = false
    @State private var createError: Bool = false

    private var panelController: PanelController? {
        (NSApp.delegate as? AppDelegate)?.panelController
    }

    private var selectedNote: Note? {
        guard let id = panelState.selectedNoteID else { return nil }
        return store.notes.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            // ResizeHandleView is attached as .overlay(alignment: .leading) below
            // Sidebar — 140pt, vibrancy via ZStack
            ZStack {
                VisualEffectBackground()
                VStack(spacing: 0) {
                    HStack {
                        Text("Notes")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            Task { @MainActor in
                                do {
                                    let note = try await store.create()
                                    panelState.selectedNoteID = note.id
                                } catch {
                                    NSLog("[Sidekick] create failed: \(error.localizedDescription)")
                                    createError = true
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("New Note")
                        .accessibilityLabel("New Note")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    NoteListView(store: store, selectedID: $panelState.selectedNoteID)

                    Divider()

                    HStack {
                        Button {
                            Task { await store.reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh notes from disk")
                        .accessibilityLabel("Refresh notes from disk")

                        Spacer()

                        Button(action: {
                            (NSApp.delegate as? AppDelegate)?.openSettings()
                        }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("Settings")
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .frame(width: 140)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(.separatorColor))
                    .frame(width: 1)
            }

            // Editor — plain opaque background
            Group {
                if store.notes.isEmpty {
                    // True empty-state — no notes exist.
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
                } else if let note = selectedNote {
                    EditorPaneView(store: store, panelState: panelState, note: note, selectedID: $panelState.selectedNoteID)
                } else {
                    // Notes exist but none selected (stale UUID mid-reassignment, or
                    // transient between delete → onChange reassign).
                    VStack(spacing: 12) {
                        Text("No Note Selected")
                            .font(.headline)
                        Text("Pick a note from the sidebar.")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.textBackgroundColor))
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
            if let uuid = UUID(uuidString: lastSelectedNoteID),
               store.notes.contains(where: { $0.id == uuid }) {
                panelState.selectedNoteID = uuid
            } else if panelState.selectedNoteID == nil {
                panelState.selectedNoteID = store.notes.first?.id
            }
            // Check whether the configured notes folder exists (STORE-04 / MF-01)
            let configured = UserDefaults.standard.string(forKey: Defaults.notesFolder) ?? ""
            let folder = configured.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Sidekick")
                : URL(fileURLWithPath: configured)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir)
            if !exists || !isDir.boolValue {
                showMissingFolderSheet = true
            }
        }
        .onChange(of: panelState.selectedNoteID) { _, new in
            lastSelectedNoteID = new?.uuidString ?? ""
        }
        .onChange(of: store.folderMissing) { _, missing in
            if missing { showMissingFolderSheet = true }
        }
        // IN-04: store.notes is empty on first appearance because
        // applicationDidFinishLaunching kicks off reload() in a detached
        // Task. Without this, lastSelectedNoteID can never be restored —
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
                if let uuid = UUID(uuidString: lastSelectedNoteID),
                   newNotes.contains(where: { $0.id == uuid }) {
                    panelState.selectedNoteID = uuid
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
                Text("Notes Folder Not Found").font(.headline)
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
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Sidekick")
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

// MARK: - Previews

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
