/// @MainActor orchestrator for the notes folder. Owns the index
/// (authoritative) and exposes observable `notes` + `externalChanges`.
/// All disk I/O delegated to `IOActor`; reconciliation via pure `reconcile`.
///
/// Pattern sources:
///   - RESEARCH.md §Architecture Patterns / §Code Examples "NoteStore wiring"
///   - PATTERNS.md: analog PanelController (orchestrator style)
///   - CONTEXT.md: API shape locked
///   - RESEARCH.md §Pattern 1 (FolderWatcher integration, watcher restart on folder deletion)
import Foundation
import Combine

@MainActor
final class NoteStore: ObservableObject {

    // MARK: - Public API

    @Published private(set) var notes: [Note] = []
    @Published private(set) var folderMissing: Bool = false
    let externalChanges: AsyncStream<ChangeEvent>

    private let folder: URL
    private let io: IOActor
    private var watcher: FolderWatcher
    private var watcherTask: Task<Void, Never>?
    private var changesContinuation: AsyncStream<ChangeEvent>.Continuation!

    init(folder: URL) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: nil
        )
        self.folder = folder
        self.io = IOActor(folder: folder)
        self.watcher = FolderWatcher(url: folder)

        var cont: AsyncStream<ChangeEvent>.Continuation!
        self.externalChanges = AsyncStream { cont = $0 }
        self.changesContinuation = cont

        // No background reload on init — callers drive reconciliation via
        // explicit `await store.reload()`. Fire-and-forget Task would race
        // with create/update calls in tests and production alike.
        startWatcher()
    }

    deinit {
        watcherTask?.cancel()
        watcher.stop()
        changesContinuation?.finish()
    }

    func create() async throws -> Note {
        let id = UUID()
        let uuid8 = String(id.uuidString.prefix(8)).lowercased()
        let filename = "untitled-\(uuid8).md"

        // Load current index (or start empty) to compute correct order.
        let currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])
        let order = currentIndex.notes.count

        // Write empty body to disk FIRST. Propagate error so the caller can
        // surface it and avoid mutating the in-memory array when disk state
        // diverges (WR-01).
        try await io.writeNote("", filename: filename)

        // Append entry to index and save. If this fails the file exists on
        // disk but is missing from .index.json — reconcile on next reload
        // will adopt it with a new UUID, which is a recoverable state.
        var newIndex = currentIndex
        newIndex.notes.append(IndexEntry(id: id, filename: filename, pinned: false, order: order))
        try await io.saveIndex(newIndex)

        let note = Note(id: id, filename: filename, body: "", pinned: false, order: order)
        notes.append(note)
        return note
    }

    func update(_ id: UUID, body: String) async throws {
        var currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])
        guard let entryIdx = currentIndex.notes.firstIndex(where: { $0.id == id }) else { return }

        var entry = currentIndex.notes[entryIdx]
        let oldFilename = entry.filename

        // Compute new filename from first heading.
        var newFilename = oldFilename
        if let heading = HeadingExtractor.firstHeading(in: body) {
            let slugBase = await io.slug(for: heading, excluding: id, index: currentIndex)
            if !slugBase.isEmpty {
                newFilename = slugBase + ".md"
            }
        }

        // Rename if heading changed.
        if newFilename != oldFilename {
            try await io.renameNote(oldFilename: oldFilename, newFilename: newFilename)
            entry.filename = newFilename
            currentIndex.notes[entryIdx] = entry
            try await io.saveIndex(currentIndex)
        }

        // Write body to disk.
        try await io.writeNote(body, filename: newFilename)

        // Update in-memory notes.
        if let noteIdx = notes.firstIndex(where: { $0.id == id }) {
            notes[noteIdx].body = body
            notes[noteIdx].filename = newFilename
        }
    }

    func delete(_ id: UUID) async throws {
        var currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])
        guard let entryIdx = currentIndex.notes.firstIndex(where: { $0.id == id }) else { return }
        let filename = currentIndex.notes[entryIdx].filename

        try await io.trashNote(filename: filename)
        currentIndex.notes.remove(at: entryIdx)

        // Reassign dense order.
        for i in currentIndex.notes.indices {
            currentIndex.notes[i].order = i
        }
        try await io.saveIndex(currentIndex)

        notes.removeAll { $0.id == id }
        // Re-sort to maintain dense order.
        notes.sort { ($0.pinned ? 0 : 1, $0.order) < ($1.pinned ? 0 : 1, $1.order) }
    }

    func reloadNote(id: UUID) async {
        guard let index = await io.loadIndex(),
              let entry = index.notes.first(where: { $0.id == id }) else { return }
        do {
            let body = try await io.readNote(filename: entry.filename)
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx].body = body
            }
        } catch {
            // Preserve in-memory body on read failure so the next auto-save
            // does not overwrite on-disk content with an empty string.
            NSLog("[Sidekick] reloadNote failed for \(entry.filename): \(error.localizedDescription)")
        }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) async throws {
        var currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])
        guard let entryIdx = currentIndex.notes.firstIndex(where: { $0.id == id }) else { return }
        currentIndex.notes[entryIdx].pinned = pinned

        let snapshot = (try? await io.scan()) ?? []
        let (newIndex, _) = reconcile(snapshot: snapshot, index: currentIndex)
        try await io.saveIndex(newIndex)
        await applyIndex(newIndex)
    }

    func reorder(_ ids: [UUID]) async throws {
        var currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])

        // Re-order entries to match provided ids sequence.
        var reordered: [IndexEntry] = []
        for id in ids {
            if let entry = currentIndex.notes.first(where: { $0.id == id }) {
                reordered.append(entry)
            }
        }
        // Append any entries not in ids (safety fallback).
        for entry in currentIndex.notes where !ids.contains(entry.id) {
            reordered.append(entry)
        }
        // Assign dense order.
        for i in reordered.indices { reordered[i].order = i }
        currentIndex.notes = reordered
        try await io.saveIndex(currentIndex)
        await applyIndex(currentIndex)
    }

    func reload() async {
        // Folder-deletion recovery (RESEARCH Pitfall 2):
        // If the notes folder was deleted, publish folderMissing=true so the UI
        // can react, then recreate it and restart the watcher (T-02-09 mitigation).
        if !FileManager.default.fileExists(atPath: folder.path) {
            folderMissing = true
            try? FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: nil
            )
            restartWatcherAfterFolderRecreated()
        } else {
            folderMissing = false
        }

        let snapshot = (try? await io.scan()) ?? []
        let existingIndex = await io.loadIndex()
        let (newIndex, changed) = reconcile(snapshot: snapshot, index: existingIndex)
        if changed { try? await io.saveIndex(newIndex) }
        await applyIndex(newIndex)
    }

    // MARK: - Reconciliation

    private func handleExternalChange() async {
        // Snapshot current ids to diff AFTER reconcile for externalChanges emission.
        let beforeIds = Set(self.notes.map(\.id))
        let beforeBodiesByID = Dictionary(uniqueKeysWithValues: self.notes.map { ($0.id, $0.body) })
        await self.reload()
        let afterIds = Set(self.notes.map(\.id))
        let afterBodiesByID = Dictionary(uniqueKeysWithValues: self.notes.map { ($0.id, $0.body) })

        // ids that appeared OR disappeared OR changed body
        var changedIDs = beforeIds.symmetricDifference(afterIds)
        for id in beforeIds.intersection(afterIds) {
            if beforeBodiesByID[id] != afterBodiesByID[id] { changedIDs.insert(id) }
        }
        if !changedIDs.isEmpty {
            changesContinuation?.yield(.externalModification(ids: changedIDs))
        }
    }

    // MARK: - Watcher lifecycle

    private func startWatcher() {
        do {
            try self.watcher.start()
        } catch {
            NSLog("[Sidekick] NoteStore: watcher.start failed: \(error)")
            return
        }
        self.watcherTask?.cancel()
        self.watcherTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.watcher.events {
                // External filesystem change detected — reconcile and emit.
                // Per RESEARCH §Pattern 2 and Anti-Patterns, we don't try to
                // diff individual events; always run a full reconcile.
                await self.handleExternalChange()
            }
        }
    }

    private func restartWatcherAfterFolderRecreated() {
        self.watcher.stop()
        self.watcher = FolderWatcher(url: folder)
        startWatcher()
    }

    // MARK: - Internal helpers

    private func applyIndex(_ index: NoteIndex) async {
        var materialized: [Note] = []
        for entry in index.notes {
            let body = (try? await io.readNote(filename: entry.filename)) ?? ""
            materialized.append(Note(
                id: entry.id,
                filename: entry.filename,
                body: body,
                pinned: entry.pinned,
                order: entry.order
            ))
        }
        // Sort: pinned first, then by order.
        notes = materialized.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.order < $1.order
        }
    }
}
