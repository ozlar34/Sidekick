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

    /// Shared autosave debouncer. One instance for every note so the app can
    /// flush the pending save on note switch and on quit.
    let autosave = Debouncer(interval: 0.5)

    /// Open notes of this session, by note id. A note's undo history lives as long as its entry.
    private var openNotes: [UUID: OpenNote] = [:]

    /// Notes whose last save failed for a reason other than a conflict (disk error, note unknown to the
    /// store), until a save of that note succeeds. The pane shows the retry message while this is not
    /// empty, so a failure of a note that is no longer shown is still reported.
    @Published private(set) var failedSaveIDs: Set<UUID> = []

    private var folder: URL
    /// The folder the store is bound to.
    var notesFolderURL: URL { folder }
    private let persistFolder: (URL) -> Void
    private let trash: (@Sendable (URL) throws -> Void)?
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
    init(folder: URL, startWatcherImmediately: Bool = true,
         trash: (@Sendable (URL) throws -> Void)? = nil,
         persistFolder: ((URL) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: nil
        )
        self.folder = folder
        self.trash = trash
        self.persistFolder = persistFolder ?? { Defaults.store.set($0.path, forKey: Defaults.notesFolder) }
        self.io = IOActor(folder: folder, trash: trash)
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

    // MARK: - Open notes (new editor)

    /// The open note for `id`, created on first use from the file on disk. Saves go through `update`.
    func openNote(_ id: UUID, scheduler: SaveScheduling? = nil) -> OpenNote? {
        if let existing = openNotes[id] { return existing }
        guard let note = notes.first(where: { $0.id == id }) else { return nil }
        let open = OpenNote(id: id, title: note.title, fileURL: folder.appendingPathComponent(note.filename),
                            scheduler: scheduler) { [weak self] title, body, baseline in
            guard let self else { throw NoteStoreError.unknownNote }
            do {
                try await self.save(id, title: title, body: body, baseline: baseline)
                self.failedSaveIDs.remove(id)
            } catch NoteStoreError.conflict {
                throw NoteStoreError.conflict          // the conflict banner reports it, not the retry message
            } catch {
                self.failedSaveIDs.insert(id)
                throw error
            }
        }
        openNotes[id] = open
        return open
    }

    /// Writes every pending save now: note switch, panel dismiss, quit.
    func flushOpenNotes() async {
        for open in Array(openNotes.values) { await open.flush() }
    }

    /// Retries every note whose last save failed.
    func retryFailedSaves() async {
        for id in failedSaveIDs {
            if let open = openNotes[id] { await open.retrySave() } else { failedSaveIDs.remove(id) }
        }
    }

    // MARK: - Serial queue

    /// Tail of the queue of folder operations. Each operation waits for the one before it, so list,
    /// create, rename, delete, pin, reorder, save and reconcile never interleave at their `await`s.
    /// An operation must not call another gated operation (it would wait for itself): gated methods
    /// are thin wrappers around `...Impl` bodies that only call `Impl` bodies.
    private var queueTail: Task<Void, Never>?

    private func serialized<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queueTail
        let run = Task { @MainActor () async -> Result<T, Error> in
            await previous?.value
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        queueTail = Task { _ = await run.value }
        return try await run.value.get()
    }

    func create() async throws -> Note {
        try await serialized { try await self.createImpl() }
    }

    private func createImpl() async throws -> Note {
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

    /// Unconditional save used by the old editor, which has no disk baseline.
    func update(_ id: UUID, title: String, body: String) async throws {
        try await serialized { try await self.updateImpl(id, title: title, body: body, baseline: nil) }
    }

    /// Conditional save: `baseline` is the exact bytes the caller last read from or wrote to the file.
    /// When the file's bytes differ (or the file is gone) nothing is written and `.conflict` is thrown.
    /// A note the store does not know throws `.unknownNote`.
    func save(_ id: UUID, title: String, body: String, baseline: Data) async throws {
        try await serialized { try await self.updateImpl(id, title: title, body: body, baseline: baseline) }
    }

    private func updateImpl(_ id: UUID, title: String, body: String, baseline: Data?) async throws {
        var currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])
        guard let entryIdx = currentIndex.notes.firstIndex(where: { $0.id == id }) else { throw NoteStoreError.unknownNote }

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

        if let baseline {
            // Check and write in one step: a changed file is never replaced, and nothing is renamed.
            try await io.writeConditional(Data(body.utf8), filename: oldFilename, newFilename: newFilename, baseline: baseline)
            if newFilename != oldFilename || titleChanged {
                entry.filename = newFilename
                entry.title = title
                currentIndex.notes[entryIdx] = entry
                try await io.saveIndex(currentIndex)
            }
        } else {
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
            try await io.writeNote(body, filename: newFilename)
        }

        // Every operation is serial, so the watcher event this write triggers is handled after this
        // point and sees the authored baseline.
        lastAuthoredBodyByID[id] = body

        openNotes[id]?.fileURL = folder.appendingPathComponent(newFilename)

        // Update in-memory notes.
        if let noteIdx = notes.firstIndex(where: { $0.id == id }) {
            notes[noteIdx].title = title
            notes[noteIdx].body = body
            notes[noteIdx].filename = newFilename
            notes[noteIdx].modified = Date()
        }
    }

    func delete(_ id: UUID) async throws {
        try await serialized { try await self.deleteImpl(id) }
    }

    private func deleteImpl(_ id: UUID) async throws {
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
        openNotes[id] = nil
        failedSaveIDs.remove(id)
        lastAuthoredBodyByID[id] = nil
        // Re-sort to maintain dense order.
        notes.sort { ($0.pinned ? 0 : 1, $0.order) < ($1.pinned ? 0 : 1, $1.order) }
    }

    func reloadNote(id: UUID) async {
        _ = try? await serialized { await self.reloadNoteImpl(id: id) }
    }

    private func reloadNoteImpl(id: UUID) async {
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
        try await serialized { try await self.setPinnedImpl(id, pinned) }
    }

    private func setPinnedImpl(_ id: UUID, _ pinned: Bool) async throws {
        var currentIndex = await io.loadIndex() ?? NoteIndex(version: 1, notes: [])
        guard let entryIdx = currentIndex.notes.firstIndex(where: { $0.id == id }) else { return }
        currentIndex.notes[entryIdx].pinned = pinned

        let snapshot = (try? await io.scan()) ?? []
        let (newIndex, _) = reconcile(snapshot: snapshot, index: currentIndex)
        try await io.saveIndex(newIndex)
        await applyIndex(newIndex)
    }

    func reorder(_ ids: [UUID]) async throws {
        try await serialized { try await self.reorderImpl(ids) }
    }

    private func reorderImpl(_ ids: [UUID]) async throws {
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
        _ = try? await serialized { await self.reloadImpl(changedFiles: nil) }
    }

    /// `changedFiles` (from the watcher) limits which note files are read again; `nil` reads them all.
    private func reloadImpl(changedFiles: Set<String>?) async {
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
        await applyIndex(newIndex, changedFiles: changedFiles)
    }

    /// G-06: Repoint this NoteStore at a new folder URL without destroying
    /// its identity. Used by "Choose Folder..." / "Create Folder" flows so
    /// the running @ObservedObject bindings in the view hierarchy continue
    /// to work. Also writes UserDefaults inside rebind so the two sources
    /// of truth (UserDefaults[notesFolder], self.folder) cannot drift.
    func rebind(to newFolder: URL) async throws {
        // 0. Pending saves belong to the old folder: write them there first. Each save is its own
        //    queued operation, so they all run before the rebind below.
        await flushOpenNotes()
        try await serialized { try await self.rebindImpl(to: newFolder) }
    }

    private func rebindImpl(to newFolder: URL) async throws {
        openNotes.removeAll()
        failedSaveIDs = []
        externallyChangedIDs = []
        lastAuthoredBodyByID = [:]

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
        self.io = IOActor(folder: newFolder, trash: trash)
        self.watcher = FolderWatcher(url: newFolder)

        // 4. Persist the new path — inside the rebind — so there is only one source of truth
        //    for "where notes live."
        persistFolder(newFolder)

        // 5. Restart watcher + reload notes from the new folder.
        startWatcher()
        await reloadImpl(changedFiles: nil)
    }

    /// Settings changed the notes folder: bind the running store to it now. An empty path means the
    /// default location; the folder the store already uses changes nothing.
    func applyNotesFolderSetting(_ path: String) async throws {
        let target = path.isEmpty ? StorageLocation.defaultNotesFolder : URL(fileURLWithPath: path)
        guard target.resolvingSymlinksInPath().path != folder.resolvingSymlinksInPath().path else { return }
        try await rebind(to: target)
    }

    // MARK: - Reconciliation

    /// The watcher reported these files. Reconciles the folder, then tells each affected note: an open
    /// note reloads silently when it has no unsaved edits and raises its conflict banner otherwise;
    /// a note without an open note is flagged in `externallyChangedIDs` (old editor).
    func handleExternalChange(files: Set<String>) async {
        let changedIDs: Set<UUID> = (try? await serialized { await self.reconcileAfterExternalChange(files: files) }) ?? []
        // Outside the queue: an open note waits for its own running save, and that save is queued.
        var flagged: Set<UUID> = []
        for id in changedIDs {
            if let open = openNotes[id] { await open.externalChange() } else { flagged.insert(id) }
        }
        if !flagged.isEmpty {
            externallyChangedIDs.formUnion(flagged)
            changesContinuation?.yield(.externalModification(ids: flagged))
        }
    }

    private func reconcileAfterExternalChange(files: Set<String>) async -> Set<UUID> {
        let beforeIds = Set(self.notes.map(\.id))
        await self.reloadImpl(changedFiles: files)
        let afterIds = Set(self.notes.map(\.id))

        var changedIDs = beforeIds.symmetricDifference(afterIds)
        for note in self.notes where beforeIds.contains(note.id) && files.contains(note.filename) {
            // Echo-suppression: a body counts as externally changed only when disk diverges from what
            // the app itself last authored.
            if note.body != lastAuthoredBodyByID[note.id] { changedIDs.insert(note.id) }
        }
        return changedIDs
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
            for await event in self.watcher.events {
                // The watcher names the files that changed; the store reconciles and tells those notes.
                guard case .filesChanged(let files) = event else { continue }
                await self.handleExternalChange(files: files)
            }
        }
    }

    private func restartWatcherAfterFolderRecreated() {
        self.watcher.stop()
        self.watcher = FolderWatcher(url: folder)
        startWatcher()
    }

    // MARK: - Internal helpers

    private func applyIndex(_ index: NoteIndex, changedFiles: Set<String>? = nil) async {
        var materialized: [Note] = []
        var migratedIndex = index
        var didMigrate = false
        for (i, entry) in index.notes.enumerated() {
            // On read failure, prefer the last body the app authored
            // (authoritative), then the current in-memory body, falling back to
            // "" only for a genuinely new/unreadable note. Prevents a transient
            // read error from zeroing the model and then propagating "" to disk
            // on the next save. Mirrors reloadNote's guard.
            // A file the watcher did not report keeps the body already in memory (no re-read).
            let unchanged = changedFiles.map { !$0.contains(entry.filename) } ?? false
            let known = unchanged ? notes.first(where: { $0.id == entry.id && $0.filename == entry.filename }) : nil
            let body: String
            if let kept = known?.body {
                body = kept
            } else if let read = try? await io.readNote(filename: entry.filename) {
                body = read
            } else {
                body = lastAuthoredBodyByID[entry.id] ?? notes.first(where: { $0.id == entry.id })?.body ?? ""
            }
            let modified: Date?
            if let kept = known { modified = kept.modified } else { modified = await io.mtime(filename: entry.filename) }
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
