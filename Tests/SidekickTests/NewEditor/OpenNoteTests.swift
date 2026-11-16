import XCTest
import AppKit
@testable import Sidekick

/// Test scheduler: nothing fires until the test says so, so no test depends on timing.
@MainActor
final class ManualScheduler: SaveScheduling {
    private(set) var pending: (@MainActor () -> Void)?
    private(set) var scheduleCount = 0
    func schedule(_ work: @escaping @MainActor () -> Void) { pending = work; scheduleCount += 1 }
    func cancel() { pending = nil }
    func fire() { let work = pending; pending = nil; work?() }
}

/// The notes-folder seam: open notes against a real `NoteStore` on a temporary folder, with the editor
/// driven by real key events. Every test makes its own folder.
@MainActor
final class OpenNoteTests: XCTestCase {

    // MARK: Helpers

    @MainActor private struct Env {
        let folder: TempFolder
        let store: NoteStore
        let scheduler = ManualScheduler()
        func url(_ note: Note) -> URL { folder.url.appendingPathComponent(note.filename) }
        func bytes(_ note: Note) throws -> Data { try Data(contentsOf: url(note)) }
        func mtime(_ note: Note) throws -> Date {
            try url(note).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        }
        func open(_ note: Note) -> OpenNote { store.openNote(note.id, scheduler: scheduler)! }
    }

    /// A store whose folder holds one note per body, in order.
    private func makeEnv(_ bodies: [String]) async throws -> (Env, [Note]) {
        let folder = TempFolder()
        let store = try NoteStore(folder: folder.url, startWatcherImmediately: false)
        var ids: [UUID] = []
        for body in bodies {
            let n = try await store.create()
            try await store.update(n.id, title: "", body: body)
            ids.append(n.id)
        }
        return (Env(folder: folder, store: store), ids.map { id in store.notes.first { $0.id == id }! })
    }

    private func host(_ note: OpenNote) -> NewEditorHost { NewEditorHost(note: note) }

    // MARK: 1. Undo never crosses notes

    func testUndoNeverCrossesNotes() async throws {
        let (env, notes) = try await makeEnv(["alpha\n", "beta\n"])
        let a = env.open(notes[0]), b = env.open(notes[1])
        let h = host(a)
        h.type("X")
        XCTAssertEqual(h.string, "Xalpha\n")

        h.textView.attach(b.content)
        XCTAssertEqual(h.string, "beta\n")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.string, "beta\n", "undo in B must not replay A's edit")
        XCTAssertEqual(b.markdown, "beta\n")

