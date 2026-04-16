import XCTest
@testable import Sidekick

final class SidebarSelectionTests: XCTestCase {

    // MARK: - successorID(afterDeleting:in:) pure function

    private func makeNote(_ id: UUID, _ filename: String) -> Note {
        Note(id: id, filename: filename, body: "", pinned: false, order: 0)
    }

    func test_successorID_middleIndex_returnsNext() {
        let a = UUID(), b = UUID(), c = UUID()
        let notes = [makeNote(a, "a.md"), makeNote(b, "b.md"), makeNote(c, "c.md")]
        XCTAssertEqual(NoteRowFormatting.successorID(afterDeleting: b, in: notes), c)
    }

    func test_successorID_lastIndex_returnsPrevious() {
        let a = UUID(), b = UUID(), c = UUID()
        let notes = [makeNote(a, "a.md"), makeNote(b, "b.md"), makeNote(c, "c.md")]
        XCTAssertEqual(NoteRowFormatting.successorID(afterDeleting: c, in: notes), b)
    }

    func test_successorID_firstIndex_returnsNext() {
        let a = UUID(), b = UUID(), c = UUID()
        let notes = [makeNote(a, "a.md"), makeNote(b, "b.md"), makeNote(c, "c.md")]
        XCTAssertEqual(NoteRowFormatting.successorID(afterDeleting: a, in: notes), b)
    }

    func test_successorID_onlyNote_returnsNil() {
        let a = UUID()
        let notes = [makeNote(a, "a.md")]
        XCTAssertNil(NoteRowFormatting.successorID(afterDeleting: a, in: notes))
    }

    func test_successorID_idNotInList_returnsNil() {
        let a = UUID(), b = UUID()
        let notes = [makeNote(a, "a.md"), makeNote(b, "b.md")]
        XCTAssertNil(NoteRowFormatting.successorID(afterDeleting: UUID(), in: notes))
    }

    // MARK: - Relaxed guard behavior (integration via NoteStore)

    @MainActor
    func test_relaxedGuard_reassignsOnStaleUUID() async throws {
        // Setup: two notes in a temp folder
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-\(UUID())")
        let store = try NoteStore(folder: tmp)
        let n1 = try await store.create()
        let n2 = try await store.create()
        var selectedID: UUID? = n1.id

        // Simulate deletion of n1 (which also fires the onChange with newNotes = [n2])
        try await store.delete(n1.id)
        let newNotes = store.notes   // after delete, should be [n2]

        // Apply the RELAXED guard body manually:
        // (original: guard selectedID == nil, !newNotes.isEmpty else { return })
        // (relaxed: reassign if selectedID is nil OR selectedID points to a UUID not in newNotes)
        let shouldReassign = selectedID == nil
            || (selectedID != nil && !newNotes.contains(where: { $0.id == selectedID! }))
        XCTAssertTrue(shouldReassign, "relaxed guard must trigger reassignment when selectedID is stale")

        if shouldReassign, !newNotes.isEmpty {
            selectedID = newNotes.first?.id
        }
        XCTAssertEqual(selectedID, n2.id, "selectedID must transfer to remaining note")

        try? FileManager.default.removeItem(at: tmp)
    }
}
