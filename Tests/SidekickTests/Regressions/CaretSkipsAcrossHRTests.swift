import XCTest
import AppKit
@testable import Sidekick

// Why this file lives in Regressions/:
// User-reported issue ("Whhy is the caret on the wrong side"): the caret on
// an HR line was anchored at the right edge of the hairline, lying about
// where the next typed character would visually land. The fix declares HR
// lines uninhabitable — `HybridTextView.setSelectedRanges` redirects any
// caret landing on an HR line to the nearest non-HR neighbor, with direction
// inferred from the previous selection.
//
// Tests use HostedEditorRunner because the snap lives on HybridTextView; a
// plain NSTextView stack would bypass the override entirely.
@MainActor
final class CaretSkipsAcrossHRTests: XCTestCase {

    /// Forward motion (target > previous) lands on an HR line → snap DOWN.
    /// Body: "before\n\n---\n\nafter"
    ///                01234 5 6 789 10 11 12..16
    /// HR line = (8, 4); empty line above = (7, 1); empty line below = (12, 1).
    func test_caretMovesForwardOntoHR_snapsToBelow() {
        let runner = HostedEditorRunner(
            initialBody: "before\n\n---\n\nafter",
            initialSelection: NSRange(location: 7, length: 0)  // empty line above HR
        )
        // Simulate arrow-down landing on HR start (position 8).
        runner.inner.textView.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertEqual(
            runner.inner.textView.selectedRange().location, 12,
            "Caret moving forward onto HR must snap to start of line below HR (12)"
        )
    }

    /// Backward motion (target < previous) lands on an HR line → snap UP.
    func test_caretMovesBackwardOntoHR_snapsToAbove() {
        let runner = HostedEditorRunner(
            initialBody: "before\n\n---\n\nafter",
            initialSelection: NSRange(location: 13, length: 0)  // 'a' of "after"
        )
        runner.inner.textView.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertEqual(
            runner.inner.textView.selectedRange().location, 7,
            "Caret moving backward onto HR must snap to end of line above HR (7)"
        )
    }

    /// HR at document start has no "above" — snap MUST go below regardless
    /// of direction.
    func test_hrAtDocStart_snapsBelowOnly() {
        let runner = HostedEditorRunner(
            initialBody: "---\nafter",
            initialSelection: NSRange(location: 0, length: 0)
        )
        // Try to land at offset 2 (between dashes) from outside the HR line.
        // Use position 5 first (inside "after") then try to go to 2.
        runner.inner.textView.setSelectedRange(NSRange(location: 5, length: 0))
        runner.inner.textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(
            runner.inner.textView.selectedRange().location, 4,
            "HR at doc start has no `above` — caret must snap to start of line below HR (4)"
        )
    }

    /// HR at end of doc with no trailing newline — no "below". Snap MUST go
    /// above regardless of direction.
    func test_hrAtDocEndNoNewline_snapsAboveOnly() {
        let runner = HostedEditorRunner(
            initialBody: "before\n---",
            initialSelection: NSRange(location: 0, length: 0)
        )
        // Forward motion onto HR.
        runner.inner.textView.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertEqual(
            runner.inner.textView.selectedRange().location, 6,
            "HR at doc end with no trailing newline — snap must go up (6, end of `before`)"
        )
    }

    /// HR is the entire document — snap returns nil. Caret stays at requested
    /// location (degenerate case: nowhere to go).
    func test_hrIsEntireDoc_noSnap() {
        let runner = HostedEditorRunner(
            initialBody: "---",
            initialSelection: NSRange(location: 0, length: 0)
        )
        runner.inner.textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(
            runner.inner.textView.selectedRange().location, 2,
            "Degenerate doc (HR only) — caret stays at requested position"
        )
    }

    /// Range selections (length > 0) crossing HR must be preserved — the snap
    /// only fires on zero-length caret selections so a user can shift-select
    /// across the rule to delete it.
    func test_rangeSelectionAcrossHR_notSnapped() {
        let runner = HostedEditorRunner(
            initialBody: "before\n\n---\n\nafter",
            initialSelection: NSRange(location: 0, length: 0)
        )
        // Select from end of "before" through the empty line below HR.
        let crossing = NSRange(location: 6, length: 6)  // covers "\n\n---\n"
        runner.inner.textView.setSelectedRange(crossing)
        XCTAssertEqual(
            runner.inner.textView.selectedRange(), crossing,
            "Non-zero-length selection that crosses an HR line must be left alone"
        )
    }