        h.textView.attach(a.content)
        XCTAssertEqual(h.string, "Xalpha\n")
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.string, "alpha\n", "A's own undo still works after switching back")
        XCTAssertEqual(a.markdown, "alpha\n")
    }

    func testReloadFromDiskDropsUndoHistory() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("X")
        try Data("changed\n".utf8).write(to: env.url(notes[0]))
        a.reload()
        XCTAssertEqual(h.string, "changed\n")
        XCTAssertFalse(h.textView.undoManager?.canUndo ?? true)
        h.textView.undoManager?.undo()
        XCTAssertEqual(h.string, "changed\n")
    }

    // MARK: 2. Debounce and baseline

    func testTypeAndDeleteWithinDebounceWritesNothing() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        let before = try env.bytes(notes[0]), mtime = try env.mtime(notes[0])

        h.type("x")
        XCTAssertTrue(a.isDirty)
        XCTAssertNotNil(env.scheduler.pending, "a save is scheduled after the edit")
        h.press(.backspace)
        XCTAssertEqual(h.markdown, "alpha\n")
        XCTAssertNil(env.scheduler.pending, "the scheduled save is cancelled when the text is back at the baseline")
        XCTAssertFalse(a.isDirty)

        env.scheduler.fire()
        await a.flush()
        XCTAssertEqual(try env.bytes(notes[0]), before)
        XCTAssertEqual(try env.mtime(notes[0]), mtime, "no write happened")
        XCTAssertEqual(try env.bytes(notes[0]), Data(h.markdown.utf8), "disk equals the editor")
    }

    func testDebouncedSaveWritesEditorBytesAndClearsDirty() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        var dirtyReports: [Bool] = []
        a.onDirtyChange = { dirtyReports.append($0) }
        h.type("x")
        XCTAssertEqual(try env.bytes(notes[0]), Data("alpha\n".utf8), "nothing is written before the debounce fires")
        env.scheduler.fire()
        await a.flush()
        XCTAssertEqual(try env.bytes(notes[0]), Data("xalpha\n".utf8))
        XCTAssertEqual(dirtyReports, [true, false])
        XCTAssertFalse(a.isDirty)
        // "Edited" time as today: the store's modified date moves with the save.
        XCTAssertGreaterThanOrEqual(env.store.notes.first { $0.id == notes[0].id }!.modified!, notes[0].modified!)
        // The save went through the store, so the file is not reported as an external change.
        XCTAssertFalse(env.store.externallyChangedIDs.contains(notes[0].id))
    }

    func testEditingTwiceSchedulesOneSavePerEditAndWritesOnce() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("xy")
        env.scheduler.fire()
        env.scheduler.fire()   // second fire has nothing pending
        await a.flush()
        XCTAssertEqual(try env.bytes(notes[0]), Data("xyalpha\n".utf8))
    }

    // MARK: 3. Unreadable files

    func testNonUTF8FileOpensReadOnlyAndNeverChanges() async throws {
        let (env, _) = try await makeEnv([])
        let broken = Data([0x66, 0xFF, 0xFE, 0x80, 0x0A])
        try broken.write(to: env.folder.url.appendingPathComponent("broken.md"))
        await env.store.reload()
        let note = env.store.notes.first { $0.filename == "broken.md" }!
        let a = env.open(note)

        guard case .unreadable(let message) = a.state else { return XCTFail("expected unreadable, got \(a.state)") }
        XCTAssertFalse(message.isEmpty)

        let h = host(a)
        XCTAssertFalse(h.textView.isEditable)
        h.type("abc")
        h.press(.enter)
        XCTAssertEqual(h.string, "", "typing is not possible")
        a.setTitle("Renamed")
        env.scheduler.fire()
        await a.flush()
        await env.store.flushOpenNotes()
        XCTAssertEqual(env.scheduler.scheduleCount, 0, "no save path")
        XCTAssertFalse(a.isDirty)
        XCTAssertEqual(try env.bytes(note), broken, "the file's bytes never change")
    }

    func testUnreadableByPermissionOpensReadOnly() async throws {
        let (env, notes) = try await makeEnv(["secret\n"])
        let path = env.url(notes[0]).path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        let a = env.open(notes[0])
        guard case .unreadable = a.state else { return XCTFail("expected unreadable") }
        XCTAssertFalse(host(a).textView.isEditable)
    }

    func testReadableNoteIsEditable() async throws {
        let (env, notes) = try await makeEnv(["fine\n"])
        let a = env.open(notes[0])
        XCTAssertEqual(a.state, .editable)
        XCTAssertTrue(host(a).textView.isEditable)
    }

    func testSwitchingFromUnreadableToReadableRestoresEditing() async throws {
        let (env, notes) = try await makeEnv(["fine\n"])
        try Data([0xFF]).write(to: env.folder.url.appendingPathComponent("broken.md"))
        await env.store.reload()
        let broken = env.store.notes.first { $0.filename == "broken.md" }!
        let h = host(env.open(broken))
        XCTAssertFalse(h.textView.isEditable)
        h.textView.attach(env.open(notes[0]).content)
        XCTAssertTrue(h.textView.isEditable)
        XCTAssertEqual(h.string, "fine\n")
    }

    // MARK: 4. Flush on switch, dismiss and quit

    func testFlushWritesPendingSaveWithoutWaitingForDebounce() async throws {
        let (env, notes) = try await makeEnv(["alpha\n", "beta\n"])
        let a = env.open(notes[0]), b = env.open(notes[1])
        let h = host(a)
        h.type("x")
        // Note switch: the pane flushes every open note when the selection changes.
        h.textView.attach(b.content)
        await env.store.flushOpenNotes()
        XCTAssertEqual(try env.bytes(notes[0]), Data("xalpha\n".utf8))
        XCTAssertFalse(a.isDirty)
        XCTAssertNil(env.scheduler.pending, "the debounce no longer holds the save")
    }

    func testFlushCoversEveryOpenNote() async throws {
        let (env, notes) = try await makeEnv(["alpha\n", "beta\n"])
        let a = env.open(notes[0]), b = env.open(notes[1])
        let h = host(a)
        h.type("1")
        h.textView.attach(b.content)
        h.type("2")
        await env.store.flushOpenNotes()   // quit / panel dismiss
        XCTAssertEqual(try env.bytes(notes[0]), Data("1alpha\n".utf8))
        XCTAssertEqual(try env.bytes(notes[1]), Data("2beta\n".utf8))
    }

    func testOpenNoteIsReusedForTheSession() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        XCTAssertTrue(env.open(notes[0]) === env.open(notes[0]))
    }

    // MARK: 5. Failed saves

    func testFailedSaveKeepsNoteDirtyAndRetrySucceeds() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("x")
        let folderPath = env.folder.url.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folderPath)
        await a.flush()
        XCTAssertTrue(a.saveFailed)
        XCTAssertTrue(a.isDirty, "a failed save never shows as saved")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderPath)
        await a.retrySave()
        XCTAssertFalse(a.saveFailed)
        XCTAssertFalse(a.isDirty)
        XCTAssertEqual(try env.bytes(notes[0]), Data("xalpha\n".utf8))
    }

    // MARK: Title

    func testTitleChangeSavesThroughTheNoteWithItsCurrentText() async throws {
        let (env, notes) = try await makeEnv(["alpha\n"])
        let a = env.open(notes[0])
        let h = host(a)
        h.type("x")
        a.setTitle("My title")
        await a.commitTitle()
        let updated = env.store.notes.first { $0.id == notes[0].id }!
        XCTAssertEqual(updated.title, "My title")
        XCTAssertEqual(try env.bytes(updated), Data("xalpha\n".utf8))
    }
}
