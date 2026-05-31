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
    @Published private(set) var externallyChangedIDs: Set<UUID> = []
    let externalChanges: AsyncStream<ChangeEvent>

    private var folder: URL
    private var io: IOActor
    private var watcher: FolderWatcher
    private var watcherTask: Task<Void, Never>?
    private var changesContinuation: AsyncStream<ChangeEvent>.Continuation!

    /// Echo-suppression baseline: the body the app itself last authored to disk
    /// per note id. `handleExternalChange` flags a note as externally changed
    /// only when its on-disk body diverges from this value — so the app's own
    /// writes (and the watcher events they fire ~150ms later) never raise a
    /// false "File changed on disk" banner. Comparing against the live in-memory
    /// `notes[i].body` instead raced with in-flight self-writes, which is what
    /// produced the spurious banner. Seeded from disk on first load, updated on
    /// every app write (create/update/reloadNote), pruned on delete.
    private var lastAuthoredBodyByID: [UUID: String] = [:]

    /// Designated initializer.
    /// - Parameters:
    ///   - folder: URL of the notes directory (created if absent).
    ///   - startWatcherImmediately: Pass `false` to skip FSEvent watcher
    ///     spin-up. Production callers always use the default `true`.
    ///     DEBUG preview fixtures pass `false` per D-PF-04.
    init(folder: URL, startWatcherImmediately: Bool = true) throws {
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
        if startWatcherImmediately {
            startWatcher()
        }
    }

    /// DEBUG-only convenience initializer for preview fixtures.
    /// Accepts pre-seeded notes and bypasses `startWatcher()` to avoid
    /// disk I/O during Canvas preview rendering (D-PF-04).
    /// Production code continues to use `init(folder:)` exclusively.
    #if DEBUG
    internal convenience init(folder: URL, seededNotes: [Note]) throws {
        // Pass startWatcherImmediately: false so no FSEvent watcher is
        // created — previews do not need to observe disk changes, and
        // watcher spin-up causes spurious FSEvent activity in Xcode Canvas.
        try self.init(folder: folder, startWatcherImmediately: false)
        self.notes = seededNotes
    }
    #endif

    deinit {
        watcherTask?.cancel()
        watcher.stop()
        changesContinuation?.finish()
    }

    func create() async throws -> Note {
        let id = UUID()
        let uuid8 = String(id.uuidString.prefix(8)).lowercased()
        let filename = "untitled-\(uuid8).md"
        let now = Date()

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
        newIndex.notes.append(IndexEntry(id: id, filename: filename, title: "", pinned: false, order: order, createdAt: now))
        try await io.saveIndex(newIndex)

        let note = Note(id: id, filename: filename, title: "", body: "", pinned: false, order: order, modified: now, createdAt: now)
        notes.append(note)
        lastAuthoredBodyByID[id] = ""
        return note
    }

    func update(_ id: UUID, title: String, body: String) async throws {
        var currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])
        guard let entryIdx = currentIndex.notes.firstIndex(where: { $0.id == id }) else { return }

        var entry = currentIndex.notes[entryIdx]
        let oldFilename = entry.filename
        let titleChanged = entry.title != title

        // Compute new filename from title (was: first heading of body).
        var newFilename = oldFilename
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            let slugBase = await io.slug(for: trimmedTitle, excluding: id, index: currentIndex)
            if !slugBase.isEmpty {
                newFilename = slugBase + ".md"
            }
        }

        // Persist title + filename if either changed.
        if newFilename != oldFilename || titleChanged {
            if newFilename != oldFilename {
                try await io.renameNote(oldFilename: oldFilename, newFilename: newFilename)
                entry.filename = newFilename
            }
            entry.title = title
            currentIndex.notes[entryIdx] = entry
            try await io.saveIndex(currentIndex)
        }

        // Record the authored baseline BEFORE writing so the watcher event this
        // write triggers can't see a divergence (the in-flight-write race). If we
        // recorded it after the write, a watcher tick landing during io.writeNote
        // would compare disk (new) against a stale baseline and flag falsely.
        lastAuthoredBodyByID[id] = body

        // Write body to disk.
        try await io.writeNote(body, filename: newFilename)

        // Update in-memory notes.
        if let noteIdx = notes.firstIndex(where: { $0.id == id }) {
            notes[noteIdx].title = title
            notes[noteIdx].body = body
            notes[noteIdx].filename = newFilename
            notes[noteIdx].modified = Date()
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
        lastAuthoredBodyByID[id] = nil
        // Re-sort to maintain dense order.
        notes.sort { ($0.pinned ? 0 : 1, $0.order) < ($1.pinned ? 0 : 1, $1.order) }
    }

    func reloadNote(id: UUID) async {
        guard let index = await io.loadIndex(),
              let entry = index.notes.first(where: { $0.id == id }) else { return }
        do {
            let body = try await io.readNote(filename: entry.filename)
            let modified = await io.mtime(filename: entry.filename)
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx].body = body
                notes[idx].modified = modified
            }
            // Adopting on-disk content as the new authored baseline: after an
            // explicit reload the app "owns" this body, so it must not re-flag.
            lastAuthoredBodyByID[id] = body
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
        // IN-05: defensive dedup. If `ids` contains duplicates, `first(where:)`
        // would append the same entry multiple times; the fallback loop below
        // would then miss nothing because `ids.contains(entry.id)` is still
        // true. Track seen ids explicitly so each entry appears exactly once.
        var seen: Set<UUID> = []
        var reordered: [IndexEntry] = []
        for id in ids where seen.insert(id).inserted {
            if let entry = currentIndex.notes.first(where: { $0.id == id }) {
                reordered.append(entry)
            }
        }
        // Append any entries not in ids (safety fallback).
        for entry in currentIndex.notes where !seen.contains(entry.id) {
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

        // Scan failure = transient folder-access blip. Preserve current in-memory
        // notes + on-disk index rather than reconciling against a bogus empty
        // snapshot (which RC1-guards in reconcile, but bailing here also avoids
        // the needless applyIndex churn). Pairs with the reconcile guard in 1a.
        guard let snapshot = try? await io.scan() else {
            NSLog("[Sidekick] reload: io.scan() failed — preserving current notes/index")
            return
        }
        let existingIndex = await io.loadIndex()
        let (newIndex, changed) = reconcile(snapshot: snapshot, index: existingIndex)
        if changed { try? await io.saveIndex(newIndex) }
        await applyIndex(newIndex)
    }

    /// G-06: Repoint this NoteStore at a new folder URL without destroying
    /// its identity. Used by "Choose Folder..." / "Create Folder" flows so
    /// the running @ObservedObject bindings in the view hierarchy continue
    /// to work. Also writes UserDefaults inside rebind so the two sources
    /// of truth (UserDefaults[notesFolder], self.folder) cannot drift.
    func rebind(to newFolder: URL) async throws {
        // 1. Stop the existing watcher and cancel its consumer task.
        watcherTask?.cancel()
        watcherTask = nil
        watcher.stop()

        // 2. Ensure the target directory exists on disk.
        try FileManager.default.createDirectory(
            at: newFolder,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // 3. Rebuild the downstream collaborators pointing at newFolder.
        //    IOActor.folder is `let`, so we reconstruct rather than mutate.
        self.folder = newFolder
        self.io = IOActor(folder: newFolder)
        self.watcher = FolderWatcher(url: newFolder)

        // 4. Persist the new path to UserDefaults — inside the rebind —
        //    so there is only one source of truth for "where notes live."
        Defaults.store.set(newFolder.path, forKey: Defaults.notesFolder)

        // 5. Restart watcher + reload notes from the new folder.
        startWatcher()
        await reload()
    }

    // MARK: - Reconciliation

    private func handleExternalChange() async {
        // Snapshot current ids to diff AFTER reconcile for externalChanges emission.
        let beforeIds = Set(self.notes.map(\.id))
        await self.reload()
        let afterIds = Set(self.notes.map(\.id))
        let afterBodiesByID = Dictionary(uniqueKeysWithValues: self.notes.map { ($0.id, $0.body) })

        // ids that appeared OR disappeared OR changed body
        var changedIDs = beforeIds.symmetricDifference(afterIds)
        for id in beforeIds.intersection(afterIds) {
            // Echo-suppression: a body counts as externally changed only when
            // disk diverges from what the app itself last authored. The earlier
            // approach diffed the live in-memory body before/after reload, which
            // raced with in-flight self-writes and produced the spurious banner;
            // the authored baseline is timing-independent.
            if afterBodiesByID[id] != lastAuthoredBodyByID[id] { changedIDs.insert(id) }
        }
        if !changedIDs.isEmpty {
            externallyChangedIDs.formUnion(changedIDs)
            changesContinuation?.yield(.externalModification(ids: changedIDs))
        }
    }

    func acknowledgeExternalChange(id: UUID) {
        externallyChangedIDs.remove(id)
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
        var migratedIndex = index
        var didMigrate = false
        for (i, entry) in index.notes.enumerated() {
            // On read failure, prefer the last body the app authored
            // (authoritative), then the current in-memory body, falling back to
            // "" only for a genuinely new/unreadable note. Prevents a transient
            // read error from zeroing the model and then propagating "" to disk
            // on the next save. Mirrors reloadNote's guard.
            let body = (try? await io.readNote(filename: entry.filename))
                ?? lastAuthoredBodyByID[entry.id]
                ?? notes.first(where: { $0.id == entry.id })?.body
                ?? ""
            let modified = await io.mtime(filename: entry.filename)
            // Seed the echo-suppression baseline for notes the app is adopting
            // for the first time (initial load, rebind, or a newly-discovered
            // external create). Already-tracked ids are left untouched so a
            // watcher-triggered reload can't overwrite the baseline a genuine
            // external edit must be detected against.
            if lastAuthoredBodyByID[entry.id] == nil {
                lastAuthoredBodyByID[entry.id] = body
            }
            // One-shot title bootstrap for pre-migration index entries.
            // HeadingExtractor → first meaningful line → "Untitled".
            let title: String
            if let stored = entry.title {
                title = stored
            } else {
                title = NoteStore.deriveTitle(fromBody: body)
                migratedIndex.notes[i].title = title
                didMigrate = true
            }
            // createdAt is stamped on create(); legacy entries stay nil.
            // Filesystem birth time isn't preserved across folder moves, so
            // a backfill from ctime would lie about pre-existing notes.
            materialized.append(Note(
                id: entry.id,
                filename: entry.filename,
                title: title,
                body: body,
                pinned: entry.pinned,
                order: entry.order,
                modified: modified,
                createdAt: entry.createdAt
            ))
        }
        // Sort: pinned first, then by order.
        notes = materialized.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.order < $1.order
        }
        // Drop baselines for notes no longer in the index (deleted on disk or
        // by the app) so the dictionary tracks exactly the live note set.
        let liveIDs = Set(index.notes.map(\.id))
        lastAuthoredBodyByID = lastAuthoredBodyByID.filter { liveIDs.contains($0.key) }

        // Persist bootstrapped titles so the migration runs once per note.
        if didMigrate {
            try? await io.saveIndex(migratedIndex)
        }
    }

    /// Title-bootstrap chain used when migrating pre-title `.index.json`
    /// entries: first explicit `# `/`## ` heading → first meaningful line
    /// → empty string (sidebar shows "Untitled" placeholder for empty).
    private static func deriveTitle(fromBody body: String) -> String {
        if let heading = HeadingExtractor.firstHeading(in: body) {
            return String(heading.prefix(80))
        }
        if let line = NoteRowFormatting.firstMeaningfulLine(for: body) {
            return String(line.prefix(80))
        }
        return ""
    }
}
