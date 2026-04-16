import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: NoteStore
    @State private var selectedID: UUID?
    @AppStorage(Defaults.lastSelectedNoteID) private var lastSelectedNoteID: String = ""
    @State private var showMissingFolderSheet = false
    @State private var createError: Bool = false

    private var panelController: PanelController? {
        (NSApp.delegate as? AppDelegate)?.panelController
    }

    private var selectedNote: Note? {
        guard let id = selectedID else { return nil }
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
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    NoteListView(store: store, selectedID: $selectedID)

                    Divider()

                    HStack {
                        Button {
                            Task { @MainActor in
                                do {
                                    let note = try await store.create()
                                    selectedID = note.id
                                } catch {
                                    NSLog("[Sidekick] create failed: \(error.localizedDescription)")
                                    createError = true
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .help("New Note")

                        Spacer()

                        Button(action: {
                            (NSApp.delegate as? AppDelegate)?.openSettings()
                        }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .help("Settings")
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
                if let note = selectedNote {
                    EditorPaneView(store: store, note: note, selectedID: $selectedID)
                } else {
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
                selectedID = uuid
            } else if selectedID == nil {
                selectedID = store.notes.first?.id
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
        .onChange(of: selectedID) { _, new in
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
        .onChange(of: store.notes) { _, newNotes in
            guard selectedID == nil, !newNotes.isEmpty else { return }
            if let uuid = UUID(uuidString: lastSelectedNoteID),
               newNotes.contains(where: { $0.id == uuid }) {
                selectedID = uuid
            } else {
                selectedID = newNotes.first?.id
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
            UserDefaults.standard.set(url.path, forKey: Defaults.notesFolder)
            showMissingFolderSheet = false
            Task { await store.reload() }
        }
    }

    private func createFolder() {
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Sidekick")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            UserDefaults.standard.set(target.path, forKey: Defaults.notesFolder)
            showMissingFolderSheet = false
            Task { await store.reload() }
        } catch {
            NSLog("[Sidekick] createFolder failed: \(error.localizedDescription)")
        }
    }
}
