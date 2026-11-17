import XCTest
import AppKit
@testable import Sidekick

/// Ticket 15, seam 3 (the notes folder): a save never destroys data silently. Every test makes its
/// own folder, uses a manual scheduler and injects the "remember the folder" step, so nothing
/// touches the shared defaults or the Trash.
@MainActor
final class SafeSavesTests: XCTestCase {

    @MainActor private struct Env {
        let folder: TempFolder
        let store: NoteStore
        let scheduler = ManualScheduler()
        var persisted: PersistedFolders
        func url(_ note: Note) -> URL { folder.url.appendingPathComponent(note.filename) }
        func bytes(_ note: Note) throws -> Data { try Data(contentsOf: url(note)) }
        func open(_ note: Note) -> OpenNote { store.openNote(note.id, scheduler: scheduler)! }
    }

    /// Records what the store would have written to the shared defaults.
    final class PersistedFolders: @unchecked Sendable { var paths: [String] = [] }

    private func makeEnv(_ bodies: [String]) async throws -> (Env, [Note]) {
        let folder = TempFolder()
        let persisted = PersistedFolders()
        let store = try NoteStore(folder: folder.url, startWatcherImmediately: false,
                                  trash: { try FileManager.default.removeItem(at: $0); return nil },
                                  persistFolder: { persisted.paths.append($0.path) })
        var ids: [UUID] = []
        for body in bodies {
            let n = try await store.create()
            try await store.update(n.id, title: "", body: body)
            ids.append(n.id)
        }
        return (Env(folder: folder, store: store, persisted: persisted), ids.map { id in store.notes.first { $0.id == id }! })
    }

    private func host(_ note: OpenNote) -> NewEditorHost { NewEditorHost(note: note) }

    // MARK: 1. A file changed by another process is not overwritten

    func testExternalChangeBetweenLoadAndSaveIsNotOverwritten() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("mine ")
        let theirs = Data("written by another tool\n".utf8)
        try theirs.write(to: env.url(notes[0]))      // a real write from outside the store

        await a.flush()

