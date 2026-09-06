import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// Empirically confirmed via a throwaway HostedEditorRunner probe (part of the
// "HR-adjacent caret/selection movement" effort, ticket 03) BEFORE this fix:
// with the caret resting exactly at the start of a line immediately below a
// divider — the boundary position immediately before a hidden inline-style
// opening marker (`**`, `*`, `<u>`, `~~`) — pressing Left did NOT move the
// caret backward across the divider. AppKit's own `moveLeft:` glyph-based
// backward search from that boundary instead jumped FORWARD, landing at the
// FAR edge of the hidden marker run (e.g. for body "before\n---\n**Bold
// below**" with the caret at 11 — right before the hidden "**" — pressing
// Left landed at 13, the far edge of the "**", instead of 6, the end of
// "before"). That is a direct violation of "a single Left press never
// increases the caret location", and it skipped the divider crossing
// entirely. (The mirrored Right direction — end of a plain line above a
// divider into a styled line below — turned out to already compute the
// correct boundary via AppKit's own stepping in the probed configuration,
// but is still covered below since nothing guarantees that's true in
// general; the new `moveRight`/`moveLeft` overrides make both directions
// authoritative rather than incidental.)
//
// Fix: `HybridTextView.moveLeft(_:)` / `moveRight(_:)` now compute their own
// naive one-character step from the current selection and run it through the
// same five-helper snap-rescue chain `setSelectedRanges` already uses
// (factored into `correctedCaretTarget(fromNaive:previous:direction:)`),
// rather than trusting AppKit's own layout-based stepping near a managed
// region. Far from any managed region, both overrides defer straight to
// `super` so ordinary movement is unaffected.
//
// Tests use HostedEditorRunner (real windowed layout) dispatching real
// `.right`/`.left` keys and assert on the real post-dispatch selection —
// never on the snap helpers directly.
//
// Ticket 04 extends this file with `moveUp`/`moveDown`. Confirmed repro (from
// `.scratch/hr-adjacent-caret-movement/PLAN.md`, "Confirmed Bug A"): body
// "Test1\n---\nTest2\n---\n*Test3*\n---\n*Test4*" with the caret at 35 (mid
// "*Test4*"), pressing Up silently failed to move — it reset the caret to 32,
// the START of the current line, instead of moving up into "*Test3*"'s line.
// Fix: `HybridTextView.moveUp(_:)` / `moveDown(_:)` compute a naive
// same-column step into the adjacent line via `NSString.getLineStart(_:end:
// contentsEnd:for:)` — precise enough only to land inside the correct
// adjacent line's span — and run it through the same
// `correctedCaretTarget(fromNaive:previous:direction:)` chain `moveLeft`/
// `moveRight` already use. Far from a managed region, both defer straight to
// `super` so real AppKit vertical stepping (x-position-preserving glyph
// search) is unaffected.
@MainActor
final class PlainArrowMoveAcrossDividerTests: XCTestCase {

    // MARK: - Helpers (index arithmetic via substring search, not hand-counted)

    private func offset(after marker: String, in body: String) -> Int {
        let r = (body as NSString).range(of: marker)
        precondition(r.location != NSNotFound, "marker not found: \(marker)")
        return r.location + r.length
    }

    private func offset(of marker: String, in body: String) -> Int {
        let r = (body as NSString).range(of: marker)
        precondition(r.location != NSNotFound, "marker not found: \(marker)")
        return r.location
    }

    // MARK: - Right: end of line above divider -> start of line below

    func test_right_plainAbove_plainBelow() {
        let body = "before\n---\nafter"
        let start = offset(after: "before", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start, "A single Right press must never decrease the caret location")
    }

