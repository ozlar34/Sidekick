import XCTest
import AppKit
@testable import Sidekick

/// Layer-4 example tests. Each test drives keystrokes through a hosted
/// editor (real NSWindow + first responder + layout) and asserts the
/// resulting attributed-string snapshot matches the committed baseline
/// under `Tests/SidekickTests/__Snapshots__/HostedEditorSnapshotTests/`.
///
/// Failure mode: snapshot diff fires when ANY of the styling surface
/// changes — marker glyph chosen, hidden-marker attribute, font traits,
/// link color, paragraph alignment / line height. This catches the bugs
/// the keystroke-transcript fuzzer misses because it tests the model
/// alone.
///
/// To re-record after an intentional change:
///   SIDEKICK_RECORD_SNAPSHOTS=1 swift test --filter HostedEditorSnapshotTests
@MainActor
final class HostedEditorSnapshotTests: XCTestCase {

    /// Empty body baseline — paragraph-style + default font attributes for
    /// an empty document. Acts as the canary snapshot: if this drifts,
    /// every other Layer-4 baseline likely needs a refresh too (system
    /// font name change, paragraph-style default tweak, etc.).
    func test_emptyBody_snapshot() {
        let runner = HostedEditorRunner()
        let snap = AttributeSnapshot.serialize(runner.attributedString)
        assertAttributeSnapshot(snap, named: "empty", testCase: self)
    }

    /// Checklist marker substitution — typing `- [ ] foo` produces the
    /// glyph-substituted ◯ marker rendered onto the leading `-` plus
    /// `sidekickChecklistMarker=false` on the marker range and
    /// `sidekickHiddenMarker=true` on the surrounding syntax chars.
    func test_uncheckedTaskItem_snapshot() {
        let runner = HostedEditorRunner()
        runner.type("- [ ] write tests")
        let snap = AttributeSnapshot.serialize(runner.attributedString)
        assertAttributeSnapshot(snap, named: "after-type", testCase: self)
    }

    /// Heading line — typing `# Hello` produces heading-sized font on the
    /// content + `sidekickHiddenMarker=true` on `# `. Snapshot pins both
    /// the chosen heading font (size + weight) and the hidden-marker
    /// boundary so regressions in either layer fire here.
    func test_heading1_snapshot() {
        let runner = HostedEditorRunner()
        runner.type("# Hello")
        let snap = AttributeSnapshot.serialize(runner.attributedString)
        assertAttributeSnapshot(snap, named: "after-type", testCase: self)
    }
}
