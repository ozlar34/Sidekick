import XCTest
@testable import Sidekick

/// Ticket 16: the one-time migration from slug filenames plus `.index.json` to title filenames plus
/// the order file. Runs only on synthetic folders built in a temp directory; content is invented.
@MainActor
final class MigrationTests: XCTestCase {

    private let today = Date(timeIntervalSince1970: 1_800_000_000)   // fixed: the backup name and marker are reproducible

    /// A fresh parent holding `Notes/` so the dated backup has somewhere to go "beside" the folder.
    private func makeParent() throws -> (parent: URL, notes: URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationTests-\(UUID().uuidString)")
        let notes = parent.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return (parent, notes)
    }

    private func backups(_ parent: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Notes-backup-") && !$0.lastPathComponent.hasSuffix(".partial") }
    }

    private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// What each fixture slug must be called afterwards.
    private var expectedNames: [String: String] {
        let long = TitleRules.fileBase(forTitle: OldFormatFixture.longTitle)
        return [
            "meeting-notes": "Meeting notes.md",
            "a-b-plan": "A-B plan.md",
            "time-12-30": "Time- 12-30.md",
            "dotted": "hidden-.md",
            "party": "Party \u{1F389}.md",
            "same": "Same.md",
            "same-2": "Same 2.md",
            "untitled-1a2b3c4d": "Untitled.md",                 // empty title becomes "Untitled"
            "long": long + ".md",
            "ideas": "Ideas.md",
            "ideas-2": "ideas 2.md",
            "cafe": "Caf\u{E9}.md",
            "cafe-2": "cafe.md",
            "no-title-key": "no-title-key.md",                 // index entry without a title key: keeps its name
        ]
    }

    // MARK: the full migration

    func testMigrationTurnsAnOldFolderIntoTheNewFormat() throws {
        let (parent, notes) = try makeParent()
        let index = try OldFormatFixture.write(into: notes)
        let original = try FolderTree.snapshot(notes)

        let outcome = try Migration.run(folder: notes, now: today)

        guard case .migrated(let renamed, let backupName) = outcome else { return XCTFail("expected migrated, got \(outcome)") }
        XCTAssertEqual(renamed, 13, "every note except the one whose index entry has no title")
        // Notes: bytes unchanged, names are the titles.
        let after = try FolderTree.snapshot(notes)
        for item in OldFormatFixture.items {
            let name = try XCTUnwrap(expectedNames[item.slug])
            XCTAssertEqual(after[nfc(name)], original[item.slug + ".md"], "bytes of \(item.slug) are unchanged under \(name)")
            if name != item.slug + ".md", !expectedNames.values.contains(item.slug + ".md") { XCTAssertNil(after[item.slug + ".md"], "the old slug file is gone") }
        }
        // Pins and order carried over, by new filename.
        let orderData = try XCTUnwrap(after[OrderFile.filename])
        let order = try XCTUnwrap(OrderFile.decode(orderData))
        let wantOrder = index.notes.sorted { ($0.pinned ? 0 : 1, $0.order) < ($1.pinned ? 0 : 1, $1.order) }
            .map { nfc(expectedNames[String($0.filename.dropLast(3))]!) }
        XCTAssertEqual(order.order.map(nfc), wantOrder)
        XCTAssertEqual(Set(order.pinned.map(nfc)), [nfc("Meeting notes.md"), nfc("Time- 12-30.md")])
        // The old index is kept as a backup file, byte for byte; the marker records completion.
        XCTAssertEqual(after[Migration.retiredIndexName], original[".index.json"])
        XCTAssertNil(after[".index.json"])
        XCTAssertNotNil(after[Migration.markerName])
        XCTAssertNil(after[Migration.journalName], "the working journal is removed once complete")
        // The backup is a dated copy beside the folder, equal to the original.
        XCTAssertEqual(try backups(parent).map(\.lastPathComponent), [backupName])
        XCTAssertTrue(backupName.hasPrefix("Notes-backup-"))
        XCTAssertEqual(try FolderTree.snapshot(parent.appendingPathComponent(backupName)), original)
    }

