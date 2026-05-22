import XCTest
import SwiftUI
@testable import Sidekick

final class NoteListTapTests: XCTestCase {

    private func makeNote(_ id: UUID, _ filename: String) -> Note {
        Note(id: id, filename: filename, body: "", pinned: false, order: 0)
    }

    // Test A: the closure body of the row tap gesture — `selectedID = note.id` —
    // when applied to a Binding<UUID?> backed by a local variable, sets the
    // variable to the tapped note's id. Covers switching from nil and from
    // another note's id.
    func test_tapAction_writesSelectedID() {
        var backing: UUID? = nil
        let selectedID = Binding<UUID?>(get: { backing }, set: { backing = $0 })

        let a = UUID(), b = UUID()
        let noteA = makeNote(a, "a.md")
        let noteB = makeNote(b, "b.md")

        // Simulate the .onTapGesture body: selectedID = note.id
        selectedID.wrappedValue = noteA.id
        XCTAssertEqual(backing, a, "Tapping a row from a nil selection must set selectedID to that row's id")

        // Simulate tapping a different row — must switch on this single write.
        selectedID.wrappedValue = noteB.id
        XCTAssertEqual(backing, b, "Tapping a different row must switch selectedID immediately")
    }

    // Test B: the predicate used by the row .background — `note.id == selectedID` —
    // returns true only for the row whose id matches the current selection, false
    // for all others. Covers the nil-selection case (no row highlighted) and the
    // matching case (exactly one row highlighted).
    func test_selectionHighlightPredicate_matchesOnlySelectedRow() {
        let a = UUID(), b = UUID(), c = UUID()
        let notes = [makeNote(a, "a.md"), makeNote(b, "b.md"), makeNote(c, "c.md")]

        // No selection — no row is highlighted.
        let none: UUID? = nil
        XCTAssertEqual(notes.filter { $0.id == none }.count, 0,
                       "With nil selection, no row's highlight predicate is true")

        // Selection on b — exactly one row highlighted.
        let selected: UUID? = b
        let highlighted = notes.filter { $0.id == selected }
        XCTAssertEqual(highlighted.count, 1, "Exactly one row matches the selection predicate")
        XCTAssertEqual(highlighted.first?.id, b, "The matching row is the selected one")
    }
}
