import XCTest
@testable import Sidekick

final class ReconcileTests: XCTestCase {

    func testMissingIndexRebuild() {
        let snapshot = DiskSnapshotFixture.make([
            (filename: "a.md", mtimeSecondsAgo: 200),
            (filename: "b.md", mtimeSecondsAgo: 100)
        ])
        let (index, changed) = reconcile(snapshot: snapshot, index: nil)
        XCTAssertEqual(index.version, 1)
        XCTAssertEqual(index.notes.count, 2)
        XCTAssertTrue(changed)
        // All entries are unpinned
        XCTAssertTrue(index.notes.allSatisfy { !$0.pinned })
        // Order is a dense permutation 0..<2
        let orders = Set(index.notes.map(\.order))
        XCTAssertEqual(orders, [0, 1])
    }

    func testOrphanFilesAppended() {
        // Index has one entry for a.md; disk also has b.md (fresher mtime).
        let existingEntry = IndexEntry(id: UUID(), filename: "a.md", pinned: false, order: 0)
        let existingIndex = NoteIndex(version: 1, notes: [existingEntry])
        let snapshot = DiskSnapshotFixture.make([
            (filename: "a.md", mtimeSecondsAgo: 200),
            (filename: "b.md", mtimeSecondsAgo: 50)   // fresher
        ])
        let (index, _) = reconcile(snapshot: snapshot, index: existingIndex)
        XCTAssertEqual(index.notes.count, 2)
        // a.md retains its original order (0), b.md appended at order 1
        let aEntry = index.notes.first { $0.filename == "a.md" }
        let bEntry = index.notes.first { $0.filename == "b.md" }
        XCTAssertNotNil(aEntry)
        XCTAssertNotNil(bEntry)
        XCTAssertEqual(aEntry?.order, 0)
        XCTAssertEqual(bEntry?.order, 1)
        // a.md retains its original UUID
        XCTAssertEqual(aEntry?.id, existingEntry.id)
    }

    func testMissingFileDropped() {
        let idA = UUID()
        let idB = UUID()
        let existingIndex = NoteIndex(version: 1, notes: [
            IndexEntry(id: idA, filename: "a.md", pinned: false, order: 0),
            IndexEntry(id: idB, filename: "b.md", pinned: false, order: 1)
        ])
        // Snapshot only has a.md — b.md is missing
        let snapshot = DiskSnapshotFixture.make([
            (filename: "a.md", mtimeSecondsAgo: 100)
        ])
        let (index, changed) = reconcile(snapshot: snapshot, index: existingIndex)
        XCTAssertEqual(index.notes.count, 1)
        XCTAssertEqual(index.notes[0].filename, "a.md")
        XCTAssertEqual(index.notes[0].order, 0)  // dense order reassigned
        XCTAssertTrue(changed)
    }
}
