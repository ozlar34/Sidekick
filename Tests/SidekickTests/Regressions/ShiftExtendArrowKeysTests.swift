import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// Prefactor for the "HR-adjacent caret/selection movement" effort: this test
// is not a regression for a bug, it's the smoke test proving the new
// `KeystrokeRunner.Key` shift-extend cases (`.shiftLeft/.shiftRight/.shiftUp/
// .shiftDown`) dispatch through the real coordinator `doCommandBy` →
// `textView.doCommand(by:)` path with the standard AppKit
// `move…AndModifySelection(_:)` selectors, exactly like the existing plain
// arrow cases. Later tickets in the same effort add marker/divider-adjacency
// coverage for these selectors — this file only proves the dispatch plumbing
// on plain, marker-free text.
@MainActor
final class ShiftExtendArrowKeysTests: XCTestCase {

    // "before after" — caret starts between "before " and "after".
    private let body = "before after"

    func test_shiftRightExtendsThenShiftLeftShrinksBack() {
        let runner = HostedEditorRunner(
            initialBody: body,
            initialSelection: NSRange(location: 7, length: 0)
        )
        runner.key(.shiftRight)
        runner.assertSelection(NSRange(location: 7, length: 1))

        runner.key(.shiftLeft)
        runner.assertSelection(NSRange(location: 7, length: 0))
    }
}