    /// Typing the third dash in a non-empty paragraph converts the line to
    /// HR mid-keystroke. The same-line exemption prevents the snap from
    /// yanking the caret off the line mid-type. Then the HR-01 escape fires
    /// (plan 04-04) to append an editable line below the freshly-typed rule,
    /// so the caret ends up below the HR rather than stranded on it.
    ///
    /// Body before keystroke: "Foo\n\n--", caret 7.
    /// Body after keystroke:  "Foo\n\n---\n", caret 9 — one below the HR.
    func test_typingThirdDash_caretStaysWithinFreshlyConvertedHR() {
        let runner = HostedEditorRunner(
            initialBody: "Foo\n\n--",
            initialSelection: NSRange(location: 7, length: 0)
        )
        runner.type("-")
        XCTAssertEqual(runner.body, "Foo\n\n---\n",
                       "Three dashes typed must produce the HR source bytes plus a trailing editable line (HR-01)")
        XCTAssertEqual(
            runner.selection.location, 9,
            "Caret must be on the editable line below the freshly-typed HR (HR-01 escape)"
        )
    }

    /// Arrow-up out of HR after typing it: simulate user pressing up after
    /// the typing leaves the caret on the editable line below a freshly-typed
    /// HR line (HR-01 escape: body is now "Foo\n\n---\n", caret 9). An arrow
    /// up targets position 4 (the empty separator between "Foo" and the HR),
    /// which is NOT on the HR line — no snap fires, caret arrives normally.
    func test_arrowUpFromFreshlyTypedHR_landsAbove() {
        let runner = HostedEditorRunner(
            initialBody: "Foo\n\n--",
            initialSelection: NSRange(location: 7, length: 0)
        )
        runner.type("-")  // body becomes "Foo\n\n---\n", caret 9 (on editable line below HR)
        // Up-arrow from the line below HR → targets position 4 (the
        // start of the empty separator between "Foo" and the HR).
        runner.inner.textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(
            runner.inner.textView.selectedRange().location, 4,
            "Caret outside HR — no snap"
        )
    }

    // MARK: - HR-01: Typed-trailing-HR escape

    /// HR-01: Typing `---` as the final line of an empty doc leaves one
    /// editable line below the rule. Body must be "---\n" and caret at 4
    /// (start of the blank line below the rule) so the user can keep typing.
    func test_typedTrailingDashes_leavesEditableLineBelow() {
        let runner = HostedEditorRunner(
            initialBody: "",
            initialSelection: NSRange(location: 0, length: 0)
        )
        runner.type("---")
        XCTAssertEqual(runner.body, "---\n",
                       "Trailing typed `---` must append one editable line below the rule")
        XCTAssertEqual(runner.selection.location, 4,
                       "Caret must be at the start of the new editable line below the rule (4)")
        runner.type("x")
        XCTAssertEqual(runner.body, "---\nx",
                       "Typing after the escape must land below the rule, not on it")
    }

    /// HR-01: `***` is also recognized as a thematic break (Plan 01). Typing
    /// it as the trailing line must also trigger the escape.
    func test_typedTrailingAsterisks_leavesEditableLineBelow() {
        let runner = HostedEditorRunner(
            initialBody: "",
            initialSelection: NSRange(location: 0, length: 0)
        )
        runner.type("***")
        XCTAssertEqual(runner.body, "***\n",
                       "Trailing typed `***` must append one editable line below the rule")
        XCTAssertEqual(runner.selection.location, 4,
                       "Caret must be at start of editable line below the rule (4)")
    }

    /// HR-01: Typing `---` after some prior content (body "abc\n---", caret
    /// at 8) leaves an editable line below the rule: body "abc\n---\n", caret 8.
    func test_typedTrailingDashes_afterContent_leavesEditableLineBelow() {
        let runner = HostedEditorRunner(
            initialBody: "abc\n",
            initialSelection: NSRange(location: 4, length: 0)
        )
        runner.type("---")
        XCTAssertEqual(runner.body, "abc\n---\n",
                       "Trailing typed `---` after content must append one editable line")
        XCTAssertEqual(runner.selection.location, 8,
                       "Caret must be at start of editable line below the rule (8)")
    }