    func testTheStoreRunsTheMigrationOnFirstReloadAndShowsTitlesPinsAndOrder() async throws {
        let (parent, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        let original = try FolderTree.snapshot(notes)

        let store = try NoteStore(folder: notes, startWatcherImmediately: false, trash: { try FileManager.default.removeItem(at: $0) },
                                  persistFolder: { _ in })
        await store.reload()

        XCTAssertEqual(store.notes.map(\.title).prefix(2), ["Meeting notes", "Time: 12:30".replacingOccurrences(of: ":", with: "-")],
                       "pinned first, in the old order")
        XCTAssertEqual(store.notes.count, OldFormatFixture.items.count)
        let pinnedNames: Set<String> = Set(store.notes.filter { $0.pinned }.map { nfc($0.filename) })
        XCTAssertEqual(pinnedNames, [nfc("Meeting notes.md"), nfc("Time- 12-30.md")])
        XCTAssertEqual(try backups(parent).count, 1)
        XCTAssertEqual(try FolderTree.snapshot(try XCTUnwrap(try backups(parent).first)), original, "backup equals the original")

        // A second store on the same folder (a restart) changes nothing.
        let settled = try FolderTree.snapshot(notes)
        let store2 = try NoteStore(folder: notes, startWatcherImmediately: false, trash: { try FileManager.default.removeItem(at: $0) },
                                   persistFolder: { _ in })
        await store2.reload()
        XCTAssertEqual(try FolderTree.snapshot(notes), settled)
        XCTAssertEqual(try backups(parent).count, 1, "no second backup")
        XCTAssertEqual(store2.notes.map(\.filename), store.notes.map(\.filename))
    }

    func testMigrationIsIdempotent() throws {
        let (parent, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        _ = try Migration.run(folder: notes, now: today)
        let settled = try FolderTree.snapshot(notes)
        let backupsAfterFirst = try FolderTree.snapshot(parent)

        let again = try Migration.run(folder: notes, now: today.addingTimeInterval(86_400 * 3))

        XCTAssertEqual(again, .alreadyDone)
        XCTAssertEqual(try FolderTree.snapshot(notes), settled)
        XCTAssertEqual(try FolderTree.snapshot(parent), backupsAfterFirst, "no new backup on a later day either")
    }

    func testANewFormatFolderIsLeftAlone() throws {
        let (parent, notes) = try makeParent()
        try Data("a\n".utf8).write(to: notes.appendingPathComponent("Alpha.md"))
        try JSONEncoder().encode(OrderFile(pinned: ["Alpha.md"], order: ["Alpha.md"])).write(to: notes.appendingPathComponent(OrderFile.filename))
        let before = try FolderTree.snapshot(parent)

        XCTAssertEqual(try Migration.run(folder: notes, now: today), .notNeeded)
        XCTAssertEqual(try FolderTree.snapshot(parent), before, "no backup, no marker, nothing")

        let empty = parent.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(try Migration.run(folder: empty, now: today), .notNeeded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
    }

    // MARK: crash safety

    func testACrashAtEveryStepFollowedByARerunReachesTheSameFinalState() throws {
        // The clean run: its final folder, its backup, and the list of steps.
        let (cleanParent, cleanNotes) = try makeParent()
        try OldFormatFixture.write(into: cleanNotes)
        let original = try FolderTree.snapshot(cleanNotes)
        var steps: [String] = []
        _ = try Migration.run(folder: cleanNotes, now: today) { steps.append($0) }
        let finalState = try FolderTree.snapshot(cleanNotes)
        XCTAssertGreaterThan(steps.count, 20, "a checkpoint around every atomic action: \(steps)")
        XCTAssertEqual(Set(steps).count, steps.count, "each checkpoint is named uniquely: \(steps)")
        for expected in ["start", "backup-copied", "backup-verified", "journal-written", "order-written", "index-retired", "marker-written"] {
            XCTAssertTrue(steps.contains(expected), "missing checkpoint \(expected) in \(steps)")
        }

        struct Crash: Error {}
        for (k, step) in steps.enumerated() {
            let (parent, notes) = try makeParent()
            try OldFormatFixture.write(into: notes)
            // The fixture's random ids differ per folder; compare against the folder's own bytes below.
            let before = try FolderTree.snapshot(notes)
            var seen = 0
            XCTAssertThrowsError(try Migration.run(folder: notes, now: today) { _ in
                if seen == k { throw Crash() }
                seen += 1
            }, "crash injected at \(step)")

            // Nothing a note says is ever lost, at any point of the crash.
            let mid = try FolderTree.snapshot(notes)
            func isNote(_ name: String) -> Bool { name.hasSuffix(".md") || name.hasPrefix(".sidekick-migrating-") }
            let noteBytes = Set(before.compactMap { isNote($0.key) ? $0.value : nil })
            let midBytes = Set(mid.compactMap { isNote($0.key) ? $0.value : nil })
            XCTAssertEqual(midBytes, noteBytes, "after a crash at \(step) every note's bytes are still there")

            let rerun = try Migration.run(folder: notes, now: today)
            XCTAssertNotEqual(rerun, .notNeeded, "after a crash at \(step) the rerun finishes the job")

            // Same final names and bytes as the uninterrupted run (the fixtures differ only in the random ids inside
            // the index files, so compare note files and the order file by name and bytes, and the index by presence).
            let after = try FolderTree.snapshot(notes)
            XCTAssertEqual(Set(after.keys), Set(finalState.keys), "same files after a crash at \(step)")
            for (name, bytes) in finalState where name.hasSuffix(".md") || name == OrderFile.filename {
                XCTAssertEqual(after[name], bytes, "\(name) after a crash at \(step)")
            }
            XCTAssertNotNil(after[Migration.markerName])
            XCTAssertNil(after[Migration.journalName])
            XCTAssertEqual(after[Migration.retiredIndexName], before[".index.json"], "the old index is kept intact after \(step)")
            let made = try backups(parent)
            XCTAssertEqual(made.count, 1, "exactly one backup after a crash at \(step)")
            XCTAssertEqual(try FolderTree.snapshot(try XCTUnwrap(made.first)), before, "the backup equals the original after a crash at \(step)")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasSuffix(".partial") })
            // And once more: a third run does nothing.
            XCTAssertEqual(try Migration.run(folder: notes, now: today), .alreadyDone)
        }
        _ = (cleanParent, original)
    }

    func testARerunOnALaterDayStillUsesTheOriginalBackup() throws {
        let (parent, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        let before = try FolderTree.snapshot(notes)
        struct Crash: Error {}
        var seen = 0
        XCTAssertThrowsError(try Migration.run(folder: notes, now: today) { step in
            if step.hasPrefix("rename-b-3") { throw Crash() }
            seen += 1
        })
        _ = try Migration.run(folder: notes, now: today.addingTimeInterval(86_400 * 5))
        let made = try backups(parent)
        XCTAssertEqual(made.count, 1, "the half-migrated folder is never backed up as if it were the original")
        XCTAssertEqual(try FolderTree.snapshot(try XCTUnwrap(made.first)), before)
    }

    /// Characters Obsidian rejects in a note name, one per title; two titles that map to the same name stay distinct.
    func testTitlesWithCharactersObsidianRejectsBecomeFilenamesWithoutThem() throws {
        let (_, notes) = try makeParent()
        let forbidden = Array("?*\"<>|\\/:")
        var items = forbidden.enumerated().map { i, c in
            OldFormatFixture.Item(slug: "s\(i)", title: "T\(c)x", body: "body \(i)\n", pinned: false, order: i)
        }
        items.append(.init(slug: "tw1", title: "same?name", body: "one\n", pinned: false, order: 20))
        items.append(.init(slug: "tw2", title: "same*name", body: "two\n", pinned: false, order: 21))
        try OldFormatFixture.write(into: notes, items: items)
        _ = try Migration.run(folder: notes, now: today)
        let mds = try FileManager.default.contentsOfDirectory(atPath: notes.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(mds.count, items.count)
        for name in mds { XCTAssertNil(name.dropLast(3).firstIndex(where: { forbidden.contains($0) }), "\(name) holds a forbidden character") }
        XCTAssertEqual(Set(mds.map { $0.lowercased() }).count, items.count, "colliding names stay distinct")
        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent("same-name.md")), Data("one\n".utf8))
        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent("same-name 2.md")), Data("two\n".utf8))
    }

    func testAFileThatAppearsAtATargetNameDuringTheMigrationIsNeverOverwritten() throws {
        let (_, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        struct Crash: Error {}
        // Crash after every renamed file has moved to its temporary name but before any reaches its final name.
        XCTAssertThrowsError(try Migration.run(folder: notes, now: today) { step in
            if step == "renames-staged" { throw Crash() }
        })
        // Another tool now creates a file where the first note is about to go.
        try Data("not mine\n".utf8).write(to: notes.appendingPathComponent("Meeting notes.md"))
        _ = try Migration.run(folder: notes, now: today)
        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent("Meeting notes.md")), Data("not mine\n".utf8))
        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent("Meeting notes 2.md")), Data("# Meeting\nagenda\n".utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: notes.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files.count, OldFormatFixture.items.count + 1)
    }

    // MARK: damaged old data

    func testACorruptOrUnreadableIndexIsAFailureNotAMigration() throws {
        let variants: [(String, Data)] = [
            ("garbage", Data("{ not json".utf8)),
            ("truncated", Data("{\"version\":1,\"notes\":[{\"id\":\"".utf8)),
            ("wrong types", Data("{\"version\":\"one\",\"notes\":{\"a\":1}}".utf8)),
            ("empty file", Data()),
            ("binary", Data([0xFF, 0xFE, 0x00, 0x80])),
        ]
        for (label, index) in variants {
            let (parent, notes) = try makeParent()
            try Data("a\n".utf8).write(to: notes.appendingPathComponent("some-slug.md"))
            try index.write(to: notes.appendingPathComponent(".index.json"))
            let before = try FolderTree.snapshot(parent)

            XCTAssertThrowsError(try Migration.run(folder: notes, now: today), label) { error in
                XCTAssertTrue(error is MigrationFailure, "\(label): \(error)")
            }
            XCTAssertEqual(try FolderTree.snapshot(parent), before,
                           "\(label): nothing changed: index kept, no marker, no order file, no backup, no renames")
            // Still pending: a repaired index migrates on the next run.
            XCTAssertThrowsError(try Migration.run(folder: notes, now: today), "\(label): retried")
        }
    }

    func testALaterMigrationMergesTheOldPinsIntoAnOrderFileMadeMeanwhile() async throws {
        let (_, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        let indexURL = notes.appendingPathComponent(".index.json")
        let goodIndex = try Data(contentsOf: indexURL)
        try Data("{ not json".utf8).write(to: indexURL)           // the migration fails

        let store = try NoteStore(folder: notes, startWatcherImmediately: false, trash: { try FileManager.default.removeItem(at: $0) },
                                  persistFolder: { _ in })
        await store.reload()
        XCTAssertNotNil(store.migrationError)
        // Normal use meanwhile: a pin on a slug-named note, and a reorder. This writes an order file.
        let same = try XCTUnwrap(store.notes.first { $0.filename == "same.md" })
        let cafe = try XCTUnwrap(store.notes.first { $0.filename == "cafe.md" })
        try await store.setPinned(same.id, true)
        try await store.reorder([cafe.id, same.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent(OrderFile.filename).path))

        try goodIndex.write(to: indexURL)                         // the index is repaired; next launch
        let store2 = try NoteStore(folder: notes, startWatcherImmediately: false, trash: { try FileManager.default.removeItem(at: $0) },
                                   persistFolder: { _ in })
        await store2.reload()

        XCTAssertNil(store2.migrationError)
        let pinned = Set(store2.notes.filter { $0.pinned }.map { nfc($0.filename) })
        XCTAssertEqual(pinned, [nfc("Meeting notes.md"), nfc("Time- 12-30.md"), nfc("Same.md")],
                       "every old pin and the pin made meanwhile")
        let names = store2.notes.map { nfc($0.filename) }
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: nfc("Caf\u{E9}.md"))), try XCTUnwrap(names.firstIndex(of: nfc("Same 2.md"))),
                          "the order made meanwhile keeps its place (the first note of it comes first among the unpinned)")
        XCTAssertEqual(Set(names).count, OldFormatFixture.items.count)
    }

    func testAPreExistingPartialNamedDirectoryIsNeverTouched() throws {
        let (parent, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let theirs = parent.appendingPathComponent("Notes-backup-\(formatter.string(from: today)).partial")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("not yours\n".utf8).write(to: theirs.appendingPathComponent("keep.txt"))
        let before = try FolderTree.snapshot(theirs)

        let outcome = try Migration.run(folder: notes, now: today)

        guard case .migrated = outcome else { return XCTFail("expected migrated, got \(outcome)") }
        XCTAssertEqual(try FolderTree.snapshot(theirs), before, "a directory this run did not create survives byte-identical")
        XCTAssertEqual(try backups(parent).count, 1)
    }

    private func failure(at checkpoint: String) throws -> MigrationFailure {
        let (_, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        struct Boom: Error {}
        do { _ = try Migration.run(folder: notes, now: today) { if $0 == checkpoint { throw Boom() } } }
        catch let f as MigrationFailure { return f }
        XCTFail("expected a failure at \(checkpoint)")
        throw Boom()
    }

    func testTheNoticeSaysNothingWasRenamedWhenNoRenameHappened() throws {
        for point in ["start", "backup-copied", "backup-verified", "journal-written"] {
            let text = try failure(at: point).noticeText
            XCTAssertTrue(text.contains("Nothing was changed"), "\(point): \(text)")
            XCTAssertFalse(text.contains("renamed"), "\(point): \(text)")
            XCTAssertFalse(text.contains("missing"), "\(point): \(text)")
        }
    }

    func testTheNoticeSaysNotesAreTemporarilyMissingWhileFilesSitUnderTemporaryNames() throws {
        for point in ["rename-a-2", "renames-staged", "rename-b-3"] {
            let text = try failure(at: point).noticeText
            XCTAssertTrue(text.contains("temporarily missing from the list"), "\(point): \(text)")
            XCTAssertTrue(text.contains("reappear when Sidekick finishes the conversion on next launch"), "\(point): \(text)")
            XCTAssertTrue(text.contains("No note text was changed"), "\(point): \(text)")
        }
    }

    func testTheNoticeSaysFilesWereRenamedButNothingIsMissingOnceAllAreInPlace() throws {
        let text = try failure(at: "rename-b-12").noticeText      // the last of the 13 final moves
        XCTAssertTrue(text.contains("already renamed"), text)
        XCTAssertFalse(text.contains("missing"), text)
    }

    func testAFailedMigrationShowsANoticeAndChangesNothing() async throws {
        let (parent, notes) = try makeParent()
        try Data("a\n".utf8).write(to: notes.appendingPathComponent("some-slug.md"))
        try Data("{ not json".utf8).write(to: notes.appendingPathComponent(".index.json"))
        let before = try FolderTree.snapshot(parent)
        let store = try NoteStore(folder: notes, startWatcherImmediately: false, trash: { try FileManager.default.removeItem(at: $0) },
                                  persistFolder: { _ in })
        XCTAssertNil(store.migrationNotice)

        await store.reload()

        XCTAssertNotNil(store.migrationError)
        let notice = try XCTUnwrap(store.migrationNotice)
        XCTAssertTrue(notice.contains("could not be converted"), notice)
        XCTAssertTrue(notice.contains("Nothing was changed"), notice)
        XCTAssertEqual(store.notes.map(\.title), ["some-slug"], "the notes are still shown under their slug names")
        XCTAssertEqual(try FolderTree.snapshot(parent), before)
    }

    func testTheNoticeNamesTheBackupWhenOneExists() {
        let text = MigrationFailure(reason: "disk full", backup: "Notes-backup-2026-11-16").noticeText
        XCTAssertTrue(text.contains("Notes-backup-2026-11-16"), text)
        XCTAssertTrue(text.contains("could not be converted"), text)
    }

    func testAFailureBeforeTheRenamesRemovesTheHalfCopyItMade() throws {
        let (parent, notes) = try makeParent()
        try OldFormatFixture.write(into: notes)
        let before = try FolderTree.snapshot(notes)
        struct Boom: Error {}
        XCTAssertThrowsError(try Migration.run(folder: notes, now: today) { if $0 == "backup-copied" { throw Boom() } })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasSuffix(".partial") },
                       "no half copy is left in the parent")
        XCTAssertEqual(try FolderTree.snapshot(notes), before)
    }

    func testASymlinkedNotesFolderIsBackedUpAsTheRealFolder() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationTests-\(UUID().uuidString)")
        let real = parent.appendingPathComponent("elsewhere/Notes")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try OldFormatFixture.write(into: real)
        let original = try FolderTree.snapshot(real)
        let link = parent.appendingPathComponent("Notes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let outcome = try Migration.run(folder: link, now: today)

        guard case .migrated(_, let backupName) = outcome else { return XCTFail("expected migrated, got \(outcome)") }
        let realParent = real.deletingLastPathComponent().resolvingSymlinksInPath()
        let backup = realParent.appendingPathComponent(backupName)
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeDirectory, "the backup is a real directory, not a link")
        XCTAssertEqual(try FolderTree.snapshot(backup), original, "with the original bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(backupName).path), "not beside the link")
        XCTAssertTrue(try FolderTree.snapshot(real).keys.contains(nfc("Meeting notes.md")), "the real folder was migrated")
    }

    func testIndexEntriesForMissingFilesAreSkippedAndExtraFilesKeepTheirNames() throws {
        let (_, notes) = try makeParent()
        let items = [OldFormatFixture.Item(slug: "present", title: "Present", body: "p\n", pinned: true, order: 0)]
        try OldFormatFixture.write(into: notes, items: items)
        // The index also names a file that is gone; the folder also holds a file the index never knew.
        var index = try JSONDecoder().decode(LegacyIndex.self, from: Data(contentsOf: notes.appendingPathComponent(".index.json")))
        index.notes.append(LegacyEntry(id: UUID(), filename: "ghost.md", title: "Ghost", pinned: true, order: 1))
        try JSONEncoder().encode(index).write(to: notes.appendingPathComponent(".index.json"))
        try Data("x\n".utf8).write(to: notes.appendingPathComponent("Stray.md"))

        _ = try Migration.run(folder: notes, now: today)

        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent("Present.md")), Data("p\n".utf8))
        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent("Stray.md")), Data("x\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent("Ghost.md").path))
        let order = try XCTUnwrap(OrderFile.decode(Data(contentsOf: notes.appendingPathComponent(OrderFile.filename))))
        XCTAssertEqual(order.pinned, ["Present.md"])
        XCTAssertEqual(order.order, ["Present.md"])
    }
}
