import XCTest
@testable import Sidekick

@MainActor
final class NoteStoreIntegrationTests: XCTestCase {

    func testCreateWritesFile() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let note = await store.create()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tmp.url.appendingPathComponent(note.filename).path
            )
        )
    }

    func testAtomicWriteCleanup() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let note = await store.create()
        try await store.update(note.id, body: "# Hello\nsome content")

        let contents = try FileManager.default.contentsOfDirectory(
            at: tmp.url,
            includingPropertiesForKeys: nil
        )
        let tmpFiles = contents.filter { $0.lastPathComponent.hasSuffix(".md.tmp") }
        XCTAssertTrue(tmpFiles.isEmpty, "Found residual .md.tmp files: \(tmpFiles)")
    }

    func testIndexRoundTrip() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)

        let note1 = await store.create()
        let note2 = await store.create()
        try await store.setPinned(note1.id, true)
        try await store.reorder([note1.id, note2.id])

        // Capture state before teardown.
        let beforeNotes = store.notes
        XCTAssertEqual(beforeNotes.count, 2)

        // Instantiate a fresh store pointed at the same folder.
        let store2 = try NoteStore(folder: tmp.url)
        await store2.reload()

        XCTAssertEqual(store2.notes.count, 2)
        // UUIDs survive restart.
        let ids2 = Set(store2.notes.map(\.id))
        XCTAssertEqual(ids2, Set(beforeNotes.map(\.id)))
        // Pin state survives restart.
        let pinnedInStore2 = store2.notes.first { $0.id == note1.id }?.pinned
        XCTAssertEqual(pinnedInStore2, true)
    }

    func testCorruptIndexRecovery() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        _ = await store.create()

        // Write garbage to .index.json.
        let indexURL = tmp.url.appendingPathComponent(".index.json")
        try "not json".write(to: indexURL, atomically: true, encoding: .utf8)

        // New store should recover: move corrupt file to .bak, rebuild from scan.
        let store2 = try NoteStore(folder: tmp.url)
        await store2.reload()

        let bakURL = tmp.url.appendingPathComponent(".index.json.bak")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bakURL.path),
            ".index.json.bak should exist after corrupt recovery"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexURL.path),
            ".index.json should be rebuilt"
        )
        // Verify the rebuilt index is valid JSON.
        let data = try Data(contentsOf: indexURL)
        XCTAssertNoThrow(try JSONDecoder().decode(NoteIndex.self, from: data))
        XCTAssertEqual(store2.notes.count, 1)
    }

    func testRenameOnHeadingChange() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let note = await store.create()
        let originalFilename = note.filename

        try await store.update(note.id, body: "# Hello World\ncontent")

        // New filename should be slug of heading.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tmp.url.appendingPathComponent("hello-world.md").path
            ),
            "hello-world.md should exist"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmp.url.appendingPathComponent(originalFilename).path
            ),
            "Original untitled-* file should be gone after rename"
        )
        XCTAssertEqual(store.notes.first?.filename, "hello-world.md")
    }
}
