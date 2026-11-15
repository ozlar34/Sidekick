import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// Follow-up to the right-arrow chain (A1–A5), reported live in a real note
// `*New Functionality*\n---\n*Bug Fixes*`: Right from the end of line 1
// crossed the divider to the raw start of `*Bug Fixes*` (before the hidden
// `*`), then needed a second press with no visible move to get past the `*`.
// The divider rescue landed on the line start and nothing skipped a hidden
// opening marker there; AppKit's own Right across a plain line break does.
//
// Fix: `hiddenPrefixEnd(ifLineStartAt:)`, applied by `moveRight` to a rescued
// landing and by `moveOffHRRun` to a forward exit.
//
// Layer 4 (HostedEditorRunner): needs real layout and real arrow keys.
@MainActor
final class HiddenPrefixAfterDividerTests: XCTestCase {

    /// Right from above the divider lands after the hidden opener in one press.
    func test_right_acrossDivider_skipsHiddenLinePrefix() {
        for (body, start, expected) in [
            ("*New*\n---\n*Bug*", 5, 11),      // italic line above (Oguz's note shape)
            ("New\n---\n*Bug*", 3, 9),         // italic
            ("New\n---\n**Bug**", 3, 10),      // bold
            ("New\n---\n# Bug", 3, 10),        // heading prefix
        ] {
            let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
            runner.key(.right)
            runner.assertSelection(NSRange(location: expected, length: 0))
        }
    }

    /// Typing at that stop lands inside the styling, not before the marker.
    func test_right_acrossDivider_thenType_landsInsideItalic() {
        let runner = HostedEditorRunner(initialBody: "New\n---\n*Bug*", initialSelection: NSRange(location: 3, length: 0))
        runner.key(.right)
        runner.type("X")
        runner.assertBody("New\n---\n*XBug*")
    }

    /// Guards: a plain line keeps its line-start stop; Left mirrors Right.
    func test_guards_plainLineAndLeftMirror() {
        let plain = HostedEditorRunner(initialBody: "New\n---\nBug", initialSelection: NSRange(location: 3, length: 0))
        plain.key(.right)
        plain.assertSelection(NSRange(location: 8, length: 0))

        let mirror = HostedEditorRunner(initialBody: "New\n---\n*Bug*", initialSelection: NSRange(location: 9, length: 0))
        mirror.key(.left)
        mirror.assertSelection(NSRange(location: 3, length: 0))
    }
}