    /// The broken case: a hidden bold-opening marker immediately after the
    /// divider's line break.
    func test_right_plainAbove_boldBelow() {
        let body = "before\n---\n**Bold below**"
        let start = offset(after: "before", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "**Bold", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    func test_right_plainAbove_italicBelow() {
        let body = "before\n---\n*Italic below*"
        let start = offset(after: "before", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "*Italic", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    func test_right_plainAbove_underlineBelow() {
        let body = "before\n---\n<u>Underline below</u>"
        let start = offset(after: "before", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "<u>Underline", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    func test_right_plainAbove_strikethroughBelow() {
        let body = "before\n---\n~~Strike below~~"
        let start = offset(after: "before", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "~~Strike", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    /// Symmetric direction: styled line above, plain line below.
    func test_right_boldAbove_plainBelow() {
        let body = "**Bold above**\n---\nafter"
        let start = offset(of: "\n---", in: body)   // end of "**Bold above**", before its own \n
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    func test_right_italicAbove_plainBelow() {
        let body = "*Italic above*\n---\nafter"
        let start = offset(of: "\n---", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    func test_right_underlineAbove_plainBelow() {
        let body = "<u>Underline above</u>\n---\nafter"
        let start = offset(of: "\n---", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    func test_right_strikethroughAbove_plainBelow() {
        let body = "~~Strike above~~\n---\nafter"
        let start = offset(of: "\n---", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, start)
    }

    // MARK: - Left: start of line below divider -> end of line above (mirrored)

    func test_left_plainAbove_plainBelow() {
        let body = "before\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start, "A single Left press must never increase the caret location")
    }

    /// The confirmed broken case: caret resting at the start of the hidden
    /// bold-opening marker run immediately below the divider.
    func test_left_plainAbove_boldBelow() {
        let body = "before\n---\n**Bold below**"
        let start = offset(of: "**Bold", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_left_plainAbove_italicBelow() {
        let body = "before\n---\n*Italic below*"
        let start = offset(of: "*Italic", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_left_plainAbove_underlineBelow() {
        let body = "before\n---\n<u>Underline below</u>"
        let start = offset(of: "<u>Underline", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_left_plainAbove_strikethroughBelow() {
        let body = "before\n---\n~~Strike below~~"
        let start = offset(of: "~~Strike", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    /// Symmetric direction: styled line above, plain line below.
    func test_left_boldAbove_plainBelow() {
        let body = "**Bold above**\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_left_italicAbove_plainBelow() {
        let body = "*Italic above*\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_left_underlineAbove_plainBelow() {
        let body = "<u>Underline above</u>\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_left_strikethroughAbove_plainBelow() {
        let body = "~~Strike above~~\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    // MARK: - Runs of consecutive dividers still skip as one block

    func test_consecutiveDividers_skipAsOneBlock_viaHostedRunner() {
        // Same body shape as ConsecutiveHRCaretTests, driven through
        // HostedEditorRunner (real windowed layout) instead of the bare
        // KeystrokeRunner, since this file's whole point is exercising the
        // new moveLeft/moveRight overrides under real layout.
        let body = "a\n---\n---\nb"   // a=0 \n=1 ---=2..4 \n=5 ---=6..8 \n=9 b=10
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 1, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: 10, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: 11, length: 0))

        let runnerBack = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 10, length: 0))
        runnerBack.key(.left)
        runnerBack.assertSelection(NSRange(location: 1, length: 0))
    }

    // MARK: - Far from any managed region defers to super, unaffected

    func test_plainText_farFromManagedRegion_movesOneCharacterAtATime() {
        let runner = HostedEditorRunner(initialBody: "hello world", initialSelection: NSRange(location: 5, length: 0))
        runner.key(.right)
        runner.assertSelection(NSRange(location: 6, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: 5, length: 0))
        runner.key(.left)
        runner.assertSelection(NSRange(location: 4, length: 0))
    }

    // MARK: - Down: a line above a divider -> the line below (ticket 04)

    func test_down_plainAbove_plainBelow() {
        let body = "before\n---\nafter"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0, "A single Down press must never decrease the caret location")
    }

    /// The broken case: a hidden bold-opening marker immediately after the
    /// divider's line break.
    func test_down_plainAbove_boldBelow() {
        let body = "before\n---\n**Bold below**"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "**Bold below**", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    func test_down_plainAbove_italicBelow() {
        let body = "before\n---\n*Italic below*"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "*Italic below*", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    func test_down_plainAbove_underlineBelow() {
        let body = "before\n---\n<u>Underline below</u>"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "<u>Underline below</u>", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    func test_down_plainAbove_strikethroughBelow() {
        let body = "before\n---\n~~Strike below~~"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "~~Strike below~~", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    /// Symmetric direction: styled line above, plain line below.
    func test_down_boldAbove_plainBelow() {
        let body = "**Bold above**\n---\nafter"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    func test_down_italicAbove_plainBelow() {
        let body = "*Italic above*\n---\nafter"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    func test_down_underlineAbove_plainBelow() {
        let body = "<u>Underline above</u>\n---\nafter"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    func test_down_strikethroughAbove_plainBelow() {
        let body = "~~Strike above~~\n---\nafter"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: offset(of: "after", in: body), length: 0))
        XCTAssertGreaterThanOrEqual(runner.selection.location, 0)
    }

    // MARK: - Up: a line below a divider -> the line above (mirrored, ticket 04)

    func test_up_plainAbove_plainBelow() {
        let body = "before\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start, "A single Up press must never increase the caret location")
    }

    /// The confirmed broken case: caret resting at the start of the hidden
    /// bold-opening marker run immediately below the divider.
    func test_up_plainAbove_boldBelow() {
        let body = "before\n---\n**Bold below**"
        let start = offset(of: "**Bold below**", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_up_plainAbove_italicBelow() {
        let body = "before\n---\n*Italic below*"
        let start = offset(of: "*Italic below*", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_up_plainAbove_underlineBelow() {
        let body = "before\n---\n<u>Underline below</u>"
        let start = offset(of: "<u>Underline below</u>", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_up_plainAbove_strikethroughBelow() {
        let body = "before\n---\n~~Strike below~~"
        let start = offset(of: "~~Strike below~~", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(after: "before", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    /// Symmetric direction: styled line above, plain line below.
    func test_up_boldAbove_plainBelow() {
        let body = "**Bold above**\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_up_italicAbove_plainBelow() {
        let body = "*Italic above*\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_up_underlineAbove_plainBelow() {
        let body = "<u>Underline above</u>\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    func test_up_strikethroughAbove_plainBelow() {
        let body = "~~Strike above~~\n---\nafter"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(of: "\n---", in: body), length: 0))
        XCTAssertLessThanOrEqual(runner.selection.location, start)
    }

    /// Exact repro from `.scratch/hr-adjacent-caret-movement/PLAN.md` ("Confirmed Bug A"): caret
    /// mid-word in the last of a chain of styled lines separated by dividers.
    /// Before the fix, Up from position 35 silently failed to move — it reset
    /// to 32 (the start of the current line) instead of moving up into
    /// "*Test3*"'s line.
    func test_up_silentlyFailsToMove_exactRepro() {
        let body = "Test1\n---\nTest2\n---\n*Test3*\n---\n*Test4*"
        let start = 35
        XCTAssertEqual((body as NSString).substring(with: NSRange(location: 32, length: 7)), "*Test4*")
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.up)
        runner.assertSelection(NSRange(location: offset(after: "*Test3*", in: body), length: 0))
        XCTAssertLessThan(runner.selection.location, start, "Up must move the caret up, never reset it to the current line's start")
    }

    // MARK: - Runs of consecutive dividers still skip as one block (vertical)

    func test_consecutiveDividers_skipAsOneBlock_viaHostedRunner_verticalMove() {
        let body = "a\n---\n---\nb"   // a=0 \n=1 ---=2..4 \n=5 ---=6..8 \n=9 b=10
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
        runner.key(.down)
        runner.assertSelection(NSRange(location: 10, length: 0))

        let runnerBack = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 10, length: 0))
        runnerBack.key(.up)
        runnerBack.assertSelection(NSRange(location: 1, length: 0))
    }

    // MARK: - Far from any managed region defers to super, unaffected (vertical)

    func test_plainText_farFromManagedRegion_movesBetweenLines() {
        let body = "line one\nline two\nline three\nline four"
        let start = offset(of: "line two", in: body) + 5   // mid "line two"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.down)
        let lineThree = (body as NSString).range(of: "line three")
        XCTAssertTrue(
            NSLocationInRange(runner.selection.location, NSRange(location: lineThree.location, length: lineThree.length + 1)),
            "Down from mid \"line two\" should land within \"line three\", got \(runner.selection.location)"
        )
        XCTAssertGreaterThan(runner.selection.location, start)
        runner.key(.up)
        runner.assertSelection(NSRange(location: start, length: 0))
    }
}
