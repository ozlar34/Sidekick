import XCTest
import AppKit
@testable import Sidekick

/// Ticket 16: the `.md` files are the notes. Identity = filename, title = filename without ".md",
/// the order file holds only pins and order. Every test makes its own folder; nothing touches the
/// shared defaults or the Trash.
@MainActor
final class FilesAreTruthTests: XCTestCase {

    // MARK: helpers

    private func makeStore(_ folder: TempFolder, watcher: Bool = false) throws -> NoteStore {
        try NoteStore(folder: folder.url, startWatcherImmediately: watcher,
                      trash: { try FileManager.default.removeItem(at: $0) }, persistFolder: { _ in })
    }

    private func write(_ name: String, _ text: String, in folder: TempFolder, modified: TimeInterval? = nil) throws {
        let url = folder.url.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        }
    }

    private func bytes(_ name: String, in folder: TempFolder) throws -> Data {
        try Data(contentsOf: folder.url.appendingPathComponent(name))
    }

    private func listing(_ folder: TempFolder) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // MARK: 1. A folder of plain .md files is complete

    func testPlainFolderOpensWithTitlesFromFilenamesAndWritesNothing() async throws {
        let folder = TempFolder()
        try write("Meeting notes.md", "# Agenda\nitems\n", in: folder, modified: 1_700_000_000)
        try write("Ideas.md", "one\n", in: folder, modified: 1_700_000_500)
        let before = try FolderTree.snapshot(folder.url)

        let store = try makeStore(folder)
        await store.reload()

        XCTAssertEqual(store.notes.map(\.title), ["Ideas", "Meeting notes"], "titles are the filenames; newest first")
        XCTAssertEqual(store.notes.map(\.body), ["one\n", "# Agenda\nitems\n"])
        XCTAssertTrue(store.notes.allSatisfy { !$0.pinned })
        XCTAssertEqual(try FolderTree.snapshot(folder.url), before, "opening a plain folder writes no file")
    }

    func testDatesComeFromTheFileSystem() async throws {
        let folder = TempFolder()
        try write("Dated.md", "x\n", in: folder, modified: 1_700_000_000)
        let url = folder.url.appendingPathComponent("Dated.md")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)

        let store = try makeStore(folder)
        await store.reload()

        let note = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(note.modified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(note.createdAt, Date(timeIntervalSince1970: 1_600_000_000))
    }

    func testCreatedDateSurvivesSavesAndRenames() async throws {
        let folder = TempFolder()
        try write("Old.md", "x\n", in: folder)
        let url = folder.url.appendingPathComponent("Old.md")
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        let store = try makeStore(folder)
        await store.reload()
        let id = try XCTUnwrap(store.notes.first).id

        try await store.update(id, title: "Old", body: "y\n")
        try await store.update(id, title: "New name", body: "z\n")

        XCTAssertEqual(store.notes.first?.createdAt, created)
        let onDisk = try folder.url.appendingPathComponent("New name.md").resourceValues(forKeys: [.creationDateKey]).creationDate
        XCTAssertEqual(onDisk, created, "the file's own creation date is kept through the write and the rename")
    }

    // MARK: 2. The order file

    func testArrangeAppendsUnknownFilesNewestFirstAndIgnoresUnknownNames() {
        let order = OrderFile(pinned: ["gone.md", "b.md"], order: ["b.md", "gone.md", "a.md"])
        let disk = [
            DiskEntry(filename: "a.md", mtime: Date(timeIntervalSince1970: 10)),
            DiskEntry(filename: "b.md", mtime: Date(timeIntervalSince1970: 20)),
            DiskEntry(filename: "old.md", mtime: Date(timeIntervalSince1970: 1)),
            DiskEntry(filename: "new.md", mtime: Date(timeIntervalSince1970: 99)),
        ]
        let arranged = order.arrange(disk)
        XCTAssertEqual(arranged.map(\.filename), ["b.md", "a.md", "new.md", "old.md"])
        XCTAssertEqual(arranged.filter(\.pinned).map(\.filename), ["b.md"], "a pin for a missing file is ignored")
    }

    func testPinsAndOrderSurviveARestart() async throws {
        let folder = TempFolder()
        let store = try makeStore(folder)
        let a = try await store.create(), b = try await store.create(), c = try await store.create()
        try await store.setPinned(b.id, true)
        try await store.reorder([c.id, a.id, b.id])
        let expected = store.notes.map { "\($0.filename)|\($0.pinned)" }

        let store2 = try makeStore(folder)
        await store2.reload()

        XCTAssertEqual(store2.notes.map { "\($0.filename)|\($0.pinned)" }, expected)
        XCTAssertEqual(expected.first, "\(try XCTUnwrap(store.notes.first).filename)|true", "pinned first")
    }

    func testDeletingTheOrderFileLosesOnlyPinsAndOrder() async throws {
        let folder = TempFolder()
        let store = try makeStore(folder)
        let a = try await store.create()
        try await store.update(a.id, title: "Alpha", body: "alpha text\n")
        let b = try await store.create()
        try await store.update(b.id, title: "Beta", body: "beta text\n")
        try await store.setPinned(b.id, true)
        let files = try listing(folder).filter { $0.hasSuffix(".md") }
        let contents = try files.map { try bytes($0, in: folder) }

        try FileManager.default.removeItem(at: folder.url.appendingPathComponent(OrderFile.filename))
        let store2 = try makeStore(folder)
        await store2.reload()

        XCTAssertEqual(Set(store2.notes.map(\.title)), ["Alpha", "Beta"], "titles do not depend on the order file")
        XCTAssertEqual(Set(store2.notes.map(\.body)), ["alpha text\n", "beta text\n"])
        XCTAssertTrue(store2.notes.allSatisfy { !$0.pinned })
        XCTAssertEqual(try files.map { try bytes($0, in: folder) }, contents, "no note file changed")
    }

    func testACorruptOrderFileLosesOnlyPinsAndOrderAndIsRebuilt() async throws {
        for garbage in ["not json", "{\"version\":2,\"pinned\":\"x\"}", "", "[1,2,3]", "{\"version\":2,\"pinned\":[\"a.md\",", "\u{0}\u{1}"] {
            let folder = TempFolder()
            try write("Alpha.md", "alpha\n", in: folder, modified: 1_700_000_000)
            try write("Beta.md", "beta\n", in: folder, modified: 1_700_000_100)
            try write(OrderFile.filename, garbage, in: folder)

            let store = try makeStore(folder)
            await store.reload()

            XCTAssertEqual(store.notes.map(\.title), ["Beta", "Alpha"], "falls back to newest first for \(garbage.debugDescription)")
            XCTAssertTrue(store.notes.allSatisfy { !$0.pinned })
            XCTAssertEqual(try bytes("Alpha.md", in: folder), Data("alpha\n".utf8))
            XCTAssertEqual(try bytes("Beta.md", in: folder), Data("beta\n".utf8))
            let rebuilt = try Data(contentsOf: folder.url.appendingPathComponent(OrderFile.filename))
            XCTAssertNotNil(OrderFile.decode(rebuilt), "the order file is rebuilt as valid for \(garbage.debugDescription)")
        }
    }

    func testAnOrderFileNamingUnknownFilesIsIgnoredAndHarmless() async throws {
        let folder = TempFolder()
        try write("Alpha.md", "alpha\n", in: folder)
        let order = OrderFile(pinned: ["Nope.md", "../escape.md"], order: ["Nope.md", "Alpha.md", "../escape.md"])
        try JSONEncoder().encode(order).write(to: folder.url.appendingPathComponent(OrderFile.filename))
        let store = try makeStore(folder)
        await store.reload()
        XCTAssertEqual(store.notes.map(\.title), ["Alpha"])
        XCTAssertEqual(store.notes.first?.pinned, false)
    }

    // MARK: 3. Title commit

    func testTitleCommitRenamesTheFileOnceAndKeepsTheNoteIdentityInTheSession() async throws {
        let folder = TempFolder()
        try write("Draft.md", "text\n", in: folder)
        let store = try makeStore(folder)
        await store.reload()
        let note = try XCTUnwrap(store.notes.first)
        let scheduler = ManualScheduler()
        let open = try XCTUnwrap(store.openNote(note.id, scheduler: scheduler))

        open.setTitle("T")
        open.setTitle("Ti")
        open.setTitle("Title")
        XCTAssertEqual(try listing(folder).filter { $0.hasSuffix(".md") }, ["Draft.md"], "typing in the title renames nothing")
        XCTAssertEqual(scheduler.scheduleCount, 0, "no save is scheduled per keystroke of the title")

        await open.commitTitle()
        XCTAssertEqual(try listing(folder).filter { $0.hasSuffix(".md") }, ["Title.md"])
        XCTAssertEqual(try bytes("Title.md", in: folder), Data("text\n".utf8))
        XCTAssertEqual(store.notes.first?.id, note.id)
        XCTAssertEqual(store.notes.first?.title, "Title")

        let beforeSecond = try FolderTree.snapshot(folder.url)
        await open.commitTitle()
        XCTAssertEqual(try FolderTree.snapshot(folder.url), beforeSecond, "a second commit changes nothing")
    }

    func testFilenameRulesTable() {
        func base(_ t: String) -> String { TitleRules.fileBase(forTitle: t) }
        XCTAssertEqual(base("Plain title"), "Plain title")
        XCTAssertEqual(base("A/B"), "A-B")
        XCTAssertEqual(base("Time: 12:30"), "Time- 12-30")
        XCTAssertEqual(base("...hidden"), "hidden", "a leading dot would hide the file")
        XCTAssertEqual(base(".md"), "md")
        XCTAssertEqual(base("."), "Untitled")
        XCTAssertEqual(base(".."), "Untitled")
        XCTAssertEqual(base(""), "Untitled")
        XCTAssertEqual(base("   \n\t "), "Untitled")
        XCTAssertEqual(base("  padded  "), "padded")
        XCTAssertEqual(base("Party \u{1F389}"), "Party \u{1F389}")
        XCTAssertEqual(base("tab\there\u{0}nul"), "tab-here-nul", "control characters are replaced")
        XCTAssertEqual(base("trailing dots..."), "trailing dots")
        let long = base(String(repeating: "\u{1F389}", count: 300))
        XCTAssertLessThanOrEqual(long.utf8.count, 200, "room is left for the extension and a suffix inside 255 bytes")
        XCTAssertFalse(long.isEmpty)
        XCTAssertEqual(long, String(repeating: "\u{1F389}", count: long.unicodeScalars.count), "never cut inside a character")
    }

    func testPlaceholderNamesAreTheOnesANewNoteGets() {
        for name in ["Untitled", "Untitled 2", "Untitled 17"] { XCTAssertTrue(TitleRules.isPlaceholder(name), name) }
        for name in ["", "Untitled notes", "untitled", "Untitled 2b", "My Untitled"] { XCTAssertFalse(TitleRules.isPlaceholder(name), name) }
    }

    func testEveryTitleCommitCreatesAFileThatIsListedAndKeepsItsText() async throws {
        let titles = ["A/B", "Time: 12:30", "...dots", "Party \u{1F389}", "", "   ", ".", "..", "x.md", String(repeating: "long ", count: 80), "Caf\u{E9}"]
        let folder = TempFolder()
        let store = try makeStore(folder)
        for (i, title) in titles.enumerated() {
            let n = try await store.create()
            try await store.update(n.id, title: title, body: "body \(i)\n")
        }
        await store.reload()
        XCTAssertEqual(store.notes.count, titles.count, "no title made a note vanish or collide")
        XCTAssertEqual(Set(store.notes.map(\.body)), Set((0..<titles.count).map { "body \($0)\n" }))
        let mdFiles = try listing(folder).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(mdFiles.count, titles.count)
        XCTAssertTrue(mdFiles.allSatisfy { !$0.hasPrefix(".") && $0.utf8.count <= 255 })
    }

    func testACollidingTitleGetsASuffixAndTheTitleShowsTheRealName() async throws {
        let folder = TempFolder()
        let store = try makeStore(folder)
        let a = try await store.create(), b = try await store.create()
        try await store.update(a.id, title: "Foo", body: "a\n")
        let scheduler = ManualScheduler()
        let open = try XCTUnwrap(store.openNote(b.id, scheduler: scheduler))
        open.setTitle("Foo")
        await open.commitTitle()

        XCTAssertEqual(store.notes.first { $0.id == b.id }?.title, "Foo 2")
        XCTAssertEqual(open.title, "Foo 2", "the open note adopts the real name, so the field shows it")
        XCTAssertEqual(try bytes("Foo.md", in: folder), Data("a\n".utf8), "the other note is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Foo 2.md").path))
        XCTAssertFalse(open.isDirty)

        // Committing the name it already has (or its plain form) changes nothing.
        open.setTitle("Foo")
        await open.commitTitle()
        XCTAssertEqual(store.notes.first { $0.id == b.id }?.title, "Foo 2")
        XCTAssertEqual(try listing(folder).filter { $0.hasSuffix(".md") }.sorted(), ["Foo 2.md", "Foo.md"])
    }

    func testARenameNeverOverwritesAFileTheStoreHasNotSeen() async throws {
        let folder = TempFolder()
        let store = try makeStore(folder)
        let n = try await store.create()
        try await store.update(n.id, title: "Mine", body: "mine\n")
        // Another tool creates Foo.md; the store has not reloaded, so no index could know about it.
        try write("Foo.md", "someone else's note\n", in: folder)

        try await store.update(n.id, title: "Foo", body: "mine again\n")

        XCTAssertEqual(try bytes("Foo.md", in: folder), Data("someone else's note\n".utf8))
        XCTAssertEqual(try bytes("Foo 2.md", in: folder), Data("mine again\n".utf8))
        XCTAssertEqual(store.notes.first?.title, "Foo 2")
    }

    func testCreateNeverOverwritesAnExistingFile() async throws {
        let folder = TempFolder()
        try write("Untitled.md", "keep me\n", in: folder)
        try write("untitled 2.md", "me too\n", in: folder)       // differs by case: on APFS this is the same name as "Untitled 2.md"
        let store = try makeStore(folder)

        let n = try await store.create()

        XCTAssertEqual(try bytes("Untitled.md", in: folder), Data("keep me\n".utf8))
        XCTAssertEqual(try bytes("untitled 2.md", in: folder), Data("me too\n".utf8))
        XCTAssertNotEqual(n.filename, "Untitled.md")
        XCTAssertNotEqual(n.filename, "untitled 2.md")
        XCTAssertEqual(try listing(folder).filter { $0.hasSuffix(".md") }.count, 3)
    }

    func testACaseOnlyRenameIsNotACollisionWithItself() async throws {
        let folder = TempFolder()
        try write("ideas.md", "lower\n", in: folder)
        let store = try makeStore(folder)
        await store.reload()
        let id = try XCTUnwrap(store.notes.first).id

        try await store.update(id, title: "Ideas", body: "lower\n")

        XCTAssertEqual(try listing(folder).filter { $0.hasSuffix(".md") }, ["Ideas.md"], "renamed in place, not 'Ideas 2'")
        XCTAssertEqual(store.notes.first?.title, "Ideas")
        XCTAssertEqual(try bytes("Ideas.md", in: folder), Data("lower\n".utf8))
    }

    func testACaseDifferingTitleDoesNotClobberAnotherNote() async throws {
        let folder = TempFolder()
        try write("IDEAS.md", "upper\n", in: folder)
        try write("Other.md", "other\n", in: folder)
        let store = try makeStore(folder)
        await store.reload()
        let other = try XCTUnwrap(store.notes.first { $0.title == "Other" })

        try await store.update(other.id, title: "ideas", body: "other\n")

        XCTAssertEqual(try bytes("IDEAS.md", in: folder), Data("upper\n".utf8))
        XCTAssertEqual(store.notes.first { $0.id == other.id }?.title, "ideas 2")
        XCTAssertEqual(try listing(folder).filter { $0.hasSuffix(".md") }.count, 2)
    }

    func testAConflictedSaveRenamesNothingAndCreatesNothing() async throws {
        let folder = TempFolder()
        try write("Draft.md", "a\n", in: folder)
        let store = try makeStore(folder)
        await store.reload()
        let id = try XCTUnwrap(store.notes.first).id
        try Data("theirs\n".utf8).write(to: folder.url.appendingPathComponent("Draft.md"))
        let before = try FolderTree.snapshot(folder.url)

        do { try await store.save(id, title: "Renamed", body: "mine\n", baseline: Data("a\n".utf8)); XCTFail("expected a conflict") }
        catch { XCTAssertEqual(error as? NoteStoreError, .conflict) }

        XCTAssertEqual(try FolderTree.snapshot(folder.url), before)
    }

    func testDeleteRemovesTheNoteFromTheOrderFile() async throws {
        let folder = TempFolder()
        let store = try makeStore(folder)
        let a = try await store.create(), b = try await store.create()
        try await store.setPinned(a.id, true)
        try await store.delete(a.id)
        let data = try Data(contentsOf: folder.url.appendingPathComponent(OrderFile.filename))
        let order = try XCTUnwrap(OrderFile.decode(data))
        XCTAssertEqual(order.pinned, [])
        XCTAssertEqual(order.order, [b.filename])
    }

    // MARK: Last selected note, by filename

    func testTheLastSelectedNoteIsRestoredByFilename() {
        let a = Note(id: UUID(), filename: "A.md", body: "", pinned: false, order: 0)
        let b = Note(id: UUID(), filename: "B.md", body: "", pinned: false, order: 1)
        XCTAssertEqual(SelectionMemory.restored(lastFilename: "B.md", in: [a, b]), b.id)
        XCTAssertNil(SelectionMemory.restored(lastFilename: "Gone.md", in: [a, b]))
        XCTAssertNil(SelectionMemory.restored(lastFilename: "", in: [a, b]))
        // A new session has new ids for the same files: the filename is what is remembered.
        let b2 = Note(id: UUID(), filename: "B.md", body: "", pinned: false, order: 0)
        XCTAssertEqual(SelectionMemory.restored(lastFilename: "B.md", in: [b2]), b2.id)
    }

    // MARK: 5. Another tool adds, renames or removes a file (real watcher, condition polling)

    func testRealWatcherShowsAFileAddedRenamedAndRemovedByAnotherTool() async throws {
        let folder = TempFolder()
        try write("Existing.md", "e\n", in: folder)
        let store = try makeStore(folder, watcher: true)
        await store.reload()
        XCTAssertEqual(store.notes.map(\.title), ["Existing"])

        // Added
        try write("From Obsidian.md", "added outside\n", in: folder)
        try await waitFor("the added file to appear") { store.notes.contains { $0.title == "From Obsidian" } }
        XCTAssertEqual(store.notes.first { $0.title == "From Obsidian" }?.body, "added outside\n")

        // Renamed
        try FileManager.default.moveItem(at: folder.url.appendingPathComponent("From Obsidian.md"),
                                         to: folder.url.appendingPathComponent("Renamed outside.md"))
        try await waitFor("the rename to show") {
            store.notes.contains { $0.title == "Renamed outside" } && !store.notes.contains { $0.title == "From Obsidian" }
        }
        XCTAssertEqual(store.notes.first { $0.title == "Renamed outside" }?.body, "added outside\n")

        // Removed
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("Renamed outside.md"))
        try await waitFor("the removal to show") { !store.notes.contains { $0.title == "Renamed outside" } }
        XCTAssertEqual(store.notes.map(\.title), ["Existing"])
    }
}
