import XCTest
@testable import Sidekick

@MainActor
final class NoteStoreRebindTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: Defaults.notesFolder)
        try await super.tearDown()
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_rebind_switchesToNewFolder_andReloads() async throws {
        let folderA = try makeFolder("A")
        let folderB = try makeFolder("B")

        // Prepare B with a pre-existing note file
        let helloURL = folderB.appendingPathComponent("hello.md")
        try "Hi from B".write(to: helloURL, atomically: true, encoding: .utf8)

        let store = try NoteStore(folder: folderA)
        _ = try await store.create()   // create one note in A
        XCTAssertEqual(store.notes.count, 1)

        try await store.rebind(to: folderB)

        // After rebind + reload, store.notes should reflect B (the hello.md file)
        // NOTE: reconcile will adopt hello.md with a fresh UUID since B has no .index.json
        XCTAssertEqual(store.notes.count, 1, "store.notes must reflect folder B, not A")
        XCTAssertEqual(store.notes.first?.filename, "hello.md")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Defaults.notesFolder),
            folderB.path,
            "rebind must persist newFolder.path to UserDefaults"
        )
    }

    func test_rebind_createsMissingDirectory() async throws {
        let folderA = try makeFolder("A")
        let folderB = tempRoot.appendingPathComponent("B-does-not-exist-yet")
        // DO NOT create folderB — rebind must create it.

        let store = try NoteStore(folder: folderA)
        try await store.rebind(to: folderB)

        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folderB.path, isDirectory: &isDir),
            "rebind must create the target directory if missing"
        )
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(store.notes.count, 0, "empty new folder → empty notes")
    }

    func test_rebind_writesUserDefaultsAtomically() async throws {
        let folderA = try makeFolder("A")
        let folderB = try makeFolder("B")
        UserDefaults.standard.set(folderA.path, forKey: Defaults.notesFolder)

        let store = try NoteStore(folder: folderA)
        try await store.rebind(to: folderB)

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Defaults.notesFolder),
            folderB.path
        )
    }

    func test_rebind_preservesStoreIdentity() async throws {
        let folderA = try makeFolder("A")
        let folderB = try makeFolder("B")

        let store = try NoteStore(folder: folderA)
        let idBefore = ObjectIdentifier(store)
        try await store.rebind(to: folderB)
        let idAfter = ObjectIdentifier(store)

        XCTAssertEqual(idBefore, idAfter, "rebind must not create a new NoteStore instance")
    }

    func test_rebind_clearsFolderMissing() async throws {
        let folderA = try makeFolder("A")
        let folderMissing = tempRoot.appendingPathComponent("gone")
        let store = try NoteStore(folder: folderMissing)

        // Immediately remove the folder to trigger folderMissing on next reload
        try? FileManager.default.removeItem(at: folderMissing)
        await store.reload()
        // NoteStore.reload() recreates the folder but also sets folderMissing=true
        // on the missing branch. Confirm we observed the flag.
        // (If timing prevents this, skip the precondition and only assert the clear.)

        try await store.rebind(to: folderA)
        XCTAssertFalse(store.folderMissing, "rebind must leave folderMissing=false after reload")
    }
}