    /// HR-01 negative: typing only two dashes (`--`) must NOT add a trailing
    /// newline — `--` is not a thematic break.
    func test_typedDoubleDash_noEscape() {
        let runner = HostedEditorRunner(
            initialBody: "",
            initialSelection: NSRange(location: 0, length: 0)
        )
        runner.type("--")
        XCTAssertEqual(runner.body, "--",
                       "Two dashes are not a thematic break — no escape must fire")
    }

    // MARK: - HR-04: `/hr` + `/divider` slash quick-insert

    /// HR-04: Typing `/hr` on an otherwise-empty line auto-converts to a rule
    /// via the canonical performInsertThematicBreak routine. Body must contain
    /// "---" and must NOT contain "/hr".
    func test_slashHr_insertsRule() {
        let runner = HostedEditorRunner(
            initialBody: "",
            initialSelection: NSRange(location: 0, length: 0)
        )
        runner.type("/hr")
        XCTAssertTrue(runner.body.contains("---"),
                      "Typing `/hr` on an empty line must insert a thematic break")
        XCTAssertFalse(runner.body.contains("/hr"),
                       "The `/hr` trigger text must be consumed — must not remain in body")
    }

    /// HR-04: `/divider` is a synonym for `/hr` — same outcome.
    func test_slashDivider_insertsRule() {
        let runner = HostedEditorRunner(
            initialBody: "",
            initialSelection: NSRange(location: 0, length: 0)
        )
        runner.type("/divider")
        XCTAssertTrue(runner.body.contains("---"),
                      "Typing `/divider` on an empty line must insert a thematic break")
        XCTAssertFalse(runner.body.contains("/divider"),
                       "The `/divider` trigger text must be consumed — must not remain in body")
    }

    /// HR-04 negative: `/hrx` (extra char appended to an existing line that
    /// already contains "/hrx") must NOT trigger the quick-insert — the line
    /// content must be exactly "/hr". Note: this cannot be tested purely via
    /// char-by-char typing (typing "/" then "h" then "r" fires the trigger
    /// before "x" can be appended — that is correct behavior). Instead, we
    /// seed the body to "/hr" and then type "x" to verify that with a non-
    /// empty partial match the trigger does not fire for the final content.
    ///
    /// Also verifies "x/hr" (prefix + trigger on a non-blank line) using
    /// `initialBody: "x"` + typing "/hr" — the line starts non-empty so the
    /// exact-match guard (line content must be exactly "/hr") blocks the trigger.
    func test_slashHrx_noInsert() {
        // Seed "/hrx" directly: set body to "/hrx" and put caret at end.
        // No typing-trigger can fire on pre-seeded body — only the next
        // typed character's insertText call checks the helper.
        let runner = HostedEditorRunner(
            initialBody: "/hrx",
            initialSelection: NSRange(location: 4, length: 0)
        )
        // Type one more char — at this point line content is "/hrxy", which
        // is NOT an exact match; no trigger must fire.
        runner.type("y")
        XCTAssertFalse(runner.body.contains("---"),
                       "No rule must be inserted when line is not exactly `/hr`")

        // Also verify: prefix "x" before "/hr" prevents trigger.
        let runner2 = HostedEditorRunner(
            initialBody: "x",
            initialSelection: NSRange(location: 1, length: 0)
        )
        runner2.type("/hr")
        XCTAssertFalse(runner2.body.contains("---"),
                       "No rule must be inserted when line is `x/hr` — not line-exact")
    }

    /// HR-04 / WR-01 regression: typing `/hr` INSIDE a fenced code block must
    /// NOT quick-insert — and, critically, must not silently eat the trigger
    /// text. `performInsertThematicBreak` already bails inside a fence, but the
    /// slash helper used to delete the trigger BEFORE delegating, so `/hr`
    /// vanished with no rule inserted (data loss). The fence guard now bails
    /// before any mutation, leaving `/hr` as literal source inside the fence.
    ///
    /// Seed a paired fence containing `/h` and complete the trigger by typing
    /// the final `r` with the caret inside the fence content.
    /// Body: "```\n/h\n```", caret at 6 (just after `h`). Type `r`.
    func test_slashHr_insideFence_staysLiteral() {
        let runner = HostedEditorRunner(
            initialBody: "```\n/h\n```",
            initialSelection: NSRange(location: 6, length: 0)
        )
        runner.type("r")
        XCTAssertEqual(runner.body, "```\n/hr\n```",
                       "`/hr` typed inside a fenced code block must stay literal — no rule, no lost text")
        XCTAssertFalse(runner.body.contains("---"),
                       "No thematic break must be inserted from inside a fenced code block")
    }
}
