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

    // MARK: - Watcher integration tests (plan 02-02)

    /// Wait until predicate is true or timeout elapses (default 2s).
    private func waitFor(
        _ predicate: @escaping () async -> Bool,
        timeout: TimeInterval = 2.0,
        description: String = "condition"
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        XCTFail("Timed out waiting for \(description)")
    }

    /// 2-02-01: External create is detected via watcher
    func testWatcherDetectsExternalCreate() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)

        // Let the watcher settle after init.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Collect first externalChanges event in background.
        var receivedEvent = false
        let eventTask = Task { @MainActor in
            for await _ in store.externalChanges {
                receivedEvent = true
                break
            }
        }

        // Write a new .md file externally.
        let outsideURL = tmp.url.appendingPathComponent("outside.md")
        try "# Outside\ncontent".write(to: outsideURL, atomically: true, encoding: .utf8)

        // Wait for NoteStore to pick up the new file.
        try await waitFor(
            { store.notes.count == 1 },
            timeout: 3.0,
            description: "store.notes.count == 1 after external create"
        )
        XCTAssertEqual(store.notes.first?.filename, "outside.md")

        // Give event task a moment to receive.
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        eventTask.cancel()
        XCTAssertTrue(receivedEvent, "externalChanges should have fired at least once")
    }

    /// 2-02-02: External edit is detected and body is updated
    func testWatcherDetectsExternalEdit() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let note = await store.create()
        let filename = note.filename

        // Let watcher settle (avoid detecting our own create as external).
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Externally overwrite the file.
        let fileURL = tmp.url.appendingPathComponent(filename)
        try "# New body\ncontent".write(to: fileURL, atomically: true, encoding: .utf8)

        // Wait for reconcile to pick up the new body.
        try await waitFor(
            { store.notes.first?.body.contains("New body") == true },
            timeout: 3.0,
            description: "note body updated after external edit"
        )

        // External edits do NOT trigger rename — filename must be unchanged.
        XCTAssertEqual(store.notes.first?.filename, filename,
                       "External edit must not rename the file")
        XCTAssertTrue(store.notes.first?.body.contains("New body") == true)
    }

    /// 2-02-03: External delete is detected and note is removed
    func testWatcherDetectsExternalDelete() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let note = await store.create()
        let filename = note.filename
        XCTAssertEqual(store.notes.count, 1)

        // Let watcher settle.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Externally delete the file.
        let fileURL = tmp.url.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: fileURL)

        // Wait for reconcile to remove the note.
        try await waitFor(
            { store.notes.isEmpty },
            timeout: 3.0,
            description: "store.notes.isEmpty after external delete"
        )
        XCTAssertTrue(store.notes.isEmpty)
    }

    /// 2-02-04: Rapid burst of external writes coalesces to consistent final state
    func testWatcherCoalescesBursts() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let note = await store.create()
        let filename = note.filename

        // Let watcher settle.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Write the same file 20 times in rapid succession.
        let fileURL = tmp.url.appendingPathComponent(filename)
        for i in 0..<20 {
            try "# Burst \(i)\ncontent".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // Wait well beyond the 150ms debounce for final state to settle.
        try await Task.sleep(nanoseconds: 400_000_000) // 400ms

        // Wait for reconcile to finish.
        try await waitFor(
            { store.notes.first?.body.contains("Burst 19") == true },
            timeout: 3.0,
            description: "final burst state: body contains Burst 19"
        )

        // Final state is consistent with the last write.
        XCTAssertEqual(store.notes.count, 1,
                       "Burst writes must not corrupt the note count")
        XCTAssertTrue(store.notes.first?.body.contains("Burst 19") == true,
                      "Final body should reflect the last burst write")
    }

    /// 2-02-05: Folder deletion recovers — watcher is restarted on recreated folder
    func testFolderDeletionRecovery() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        _ = await store.create()
        XCTAssertEqual(store.notes.count, 1)

        // Delete the entire notes folder.
        try FileManager.default.removeItem(at: tmp.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.url.path),
                       "Folder should be gone after removal")

        // Wait briefly for watcher to detect the deletion.
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // Force reload — this triggers folder recreation and watcher restart.
        await store.reload()

        // (a) Folder exists again.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.url.path),
                      "Folder should be recreated after reload()")

        // (b) Notes are empty (file was in deleted folder — acceptable for v1).
        XCTAssertTrue(store.notes.isEmpty,
                      "Notes should be empty after folder was deleted")

        // (c) Watcher is live on the fresh folder — write a new file externally
        //     and verify it is detected.
        let recoveredURL = tmp.url.appendingPathComponent("recovered.md")
        try "# Recovered\n".write(to: recoveredURL, atomically: true, encoding: .utf8)

        try await waitFor(
            { store.notes.count == 1 },
            timeout: 3.0,
            description: "store.notes.count == 1 after watcher restart"
        )
        XCTAssertEqual(store.notes.count, 1,
                       "Watcher must detect new files after folder recreation")
    }
}
