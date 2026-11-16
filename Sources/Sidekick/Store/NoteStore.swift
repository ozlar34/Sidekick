/// @MainActor orchestrator for the notes folder. Files are the only truth: a note is a `.md` file,
/// its identity is the filename and its title is the filename without ".md". Pins and manual order
/// live in the order file (`OrderFile`), which nothing else depends on. Exposes observable `notes`
/// + `externalChanges`. All disk I/O delegated to `IOActor`.
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
    /// Session ids by filename. Nothing on disk holds an id: a file the store has not seen gets a new
    /// one, and a rename made by the store carries the id over.
    private var idsByName: [String: UUID] = [:]
    /// The folder whose one-time migration has been looked at (or attempted) in this session.
    private var migratedFolder: URL?
    /// Set when the one-time migration failed; the folder is then used as it is and tried again next launch.
    @Published private(set) var migrationError: String?
    @Published private(set) var migrationFailure: MigrationFailure?
    /// One line for the editor pane while the last migration attempt failed; nil otherwise.
    var migrationNotice: String? { migrationFailure?.noticeText }
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
                let resolved = try await self.save(id, title: title, body: body, baseline: baseline)
                self.failedSaveIDs.remove(id)
                return resolved
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
            await self.ensureMigrated()
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        queueTail = Task { _ = await run.value }
        return try await run.value.get()
    }

    func create() async throws -> Note {
        try await serialized { try await self.createImpl() }
    }

    private func createImpl() async throws -> Note {
        // The name is claimed on disk (exclusive create), so no file made by another tool is replaced.
        let filename = try await io.createNote(base: TitleRules.untitled)
        let id = UUID()
        idsByName[filename] = id
        let stamp = await io.mtime(filename: filename)
        let note = Note(id: id, filename: filename, title: Self.title(of: filename), body: "", pinned: false,
                        order: notes.count, modified: stamp ?? Date(), createdAt: FileOps.creationDate(folder.appendingPathComponent(filename)) ?? Date())
        notes.append(note)
        lastAuthoredBodyByID[id] = ""
        // The new note goes last. The order file only records order; losing this write loses nothing else.
        if var arranged = await arrangement() {
            arranged.removeAll { $0.filename == filename }
            arranged.append(.init(filename: filename, pinned: false))
            await saveOrderBestEffort(arranged)
        }
        return note
    }

    /// Unconditional save of title and body: no disk baseline is checked, a note whose file is gone is written
    /// again. The app saves through `save(_:title:body:baseline:)`; this one serves tests and tools.
    func update(_ id: UUID, title: String, body: String) async throws {
        try await serialized { _ = try await self.updateImpl(id, title: title, body: body, baseline: nil) }
    }

    /// Unconditional body save that keeps the note's name.
    func update(_ id: UUID, body: String) async throws {
        try await serialized { _ = try await self.updateImpl(id, title: nil, body: body, baseline: nil) }
    }

    /// Conditional save: `baseline` is the exact bytes the caller last read from or wrote to the file.
    /// When the file's bytes differ (or the file is gone) nothing is written, nothing is renamed and
    /// `.conflict` is thrown. A note the store does not know throws `.unknownNote`.
    /// Returns the note's title afterwards: the requested one, or with a number suffix when that name was taken.
    @discardableResult
    func save(_ id: UUID, title: String, body: String, baseline: Data) async throws -> String {
        try await serialized { try await self.updateImpl(id, title: title, body: body, baseline: baseline) }
    }

    private func updateImpl(_ id: UUID, title: String?, body: String, baseline: Data?) async throws -> String {
        guard let noteIdx = notes.firstIndex(where: { $0.id == id }) else { throw NoteStoreError.unknownNote }
        let oldName = notes[noteIdx].filename

        // A title that is already the note's name renames nothing; any other title renames the file once,
        // here, with the collision check made against the disk.
        let wantedBase = title.map { TitleRules.fileBase(forTitle: $0) }
        let rename = title != nil && title != notes[noteIdx].title && wantedBase != notes[noteIdx].title
        let newName = try await io.save(Data(body.utf8), filename: oldName, wantedBase: rename ? wantedBase : nil, baseline: baseline)

        // Every operation is serial, so the watcher event this write triggers is handled after this
        // point and sees the authored baseline.
        lastAuthoredBodyByID[id] = body
        if newName != oldName {
            idsByName[oldName] = nil
            idsByName[newName] = id
            await renameInOrderFile(from: oldName, to: newName)
        }
        let resolved = Self.title(of: newName)
        openNotes[id]?.fileURL = folder.appendingPathComponent(newName)
        if let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i].title = resolved
            notes[i].body = body
            notes[i].filename = newName
            notes[i].modified = Date()
        }
        return resolved
    }

    func delete(_ id: UUID) async throws {
        try await serialized { try await self.deleteImpl(id) }
    }

    private func deleteImpl(_ id: UUID) async throws {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        try await io.trashNote(filename: note.filename)
        if var arranged = await arrangement() {
            arranged.removeAll { $0.filename == note.filename }
            await saveOrderBestEffort(arranged)
        }
        idsByName[note.filename] = nil
        notes.removeAll { $0.id == id }
        openNotes[id] = nil
        failedSaveIDs.remove(id)
        lastAuthoredBodyByID[id] = nil
        for i in notes.indices { notes[i].order = i }
    }

    func reloadNote(id: UUID) async {
        _ = try? await serialized { await self.reloadNoteImpl(id: id) }
    }

    private func reloadNoteImpl(id: UUID) async {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        do {
            let body = try await io.readNote(filename: note.filename)
            let modified = await io.mtime(filename: note.filename)
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
            NSLog("[Sidekick] reloadNote failed for \(note.filename): \(error.localizedDescription)")
        }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) async throws {
        try await serialized { try await self.setPinnedImpl(id, pinned) }
    }

    private func setPinnedImpl(_ id: UUID, _ pinned: Bool) async throws {
        guard let note = notes.first(where: { $0.id == id }), var arranged = await arrangement() else { return }
        guard let i = arranged.firstIndex(where: { $0.filename == note.filename }) else { return }
        arranged[i] = .init(filename: note.filename, pinned: pinned)
        try await saveOrder(arranged.filter(\.pinned) + arranged.filter { !$0.pinned })
        await applyDisk()
    }

    func reorder(_ ids: [UUID]) async throws {
        try await serialized { try await self.reorderImpl(ids) }
    }

    private func reorderImpl(_ ids: [UUID]) async throws {
        guard let arranged = await arrangement() else { return }
        // Names in the order given; duplicates and unknown ids are dropped, the rest keep their place at the end.
        var seen: Set<String> = []
        var names: [String] = []
        for id in ids {
            if let name = notes.first(where: { $0.id == id })?.filename, seen.insert(name).inserted { names.append(name) }
        }
        let pinnedNames = Set(arranged.filter(\.pinned).map(\.filename))
        let known = Set(arranged.map(\.filename))
        let ordered = names.filter { known.contains($0) } + arranged.map(\.filename).filter { !seen.contains($0) }
        try await saveOrder(ordered.map { .init(filename: $0, pinned: pinnedNames.contains($0)) })
        await applyDisk()
    }

    func reload() async {
        _ = try? await serialized { await self.reloadImpl(changedFiles: nil) }
    }

    /// `changedFiles` (from the watcher) limits which note files are read again; `nil` reads them all.
    private func reloadImpl(changedFiles: Set<String>?) async {
        // Folder-deletion recovery (RESEARCH Pitfall 2):
        // If the notes folder was deleted, publish folderMissing=true so the UI
        // can react, then recreate it and restart the watcher (T-02-09 mitigation).
        var folderWasMissing = false
        if !FileManager.default.fileExists(atPath: folder.path) {
            folderWasMissing = true
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
        await applyDisk(changedFiles: changedFiles, emptyIsReal: folderWasMissing)
    }

    // MARK: - One-time migration

    /// Runs the old-format migration once per bound folder, before anything reads or changes the files.
    /// A failure is recorded in `migrationError`; the folder is then used as it is and tried again next launch.
    private func ensureMigrated() async {
        guard migratedFolder != folder else { return }
        migratedFolder = folder
        do {
            if case .migrated(let renamed, let backup) = try await io.migrate() {
                NSLog("[Sidekick] migrated \(renamed) note files; backup: \(backup)")
            }
            migrationError = nil
            migrationFailure = nil
        } catch {
            NSLog("[Sidekick] migration failed, notes used as they are: \(error)")
            let failure = error as? MigrationFailure ?? MigrationFailure(reason: error.localizedDescription, backup: nil)
            migrationFailure = failure
            migrationError = failure.reason
        }
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
        idsByName = [:]
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
        await ensureMigrated()
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
    /// a note without an open note is flagged in `externallyChangedIDs`.
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

    private static func title(of filename: String) -> String { String(filename.dropLast(3)) }

    /// The folder's notes in display order, from a fresh scan and the order file. nil when the folder
    /// cannot be scanned (a blip must never be read as "every note was deleted").
    private func arrangement() async -> [OrderFile.Arranged]? {
        guard let entries = try? await io.scan() else { return nil }
        return await orderFile().arrange(entries)
    }

    /// The order file as stored. A damaged file is moved aside and rebuilt empty: pins and order reset, nothing else.
    private func orderFile() async -> OrderFile {
        switch await io.loadOrder() {
        case .loaded(let order): return order
        case .missing: return OrderFile(pinned: [], order: [])
        case .damaged:
            let empty = OrderFile(pinned: [], order: [])
            try? await io.saveOrder(empty)
            return empty
        }
    }

    private func saveOrder(_ arranged: [OrderFile.Arranged]) async throws {
        try await io.saveOrder(OrderFile.make(from: arranged))
    }

    /// For changes whose file work already succeeded: a lost order file write only changes the order.
    private func saveOrderBestEffort(_ arranged: [OrderFile.Arranged]) async {
        do { try await saveOrder(arranged) } catch { NSLog("[Sidekick] order file not saved: \(error.localizedDescription)") }
    }

    private func renameInOrderFile(from old: String, to new: String) async {
        guard case .loaded(var order) = await io.loadOrder() else { return }
        order.order = order.order.map { $0 == old ? new : $0 }
        order.pinned = order.pinned.map { $0 == old ? new : $0 }
        do { try await io.saveOrder(order) } catch { NSLog("[Sidekick] order file not saved: \(error.localizedDescription)") }
    }

    /// Rebuilds `notes` from the folder. A file the watcher did not report keeps the body already in memory.
    /// `emptyIsReal`: the folder was just recreated, so an empty scan is the truth.
    private func applyDisk(changedFiles: Set<String>? = nil, emptyIsReal: Bool = false) async {
        // Scan failure = transient folder-access blip: keep the current notes.
        guard var entries = try? await io.scan() else {
            NSLog("[Sidekick] reload: io.scan() failed — preserving current notes")
            return
        }
        // RC1 guard: one empty listing against a populated list may be a transient folder-access blip,
        // not that the user deleted every note. Keep the list unless a second look agrees.
        // A second listing after the debounce that is also empty, with the folder still there, is the truth:
        // the user (or another tool) really removed the last note.
        if entries.isEmpty, !notes.isEmpty, !emptyIsReal {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard FileManager.default.fileExists(atPath: folder.path), let again = try? await io.scan(), again.isEmpty else { return }
            entries = again
        }
        let byName = Dictionary(entries.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        let arranged = await orderFile().arrange(entries)
        var materialized: [Note] = []
        for (position, item) in arranged.enumerated() {
            let name = item.filename
            let id = idsByName[name] ?? UUID()
            idsByName[name] = id
            let unchanged = changedFiles.map { !$0.contains(name) } ?? false
            let known = unchanged ? notes.first(where: { $0.id == id && $0.filename == name }) : nil
            let body: String
            if let kept = known?.body {
                body = kept
            } else if let read = try? await io.readNote(filename: name) {
                body = read
            } else {
                // A read error must not zero the model and then propagate "" to disk on the next save.
                body = lastAuthoredBodyByID[id] ?? notes.first(where: { $0.id == id })?.body ?? ""
            }
            // Seed the echo-suppression baseline for notes adopted for the first time. Already-tracked ids
            // keep theirs so a genuine external edit is still detected against what the app authored.
            if lastAuthoredBodyByID[id] == nil { lastAuthoredBodyByID[id] = body }
            materialized.append(Note(
                id: id, filename: name, title: Self.title(of: name), body: body,
                pinned: item.pinned, order: position,
                modified: byName[name]?.mtime, createdAt: byName[name]?.created
            ))
        }
        notes = materialized
        // Ids and baselines track exactly the files that are there.
        let liveNames = Set(arranged.map(\.filename))
        idsByName = idsByName.filter { liveNames.contains($0.key) }
        let liveIDs = Set(materialized.map(\.id))
        lastAuthoredBodyByID = lastAuthoredBodyByID.filter { liveIDs.contains($0.key) }
    }
}
