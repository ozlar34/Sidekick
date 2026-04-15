import XCTest
@testable import Sidekick

/// Verifies that the setDocumentEdited closure is called with `true` immediately
/// on scheduling and `false` after the debounce fires — backing EDIT-05.
final class UnsavedIndicatorTests: XCTestCase {

    func testSetDocumentEdited_trueOnSchedule_falseAfterFire() async throws {
        let debouncer = Debouncer(interval: 0.05)
        var calls: [Bool] = []
        let setDocumentEdited: (Bool) -> Void = { calls.append($0) }

        // Simulate what EditorPaneView.scheduleAutoSave does:
        // 1. Call setDocumentEdited(true) immediately (EDIT-05 unsaved signal)
        setDocumentEdited(true)
        // 2. Schedule debounced work that calls setDocumentEdited(false) on completion
        let editedSetter = setDocumentEdited
        await debouncer.schedule {
            await MainActor.run { editedSetter(false) }
        }
        // Wait for debounce to fire
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(calls, [true, false], "setDocumentEdited should be called true then false")
    }

    func testSetDocumentEdited_cancelAndReschedule_onlyOneFalse() async throws {
        let debouncer = Debouncer(interval: 0.05)
        var calls: [Bool] = []
        let setDocumentEdited: (Bool) -> Void = { calls.append($0) }

        // First keystroke
        setDocumentEdited(true)
        let editedSetter = setDocumentEdited
        await debouncer.schedule {
            await MainActor.run { editedSetter(false) }
        }
        // Second keystroke before debounce fires
        try await Task.sleep(nanoseconds: 10_000_000)
        setDocumentEdited(true)
        await debouncer.schedule {
            await MainActor.run { editedSetter(false) }
        }
        // Wait for second debounce to fire
        try await Task.sleep(nanoseconds: 200_000_000)

        // Expect: true (1st keystroke), true (2nd keystroke), false (2nd debounce only)
        XCTAssertEqual(calls, [true, true, false], "First debounced save should be cancelled; only second fires false")
    }
}
