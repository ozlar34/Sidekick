import XCTest
@testable import Sidekick

/// A delete can be undone: the file comes back from the Trash with its id, body, pin and place in the list.
/// The "Trash" here is a second temp folder, so nothing touches the real Trash.
@MainActor
final class DeleteUndoTests: XCTestCase {

    private func makeStore(_ folder: TempFolder, trash: TempFolder) throws -> NoteStore {
        let bin = trash.url
        return try NoteStore(folder: folder.url, startWatcherImmediately: false, trash: { url in
            let dest = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }, persistFolder: { _ in })
    }

    private func write(_ name: String, _ text: String, in folder: TempFolder) throws {
        try Data(text.utf8).write(to: folder.url.appendingPathComponent(name))
    }

    func testUndoBringsTheNoteBackWithItsIdBodyPinAndPlace() async throws {
        let folder = TempFolder(), bin = TempFolder()
        for name in ["A.md", "B.md", "C.md"] { try write(name, "body of \(name)\n", in: folder) }
        let store = try makeStore(folder, trash: bin)
        await store.reload()
        let b = try XCTUnwrap(store.notes.first { $0.filename == "B.md" })
        try await store.setPinned(b.id, true)
        let before = store.notes.map(\.filename)

        try await store.delete(b.id)
        XCTAssertFalse(store.notes.contains { $0.id == b.id })
        XCTAssertEqual(store.lastDeleted?.id, b.id)

        let restored = try await store.undoDelete()
        XCTAssertEqual(restored, b.id, "the note keeps its id, so the selection can follow it")
        XCTAssertNil(store.lastDeleted, "one undo per delete")
        XCTAssertEqual(store.notes.map(\.filename), before, "back in its place")
        let back = try XCTUnwrap(store.notes.first { $0.id == b.id })
        XCTAssertTrue(back.pinned)
        XCTAssertEqual(back.body, "body of B.md\n")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: bin.url.path).isEmpty, "the file left the Trash")
    }

    func testUndoNeverReplacesAFileThatTookTheName() async throws {
        let folder = TempFolder(), bin = TempFolder()
        try write("A.md", "old\n", in: folder)
        let store = try makeStore(folder, trash: bin)
        await store.reload()
        let a = try XCTUnwrap(store.notes.first)
        try await store.delete(a.id)
        try write("A.md", "new\n", in: folder)

        _ = try await store.undoDelete()
        XCTAssertEqual(try String(contentsOf: folder.url.appendingPathComponent("A.md"), encoding: .utf8), "new\n")
        XCTAssertEqual(try String(contentsOf: folder.url.appendingPathComponent("A 2.md"), encoding: .utf8), "old\n")
    }

    func testNothingToUndo_whenTheFileIsGoneForGood() async throws {
        let folder = TempFolder()
        try write("A.md", "x\n", in: folder)
        let store = try NoteStore(folder: folder.url, startWatcherImmediately: false,
                                  trash: { try FileManager.default.removeItem(at: $0); return nil }, persistFolder: { _ in })
        await store.reload()
        try await store.delete(try XCTUnwrap(store.notes.first).id)
        XCTAssertNil(store.lastDeleted)
        let restored = try await store.undoDelete()
        XCTAssertNil(restored)
    }

    func testOnlyTheLatestDeleteCanBeUndone() async throws {
        let folder = TempFolder(), bin = TempFolder()
        for name in ["A.md", "B.md"] { try write(name, "x\n", in: folder) }
        let store = try makeStore(folder, trash: bin)
        await store.reload()
        let a = store.notes[0], b = store.notes[1]
        try await store.delete(a.id)
        try await store.delete(b.id)
        XCTAssertEqual(store.lastDeleted?.id, b.id)
        let restored = try await store.undoDelete()
        XCTAssertEqual(restored, b.id)
        XCTAssertEqual(store.notes.map(\.id), [b.id], "A stays in the Trash")
    }
}