        XCTAssertEqual(try env.bytes(notes[0]), theirs, "the other tool's bytes are still on disk")
        XCTAssertTrue(a.hasConflict, "the banner shows")
        XCTAssertTrue(a.isDirty, "the note never shows as saved")
        XCTAssertEqual(h.string, "mine alpha\n", "my text is still in the editor")
    }

    func testKeepMineWritesMyTextOverTheExternalChange() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("mine ")
        try Data("theirs\n".utf8).write(to: env.url(notes[0]))
        await a.flush()
        XCTAssertTrue(a.hasConflict)

        await a.keepMine()

        XCTAssertEqual(try env.bytes(notes[0]), Data("mine alpha\n".utf8))
        XCTAssertFalse(a.hasConflict)
        XCTAssertFalse(a.isDirty)
        XCTAssertEqual(h.string, "mine alpha\n")
    }

    func testReloadTakesTheDiskTextAndDropsMyEdits() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("mine ")
        let theirs = Data("theirs\n".utf8)
        try theirs.write(to: env.url(notes[0]))
        await a.flush()

        a.reload()

        XCTAssertEqual(h.string, "theirs\n")
        XCTAssertEqual(try env.bytes(notes[0]), theirs, "reload writes nothing")
        XCTAssertFalse(a.hasConflict)
        XCTAssertFalse(a.isDirty)
        // After a reload the next edit saves normally against the new baseline.
        h.select(0)
        h.type("x")
        await a.flush()
        XCTAssertEqual(try env.bytes(notes[0]), Data("xtheirs\n".utf8))
    }

    func testExternalChangeWithoutUnsavedEditsReloadsSilently() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        try Data("theirs\n".utf8).write(to: env.url(notes[0]))

        await a.externalChange()

        XCTAssertEqual(h.string, "theirs\n")
        XCTAssertFalse(a.hasConflict, "no banner when there is nothing to lose")
        XCTAssertFalse(a.isDirty)
    }

    func testExternalChangeWithUnsavedEditsRaisesTheBannerAndKeepsBothSides() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("mine ")
        let theirs = Data("theirs\n".utf8)
        try theirs.write(to: env.url(notes[0]))

        await a.externalChange()

        XCTAssertTrue(a.hasConflict)
        XCTAssertEqual(h.string, "mine alpha\n")
        XCTAssertEqual(try env.bytes(notes[0]), theirs)
        // Keep mine, from this state, also works and the editor never lost its undo history.
        await a.keepMine()
        XCTAssertEqual(try env.bytes(notes[0]), Data("mine alpha\n".utf8))
        XCTAssertTrue(h.textView.undoManager?.canUndo ?? false)
    }

    func testTheNotesOwnWriteIsNotAnExternalChange() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("x")
        await a.flush()
        h.type("y")                                     // dirty again, saved text differs from now
        await a.externalChange()                        // the watcher's echo of our own write
        XCTAssertFalse(a.hasConflict)
        XCTAssertEqual(h.string, "xyalpha\n")
        XCTAssertTrue(a.isDirty)
    }

    func testStoreSaveRefusesWhenTheFileIsNotTheBaseline() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let id = notes[0].id
        do {
            try await env.store.save(id, title: "", body: "new\n", baseline: Data("something else\n".utf8))
            XCTFail("expected a conflict")
        } catch let error as NoteStoreError {
            XCTAssertEqual(error, .conflict)
        }
        XCTAssertEqual(try env.bytes(notes[0]), Data("alpha\n".utf8))

        try await env.store.save(id, title: "", body: "new\n", baseline: Data("alpha\n".utf8))
        XCTAssertEqual(try env.bytes(notes[0]), Data("new\n".utf8))
        XCTAssertEqual(env.store.notes.first { $0.id == id }?.body, "new\n")
    }

    func testAConflictRenamesNothing() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("x")
        a.setTitle("Renamed")
        try Data("theirs\n".utf8).write(to: env.url(notes[0]))
        await a.commitTitle()
        XCTAssertTrue(a.hasConflict)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.url(notes[0]).path), "old file stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.folder.url.appendingPathComponent("Renamed.md").path))
    }

    // MARK: 2. Every save reports its result

    func testSaveForANoteTheStoreDoesNotKnowReportsFailure() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        var dirtyReports: [Bool] = []
        a.onDirtyChange = { dirtyReports.append($0) }
        try await env.store.delete(notes[0].id)         // the store forgets the note, the editor still has it
        h.type("x")

        await a.flush()

        XCTAssertTrue(a.saveFailed)
        XCTAssertTrue(a.isDirty, "never shown as saved")
        XCTAssertEqual(dirtyReports, [true])
        XCTAssertTrue(env.store.failedSaveIDs.contains(notes[0].id))
    }

    func testStoreSaveForAnUnknownNoteThrows() async throws {
        let (env, _) = try await makeEnv([])
        do {
            try await env.store.save(UUID(), title: "", body: "x", baseline: Data())
            XCTFail("expected unknownNote")
        } catch let error as NoteStoreError {
            XCTAssertEqual(error, .unknownNote)
        }
        do {
            try await env.store.update(UUID(), title: "", body: "x")
            XCTFail("expected unknownNote")
        } catch let error as NoteStoreError {
            XCTAssertEqual(error, .unknownNote)
        }
    }

    /// Reviewer note from ticket 14: the pane drops a note's callbacks on a note switch, so a failure
    /// of the previously open note must still reach the user. The store keeps the failures.
    func testFailureOfAPreviouslyOpenNoteStaysReportedUntilItSaves() async throws {
        let (env, notes) = try await makeEnv(["alpha\n", "beta\n"])
        let a = env.open(notes[0]), b = env.open(notes[1])
        let h = host(a)
        h.type("x")
        h.textView.attach(b.content)                    // note switch: A is no longer shown
        let folderPath = env.folder.url.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folderPath)
        await env.store.flushOpenNotes()
        XCTAssertTrue(env.store.failedSaveIDs.contains(notes[0].id))
        XCTAssertTrue(a.isDirty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderPath)
        await env.store.retryFailedSaves()
        XCTAssertTrue(env.store.failedSaveIDs.isEmpty)
        XCTAssertEqual(try env.bytes(notes[0]), Data("xalpha\n".utf8))
    }

    func testAConflictIsNotAnIOFailureMessage() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        host(a).type("x")
        try Data("theirs\n".utf8).write(to: env.url(notes[0]))
        await a.flush()
        XCTAssertTrue(a.hasConflict)
        XCTAssertFalse(a.saveFailed, "the banner, not the retry message")
        XCTAssertTrue(env.store.failedSaveIDs.isEmpty)
    }

    // MARK: 3. Folder change in Settings

    func testFolderChangeInSettingsRebindsTheRunningStoreAndPendingSaveGoesToTheOldFolderFirst() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        host(a).type("pending ")
        let other = TempFolder()
        try Data("hello\n".utf8).write(to: other.url.appendingPathComponent("hello.md"))

        try await env.store.applyNotesFolderSetting(other.url.path)

        XCTAssertEqual(try env.bytes(notes[0]), Data("pending alpha\n".utf8), "the old folder got the pending save")
        XCTAssertEqual(env.store.notesFolderURL.standardizedFileURL, other.url.standardizedFileURL)
        XCTAssertEqual(env.store.notes.map(\.filename), ["hello.md"])
        XCTAssertEqual(try Data(contentsOf: other.url.appendingPathComponent("hello.md")), Data("hello\n".utf8))
        XCTAssertEqual(env.persisted.paths, [other.url.path])
        // A save of the old note after the switch must not land in the new folder.
        host(a).type("late ")
        await a.flush()
        XCTAssertTrue(a.saveFailed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.url.path).filter { $0.hasSuffix(".md") }, ["hello.md"])
    }

    func testSettingTheCurrentFolderAgainChangesNothing() async throws {
        let (env, _) = try await makeEnv(["alpha\n"])
        try await env.store.applyNotesFolderSetting(env.folder.url.path)
        XCTAssertEqual(env.persisted.paths, [])
        XCTAssertEqual(env.store.notes.count, 1)
    }

    // MARK: 4. The watcher reports per file

    func testFolderSnapshotNamesTheFilesThatChanged() {
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        let before: [String: FolderSnapshot.Stamp] = [
            "a.md": .init(mtime: t0, size: 3), "b.md": .init(mtime: t0, size: 3), "c.md": .init(mtime: t0, size: 3),
        ]
        let after: [String: FolderSnapshot.Stamp] = [
            "a.md": .init(mtime: t0, size: 3),       // same
            "b.md": .init(mtime: t1, size: 3),       // touched
            "d.md": .init(mtime: t0, size: 9),       // new; c.md removed
        ]
        XCTAssertEqual(FolderSnapshot.changedFiles(from: before, to: after), ["b.md", "c.md", "d.md"])
        XCTAssertEqual(FolderSnapshot.changedFiles(from: before, to: before), [])
    }

    func testExternalChangeIsHandledOnlyForTheReportedFiles() async throws {
        let (env, notes) = try await makeEnv(["alpha\n", "beta\n"])
        let a = env.open(notes[0]), b = env.open(notes[1])
        let ha = host(a)
        try Data("alpha changed\n".utf8).write(to: env.url(notes[0]))
        try Data("beta changed\n".utf8).write(to: env.url(notes[1]))

        await env.store.handleExternalChange(files: [notes[0].filename])

        XCTAssertEqual(ha.string, "alpha changed\n", "reported file reloaded")
        XCTAssertEqual(b.markdown, "beta\n", "a file the watcher did not report is not touched")
        XCTAssertEqual(env.store.notes.first { $0.id == notes[1].id }?.body, "beta\n")
    }

    // MARK: 5. End to end with the real watcher

    /// The real FolderWatcher feeds the store: an outside write is reported per file and reaches the
    /// open note. Waits on a condition with a generous timeout, never a fixed sleep.
    func testRealWatcherReportsAnOutsideWriteToTheOpenNote() async throws {
        let folder = TempFolder()
        let store = try NoteStore(folder: folder.url, startWatcherImmediately: true,
                                  trash: { try FileManager.default.removeItem(at: $0); return nil },
                                  persistFolder: { _ in })
        let n = try await store.create()
        try await store.update(n.id, title: "", body: "alpha\n")
        let note = store.notes.first { $0.id == n.id }!
        let a = store.openNote(note.id, scheduler: ManualScheduler())!
        let h = host(a)
        try Data("theirs\n".utf8).write(to: folder.url.appendingPathComponent(note.filename))

        let deadline = Date().addingTimeInterval(10)
        while h.string != "theirs\n", Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertEqual(h.string, "theirs\n", "the watcher event reloaded the clean open note")
        XCTAssertFalse(a.hasConflict)
        XCTAssertEqual(store.notes.first { $0.id == n.id }?.body, "theirs\n")
    }
}
