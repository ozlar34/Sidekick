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
//
// Ticket 05 extends this file with `HybridTextView.moveLeftAndModifySelection(_:)`
// / `moveRightAndModifySelection(_:)` coverage: those overrides extend or
// shrink a selection's moving edge by one character, reusing the exact
// naive-step + snap-rescue chain `moveLeft`/`moveRight` (ticket 03/04) use
// for a plain caret, combined with a tracked selection anchor (see
// `HybridTextView.selectionExtensionAnchor`'s doc comment for why AppKit's
// own selection state doesn't expose which end of a range is the anchor).
// The cases below cover: N-presses-produce-length-N on plain/bold/italic/
// underline/strikethrough text after a divider (both directions), growing a
// selection up to and across a divider by exactly the expected amount
// (including a divider immediately followed by a hidden inline marker, so
// both managed regions get crossed back-to-back), and — the actual product
// requirement motivating this ticket — that wrapping a shift-extended
// word right after a divider touches only that word and leaves the
// divider's `---` line byte-identical.
//
// Ticket 08 extends this file with the multi-divider shift-extend-overshoot
// repro (`test_shiftRight_fromLineTerminator_multiDividerChain_exactRepro`)
// and its Cmd+B-after-shift-extend follow-up. Root cause: on the step whose
// naive one-character target lands exactly on the line terminator ending the
// CURRENT (unmanaged) line, `correctedCaretTarget`'s gate never looked one
// line ahead to see the FOLLOWING line was a divider, so it deferred to
// `super.moveRightAndModifySelection(sender)` — which jumped the selection
// past the entire `"\n---\n"` block in one step instead of stopping at the
// terminator.
//
// Scope note (ticket 08): this file covers exactly `moveLeftAndModifySelection`/
// `moveRightAndModifySelection`/`moveUpAndModifySelection`/
// `moveDownAndModifySelection` near an HR/hidden-marker boundary — nothing
// else. Deliberately NOT covered/verified: word-jump modify-selection
// variants (`moveWordLeftAndModifySelection:`/`moveWordRightAndModifySelection:`,
// Option+Shift+Arrow) and line/paragraph/document jump modify-selection
// variants (Cmd+Shift+Arrow/Home/End) — plausibly share the same root cause
// but were never tested; a future bug report there is not necessarily a
// regression of this fix. `performWrap`/`applyMarkdownWrap` in
// `FormattingToolbarView.swift` was investigated and ruled out as not
// independently buggy — given a correct selection it produces correct output
// every time; the divider-corruption symptom traced to the shift-extend
// overshoot this ticket (08) fixes, not to the wrap logic.
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

    // MARK: - Helpers (index arithmetic via substring search, not hand-counted)
    // Same helpers as PlainArrowMoveAcrossDividerTests — duplicated locally
    // since that file's are `private` to its own type.

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

    // MARK: - N presses of Shift+Right/Shift+Left produce a selection of
    // exactly length N, right after a divider, for each style on the
    // surrounding text (AC #1, #2).
    //
    // Each case starts the caret at the first VISIBLE character of the line
    // below the divider (i.e. already past any hidden opening marker — the
    // marker-skip mechanics themselves are ticket 03/04 territory and are
    // separately exercised, combined with divider-crossing, below). This
    // isolates the thing this ticket actually adds: extending a selection
    // one visible character at a time through styled (but not
    // hidden-marker) text is unaffected by the new overrides — the cheap
    // gate inside `correctedCaretTarget` sees no managed region on any of
    // these steps and defers straight to `super` every time.

    private func assertShiftRightThenShiftLeftStepsByOne(
        body: String,
        start: Int,
        steps: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        for n in 1...steps {
            runner.key(.shiftRight)
            runner.assertSelection(NSRange(location: start, length: n), file: file, line: line)
        }
        for n in stride(from: steps - 1, through: 0, by: -1) {
            runner.key(.shiftLeft)
            runner.assertSelection(NSRange(location: start, length: n), file: file, line: line)
        }
    }

    func test_shiftRightThenShiftLeft_plainWordAfterDivider() {
        let body = "before\n---\nafter word"
        assertShiftRightThenShiftLeftStepsByOne(body: body, start: offset(of: "after", in: body), steps: 3)
    }

    func test_shiftRightThenShiftLeft_boldWordAfterDivider() {
        let body = "before\n---\n**Bold word here**"
        assertShiftRightThenShiftLeftStepsByOne(body: body, start: offset(of: "Bold", in: body), steps: 3)
    }

    func test_shiftRightThenShiftLeft_italicWordAfterDivider() {
        let body = "before\n---\n*Italic word here*"
        assertShiftRightThenShiftLeftStepsByOne(body: body, start: offset(of: "Italic", in: body), steps: 3)
    }

    func test_shiftRightThenShiftLeft_underlineWordAfterDivider() {
        let body = "before\n---\n<u>Underline word here</u>"
        assertShiftRightThenShiftLeftStepsByOne(body: body, start: offset(of: "Underline", in: body), steps: 3)
    }

    func test_shiftRightThenShiftLeft_strikethroughWordAfterDivider() {
        let body = "before\n---\n~~Strike word here~~"
        assertShiftRightThenShiftLeftStepsByOne(body: body, start: offset(of: "Strike", in: body), steps: 3)
    }

    // MARK: - N presses of Shift+Left ALONE (no prior Shift+Right) produce
    // a selection of exactly length N, growing BACKWARD from a caret
    // placed after the region, for each style (AC #2 independently — every
    // case above only exercises Shift+Left as the shrink-back half of a
    // Shift+Right-then-Shift+Left pair; none of them start a chain with
    // Shift+Left or grow a selection using it alone).

    private func assertShiftLeftStepsByOne(
        body: String,
        end: Int,
        steps: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: end, length: 0))
        for n in 1...steps {
            runner.key(.shiftLeft)
            runner.assertSelection(NSRange(location: end - n, length: n), file: file, line: line)
        }
    }

    func test_shiftLeft_extendsBackward_producesExactLength_plainWord() {
        let body = "before\n---\nafter word"
        assertShiftLeftStepsByOne(body: body, end: offset(after: "after", in: body), steps: 3)
    }

    func test_shiftLeft_extendsBackward_producesExactLength_boldWord() {
        let body = "before\n---\n**Bold word here**"
        assertShiftLeftStepsByOne(body: body, end: offset(after: "Bold", in: body), steps: 3)
    }

    func test_shiftLeft_extendsBackward_producesExactLength_italicWord() {
        let body = "before\n---\n*Italic word here*"
        assertShiftLeftStepsByOne(body: body, end: offset(after: "Italic", in: body), steps: 3)
    }

    func test_shiftLeft_extendsBackward_producesExactLength_underlineWord() {
        let body = "before\n---\n<u>Underline word here</u>"
        assertShiftLeftStepsByOne(body: body, end: offset(after: "Underline", in: body), steps: 3)
    }

    func test_shiftLeft_extendsBackward_producesExactLength_strikethroughWord() {
        let body = "before\n---\n~~Strike word here~~"
        assertShiftLeftStepsByOne(body: body, end: offset(after: "Strike", in: body), steps: 3)
    }

    // MARK: - Extending up to and across a divider grows the selection by
    // exactly the expected amount, never overshooting (AC #3).

    /// Forward: caret starts mid-word above a divider, extends through the
    /// rest of that word, across the whole divider block in one press (the
    /// divider's `\n---\n` is uninhabitable — same one-hop rule
    /// `moveRight(_:)` already uses for a plain caret, ticket 03), then on
    /// into the plain word below.
    func test_shiftRight_extendsAcrossDivider_growsByExpectedAmount() {
        let body = "before\n---\nafter"
        let start = offset(of: "ore", in: body)   // mid "before": caret between "bef" and "ore"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))

        var previousLength = 0
        for _ in 0..<6 {
            runner.key(.shiftRight)
            let current = runner.selection
            XCTAssertEqual(current.location, start, "Anchor must never move")
            XCTAssertGreaterThan(current.length, previousLength, "Every press must grow the selection")
            previousLength = current.length
        }
        // After 6 presses the selection must have crossed the entire
        // divider block and landed exactly 2 characters into "after" — not
        // one character short (stuck on the divider) and not overshot
        // further than the naive 1-char-per-visible-step count warrants.
        let expectedEnd = offset(of: "after", in: body) + 2
        runner.assertSelection(NSRange(location: start, length: expectedEnd - start))
        XCTAssertEqual(
            (body as NSString).substring(with: runner.selection),
            "ore\n---\naf",
            "Selected text must be exactly the run from the anchor through 2 characters into \"after\", divider included, nothing extra"
        )
    }

    /// Mirrored: caret starts mid-word below a divider, extends backward
    /// through the rest of that word, across the whole divider block, then
    /// up into the plain word above.
    func test_shiftLeft_extendsAcrossDivider_growsByExpectedAmount() {
        let body = "before\nafter word"
            .replacingOccurrences(of: "\n", with: "\n---\n")
        // body == "before\n---\nafter word"
        let start = offset(of: "ter word", in: body)   // mid "after": caret between "af" and "ter"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))

        var previousLength = 0
        for _ in 0..<6 {
            runner.key(.shiftLeft)
            let current = runner.selection
            XCTAssertEqual(NSMaxRange(current), start, "Anchor must never move")
            XCTAssertGreaterThan(current.length, previousLength, "Every press must grow the selection")
            previousLength = current.length
        }
        // 6 presses starting from `start` (offset of "ter word") and
        // extending backward land on exactly the same range that 6 presses
        // starting from offset(of: "ore") and extending forward land on
        // (the forward test above) — both walk the identical span of the
        // document, just from opposite ends, and the divider block is
        // still crossed in a single press either way.
        let expectedStart = offset(of: "ore", in: body)
        runner.assertSelection(NSRange(location: expectedStart, length: start - expectedStart))
        XCTAssertEqual(
            (body as NSString).substring(with: runner.selection),
            "ore\n---\naf",
            "Selected text must be exactly the run from the anchor back through the divider to 3 characters into \"before\", divider included, nothing extra"
        )
    }

    /// Combined case: a divider immediately followed by a hidden inline
    /// marker (bold). The first press must cross the whole divider block,
    /// the second must cross the whole hidden `**` marker run, and only the
    /// third press should be a normal 1-character step — proving the two
    /// managed regions compose correctly back-to-back instead of the
    /// second press's naive target landing mid-marker and needing a
    /// follow-up press to actually move.
    func test_shiftRight_extendsAcrossDividerThenHiddenMarker_growsByExpectedAmountAtEachStep() {
        let body = "before\n---\n**Bold below**"
        let start = offset(after: "before", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))

        runner.key(.shiftRight)
        runner.assertSelection(NSRange(location: start, length: offset(of: "**Bold", in: body) - start))

        runner.key(.shiftRight)
        runner.assertSelection(NSRange(location: start, length: offset(of: "Bold", in: body) - start))

        runner.key(.shiftRight)
        runner.assertSelection(NSRange(location: start, length: offset(of: "old", in: body) - start))
    }

    // MARK: - `selectionExtensionOwnedByOverride` safeguard: once a chain
    // has needed a correction, every later step in the SAME chain stays
    // self-computed instead of deferring back to `super` — see
    // `stepExtension`'s doc comment for the confirmed repro this guards
    // against (a post-correction step handed back to `super` silently
    // re-anchors the selection instead of continuing from the tracked
    // anchor).

    /// Extends left from mid-"after" across the whole divider block (one
    /// corrected press — the same repro `stepExtension`'s doc comment
    /// describes: anchor 13 jumps the selection to `{6, 7}`), then keeps
    /// pressing Shift+Left for two MORE steps that land in plain,
    /// unmanaged text ("before"). Those two steps have nothing left to
    /// correct — `correctedCaretTarget` returns `nil` for both — so only
    /// `selectionExtensionOwnedByOverride` staying latched keeps them
    /// self-computed instead of deferring to `super`, which (per the
    /// documented repro) would silently re-anchor the selection to the
    /// moving edge instead of continuing to grow it from the true anchor.
    func test_shiftLeftAndModifySelection_staysSelfManaged_forStepsAfterDividerCorrection() {
        let body = "before\n---\nafter word"
        let anchor = offset(of: "ter word", in: body)   // mid "after", matches stepExtension's doc-comment repro
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: anchor, length: 0))

        // Two plain steps inside "after", then the one-hop divider
        // crossing — matches the doc comment's repro exactly.
        for _ in 0..<3 {
            runner.key(.shiftLeft)
            XCTAssertEqual(NSMaxRange(runner.selection), anchor, "Anchor must never move")
        }
        runner.assertSelection(NSRange(location: 6, length: 7))

        // The part that exercises the safeguard: two MORE presses, now
        // purely in plain "before" text.
        runner.key(.shiftLeft)
        XCTAssertEqual(NSMaxRange(runner.selection), anchor, "Anchor must not move on a post-correction plain step")
        runner.key(.shiftLeft)
        XCTAssertEqual(NSMaxRange(runner.selection), anchor, "Anchor must not move on a second post-correction plain step")

        let expectedStart = offset(of: "re", in: body)
        runner.assertSelection(NSRange(location: expectedStart, length: anchor - expectedStart))
        XCTAssertEqual(
            (body as NSString).substring(with: runner.selection),
            "re\n---\naf",
            "Selected text must be exactly the run from 2 characters into \"before\" through the divider to the anchor mid-\"after\""
        )
    }

    // MARK: - Anchor-crossing NSRange arithmetic in `stepExtension`: the
    // selection's "sides" flip correctly when Shift+Right growth (anchor
    // on the left) is shrunk by Shift+Left past zero-length and regrown
    // on the opposite side (anchor now on the right) (AC #1/#2 combined,
    // stress case).

    /// Grows via Shift+Right (anchor mid-"before", on the left), crosses
    /// the divider once forward, then shrinks the same selection back down
    /// via Shift+Left — crossing the SAME divider a second time, backward
    /// — until it collapses to a zero-length caret exactly at the anchor,
    /// then continues past that point, growing into the opposite
    /// direction with the anchor now pinned to the right (`NSMaxRange`)
    /// instead of the left.
    func test_shiftRightThenShiftLeft_selectionCrossesBackOverAnchor_intoOppositeSide() {
        let body = "before\n---\nafter"
        let anchor = offset(of: "ore", in: body)   // mid "before": between "bef" and "ore"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: anchor, length: 0))

        // Phase 1 — grow right, anchor fixed on the left, crossing the
        // divider once (same setup/endpoint as
        // `test_shiftRight_extendsAcrossDivider_growsByExpectedAmount` above).
        var previousLength = 0
        for _ in 0..<6 {
            runner.key(.shiftRight)
            let current = runner.selection
            XCTAssertEqual(current.location, anchor, "Anchor must stay on the left while growing right")
            XCTAssertGreaterThan(current.length, previousLength, "Every press must grow the selection")
            previousLength = current.length
        }
        let expectedEnd = offset(of: "after", in: body) + 2
        runner.assertSelection(NSRange(location: anchor, length: expectedEnd - anchor))

        // Phase 2 — shrink the SAME selection back down, crossing the
        // divider a second time (backward), until it collapses to a
        // zero-length caret exactly at the anchor.
        previousLength = expectedEnd - anchor
        for _ in 0..<6 {
            runner.key(.shiftLeft)
            let current = runner.selection
            XCTAssertEqual(current.location, anchor, "Anchor must still be the fixed left side while shrinking")
            XCTAssertLessThan(current.length, previousLength, "Every press must shrink the selection")
            previousLength = current.length
        }
        runner.assertSelection(NSRange(location: anchor, length: 0))

        // Phase 3 — continuing Shift+Left PAST the collapse point starts a
        // fresh extension chain at the same point, but growing in the
        // OPPOSITE direction: the anchor ends up pinned to the RIGHT of
        // the selection instead of the left.
        previousLength = 0
        for _ in 0..<3 {
            runner.key(.shiftLeft)
            let current = runner.selection
            XCTAssertEqual(NSMaxRange(current), anchor, "Anchor must now be pinned to the right of the selection")
            XCTAssertGreaterThan(current.length, previousLength, "Every press must grow the selection further left")
            previousLength = current.length
        }
        // 3 presses from position 3 (mid "before") land exactly at the
        // document start — "before"'s first 3 characters, "bef".
        runner.assertSelection(NSRange(location: 0, length: anchor))
        XCTAssertEqual(
            (body as NSString).substring(with: runner.selection),
            "bef",
            "Selected text must be exactly the first 3 characters of \"before\""
        )
    }

    // MARK: - Shift-extended word right after a divider, wrapped, touches
    // only that word — the divider's `---` line is byte-identical (AC #4).

    private func assertWrapTouchesOnlySelectedWord(
        prefix: String,
        suffix: String,
        expectedWrappedBody: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let body = "before\n---\nafter word"
        let dividerLine = "---"
        let start = offset(of: "after", in: body)
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        for _ in 0..<5 { runner.key(.shiftRight) }   // selects "after" (5 chars)
        runner.assertSelection(NSRange(location: start, length: 5), file: file, line: line)

        FormattingToolbarView.performWrap(prefix: prefix, suffix: suffix, in: runner.inner.textView)

        runner.assertBody(expectedWrappedBody, file: file, line: line)
        XCTAssertTrue(
            runner.body.contains("\n" + dividerLine + "\n"),
            "Divider line must survive byte-identical",
            file: file, line: line
        )
    }

    func test_wrapBold_afterShiftExtend_touchesOnlySelectedWord() {
        assertWrapTouchesOnlySelectedWord(
            prefix: "**", suffix: "**",
            expectedWrappedBody: "before\n---\n**after** word"
        )
    }

    func test_wrapItalic_afterShiftExtend_touchesOnlySelectedWord() {
        assertWrapTouchesOnlySelectedWord(
            prefix: "*", suffix: "*",
            expectedWrappedBody: "before\n---\n*after* word"
        )
    }

    func test_wrapUnderline_afterShiftExtend_touchesOnlySelectedWord() {
        assertWrapTouchesOnlySelectedWord(
            prefix: "<u>", suffix: "</u>",
            expectedWrappedBody: "before\n---\n<u>after</u> word"
        )
    }

    func test_wrapStrikethrough_afterShiftExtend_touchesOnlySelectedWord() {
        assertWrapTouchesOnlySelectedWord(
            prefix: "~~", suffix: "~~",
            expectedWrappedBody: "before\n---\n~~after~~ word"
        )
    }

    // MARK: - Ticket 06: Shift+Down/Shift+Up selection extension across a
    // divider.
    //
    // `HybridTextView.moveDownAndModifySelection(_:)` /
    // `moveUpAndModifySelection(_:)` combine the naive same-column vertical
    // step `moveDown(_:)`/`moveUp(_:)` (ticket 04) compute — but applied to
    // the moving EDGE of the selection instead of `current.location` — with
    // the anchor/edge extension bookkeeping `moveRightAndModifySelection(_:)`/
    // `moveLeftAndModifySelection(_:)` (ticket 05) already use. The style
    // matrices below mirror `PlainArrowMoveAcrossDividerTests`'s "Down: a
    // line above a divider -> the line below" / "Up: a line below a divider
    // -> the line above" sections exactly — same bodies, same start
    // locations, same corrected landing points — since a first Shift+Down/
    // Shift+Up press from a fresh (zero-length) selection re-anchors at the
    // caret and so must land the moving edge on the identical target the
    // plain override would land the caret on. The point being verified is
    // that the SELECTION's edge, not just a caret, gets that same one-hop
    // correction (AC: "the resulting selection length equals what
    // plain-text behaviour would produce", i.e. never stuck mid-divider,
    // never overshooting past the corrected landing point).

    private func assertShiftDownExtendsAcrossDivider(
        body: String,
        start: Int,
        expectedEdge: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.shiftDown)
        runner.assertSelection(NSRange(location: start, length: expectedEdge - start), file: file, line: line)
    }

    private func assertShiftUpExtendsAcrossDivider(
        body: String,
        start: Int,
        expectedEdge: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.shiftUp)
        runner.assertSelection(NSRange(location: expectedEdge, length: start - expectedEdge), file: file, line: line)
    }

    // MARK: - Shift+Down: line above a divider -> line below (style matrix)

    func test_shiftDown_plainAbove_plainBelow() {
        let body = "before\n---\nafter"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "after", in: body))
    }

    /// The plain-arrow analog (`test_down_plainAbove_boldBelow`) is the
    /// confirmed-broken case this whole effort started from: a hidden
    /// bold-opening marker immediately after the divider's line break.
    func test_shiftDown_plainAbove_boldBelow() {
        let body = "before\n---\n**Bold below**"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "**Bold below**", in: body))
    }

    func test_shiftDown_plainAbove_italicBelow() {
        let body = "before\n---\n*Italic below*"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "*Italic below*", in: body))
    }

    func test_shiftDown_plainAbove_underlineBelow() {
        let body = "before\n---\n<u>Underline below</u>"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "<u>Underline below</u>", in: body))
    }

    func test_shiftDown_plainAbove_strikethroughBelow() {
        let body = "before\n---\n~~Strike below~~"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "~~Strike below~~", in: body))
    }

    /// Symmetric direction: styled line above, plain line below.
    func test_shiftDown_boldAbove_plainBelow() {
        let body = "**Bold above**\n---\nafter"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "after", in: body))
    }

    func test_shiftDown_italicAbove_plainBelow() {
        let body = "*Italic above*\n---\nafter"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "after", in: body))
    }

    func test_shiftDown_underlineAbove_plainBelow() {
        let body = "<u>Underline above</u>\n---\nafter"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "after", in: body))
    }

    func test_shiftDown_strikethroughAbove_plainBelow() {
        let body = "~~Strike above~~\n---\nafter"
        assertShiftDownExtendsAcrossDivider(body: body, start: 0, expectedEdge: offset(of: "after", in: body))
    }

    // MARK: - Shift+Up: line below a divider -> line above (mirrored style matrix)

    func test_shiftUp_plainAbove_plainBelow() {
        let body = "before\n---\nafter"
        let start = offset(of: "after", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(after: "before", in: body))
    }

    /// The confirmed-broken case, mirrored: caret resting at the start of
    /// the hidden bold-opening marker run immediately below the divider.
    func test_shiftUp_plainAbove_boldBelow() {
        let body = "before\n---\n**Bold below**"
        let start = offset(of: "**Bold below**", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(after: "before", in: body))
    }

    func test_shiftUp_plainAbove_italicBelow() {
        let body = "before\n---\n*Italic below*"
        let start = offset(of: "*Italic below*", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(after: "before", in: body))
    }

    func test_shiftUp_plainAbove_underlineBelow() {
        let body = "before\n---\n<u>Underline below</u>"
        let start = offset(of: "<u>Underline below</u>", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(after: "before", in: body))
    }

    func test_shiftUp_plainAbove_strikethroughBelow() {
        let body = "before\n---\n~~Strike below~~"
        let start = offset(of: "~~Strike below~~", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(after: "before", in: body))
    }

    /// Symmetric direction: styled line above, plain line below.
    func test_shiftUp_boldAbove_plainBelow() {
        let body = "**Bold above**\n---\nafter"
        let start = offset(of: "after", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(of: "\n---", in: body))
    }

    func test_shiftUp_italicAbove_plainBelow() {
        let body = "*Italic above*\n---\nafter"
        let start = offset(of: "after", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(of: "\n---", in: body))
    }

    func test_shiftUp_underlineAbove_plainBelow() {
        let body = "<u>Underline above</u>\n---\nafter"
        let start = offset(of: "after", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(of: "\n---", in: body))
    }

    func test_shiftUp_strikethroughAbove_plainBelow() {
        let body = "~~Strike above~~\n---\nafter"
        let start = offset(of: "after", in: body)
        assertShiftUpExtendsAcrossDivider(body: body, start: start, expectedEdge: offset(of: "\n---", in: body))
    }

    // MARK: - Far from any managed region defers to super, unaffected
    // (mirrors `test_plainText_farFromManagedRegion_movesBetweenLines`)

    func test_shiftDown_farFromManagedRegion_extendsBetweenLines() {
        let body = "line one\nline two\nline three\nline four"
        let start = offset(of: "line two", in: body) + 5   // mid "line two"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.shiftDown)
        let current = runner.selection
        XCTAssertEqual(current.location, start, "Anchor must not move")
        let lineThree = (body as NSString).range(of: "line three")
        XCTAssertTrue(
            NSLocationInRange(NSMaxRange(current), NSRange(location: lineThree.location, length: lineThree.length + 1)),
            "Shift+Down from mid \"line two\" should extend the moving edge into \"line three\", got \(NSMaxRange(current))"
        )
    }

    func test_shiftUp_farFromManagedRegion_extendsBetweenLines() {
        let body = "line one\nline two\nline three\nline four"
        let start = offset(of: "line three", in: body) + 5   // mid "line three"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: start, length: 0))
        runner.key(.shiftUp)
        let current = runner.selection
        XCTAssertEqual(NSMaxRange(current), start, "Anchor must not move")
        let lineTwo = (body as NSString).range(of: "line two")
        XCTAssertTrue(
            NSLocationInRange(current.location, NSRange(location: lineTwo.location, length: lineTwo.length + 1)),
            "Shift+Up from mid \"line three\" should extend the moving edge into \"line two\", got \(current.location)"
        )
    }

    // MARK: - `selectionExtensionOwnedByOverride` safeguard, vertical chain
    // (mirrors `test_shiftLeftAndModifySelection_staysSelfManaged_forStepsAfterDividerCorrection`)

    /// Once a Shift+Down chain has needed a divider correction, a SECOND
    /// Shift+Down press landing purely in plain, unmanaged text (`"line2"`
    /// to `"line3"`, no divider between them) must still be self-computed
    /// via the latched `selectionExtensionOwnedByOverride` flag rather than
    /// deferred to `super` — deferring would silently re-anchor the
    /// selection to the moving edge instead of continuing to grow it from
    /// the true anchor (see `stepExtension`'s doc comment for the confirmed
    /// repro, established there for the horizontal chain but structurally
    /// identical for a vertical one).
    func test_shiftDownAndModifySelection_staysSelfManaged_forStepsAfterDividerCorrection() {
        let body = "x\n---\nline2\nline3"
        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))

        // First press: crosses the divider (a correction), anchored at 0.
        runner.key(.shiftDown)
        XCTAssertEqual(runner.selection.location, 0, "Anchor must not move")
        runner.assertSelection(NSRange(location: 0, length: offset(of: "line2", in: body)))

        // Second press: purely plain text ("line2" -> "line3"), nothing left
        // to correct — only the latched flag keeps this self-managed.
        runner.key(.shiftDown)
        XCTAssertEqual(runner.selection.location, 0, "Anchor must not move on the post-correction plain step")
        runner.assertSelection(NSRange(location: 0, length: offset(of: "line3", in: body)))
    }

    // MARK: - Ticket 08: exact multi-divider repro from
    // `.scratch/hr-adjacent-caret-movement/PLAN.md` (same fixture
    // `PlainArrowMoveAcrossDividerTests.test_up_silentlyFailsToMove_exactRepro`
    // and `test_right_fromHiddenMarkerSource_multiDividerChain_exactRepro`
    // use).

    private let multiDividerBody = "Test1\n---\nTest2\n---\n*Test3*\n---\n*Test4*"

    /// Confirmed-live-broken case: 5 consecutive Shift+Right presses from
    /// the start of "Test2" (offset 10) grew the selection 1, 2, 3, 4, then
    /// OVERSHOT to 9 on the 5th press instead of stopping at 5 — swallowing
    /// the following divider's `"\n---"` instead of stopping right before
    /// it. Root cause: the 5th press's naive one-character target (15) lands
    /// exactly on the `\n` terminating "Test2"'s own (unmanaged) line — the
    /// gate never looked one line ahead to see the FOLLOWING line (16,
    /// "---") was a divider, so it deferred to
    /// `super.moveRightAndModifySelection(sender)`, whose native extension
    /// jumped the whole `"\n---\n"` block in one step.
    func test_shiftRight_fromLineTerminator_multiDividerChain_exactRepro() {
        let start = 10
        XCTAssertEqual((multiDividerBody as NSString).substring(with: NSRange(location: 10, length: 5)), "Test2")
        let runner = HostedEditorRunner(initialBody: multiDividerBody, initialSelection: NSRange(location: start, length: 0))
        let expectedLengths = [1, 2, 3, 4, 5]
        for expected in expectedLengths {
            runner.key(.shiftRight)
            runner.assertSelection(NSRange(location: start, length: expected))
        }
        runner.assertSelection(NSRange(location: 10, length: 5))
    }

    /// Follow-on from the repro above: Cmd+B applied to the CORRECT `(10,5)`
    /// selection must wrap only "Test2" — `**Test2**` — leaving every
    /// divider byte-identical. Before the ticket-08 fix, the over-extended
    /// `(10,9)` selection from the bug above would have wrapped
    /// `"Test2\n---"` instead, corrupting the divider; that was never a
    /// separate wrap-logic bug (see `assertWrapTouchesOnlySelectedWord`
    /// above and this file's scope note) — fixing the selection here is
    /// sufficient.
    func test_wrapBold_afterShiftExtend_multiDividerChain_touchesOnlySelectedWord() {
        let start = 10
        let runner = HostedEditorRunner(initialBody: multiDividerBody, initialSelection: NSRange(location: start, length: 0))
        for _ in 0..<5 { runner.key(.shiftRight) }
        runner.assertSelection(NSRange(location: start, length: 5))

        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: runner.inner.textView)

        runner.assertBody("Test1\n---\n**Test2**\n---\n*Test3*\n---\n*Test4*")
    }

    /// Symmetric backward direction: Shift+Left from the end of "Test3"
    /// (offset 26, right before its own closing hidden `*`) growing
    /// backward across the SAME kind of boundary this file's forward repro
    /// covers. Included per ticket 08's brief to check whether
    /// `moveLeftAndModifySelection` is vulnerable to the same overshoot —
    /// it is not: NSString's line-terminator convention attaches a
    /// terminator to the line it ENDS, so a backward-moving naive step that
    /// lands on a terminator already belongs to the line it's leaving (caught
    /// directly by the existing "naive's own line is managed" check) — no
    /// one-line-lookahead gap exists in this direction. This locks in that
    /// non-vulnerability rather than asserting a fix.
    func test_shiftLeft_fromWithinLine_multiDividerChain_noOvershoot() {
        let start = 26
        XCTAssertEqual((multiDividerBody as NSString).substring(with: NSRange(location: 21, length: 5)), "Test3")
        let runner = HostedEditorRunner(initialBody: multiDividerBody, initialSelection: NSRange(location: start, length: 0))
        let expectedLengths = [1, 2, 3, 4, 5]
        for expected in expectedLengths {
            runner.key(.shiftLeft)
            runner.assertSelection(NSRange(location: start - expected, length: expected))
        }
        runner.assertSelection(NSRange(location: 21, length: 5))
        XCTAssertEqual((multiDividerBody as NSString).substring(with: runner.selection), "Test3")
    }

    // MARK: - Ticket 08 (standards-fix iteration): `moveDownAndModifySelection`/
    // `moveUpAndModifySelection` share `stepExtension`'s `naiveIsVerifiedStep`
    // gate with the plain vertical overrides — mirrors
    // `PlainArrowMoveAcrossDividerTests.test_down_fromHiddenMarkerSource_trustsSuperNotNaiveColumnGuess`
    // for the Shift+Down modify-selection path (same fixture, same
    // rationale: a caret/edge sitting on a zero-width `.sidekickHiddenMarker`
    // run must not have its raw column count trusted as a verified vertical
    // step just because the SOURCE line happens to contain a hidden marker).

    func test_shiftDown_fromHiddenMarkerSource_trustsSuperNotNaiveColumnGuess() {
        let body = "**Bold** text\n0123456789ABCDEF"
        XCTAssertEqual((body as NSString).substring(with: NSRange(location: 6, length: 2)), "**",
                       "sanity: offset 6 must be the closing bold marker's hidden run")
        let lineTwoStart = offset(of: "0123456789ABCDEF", in: body)
        let buggyNaiveGuess = lineTwoStart + 6   // what the pre-fix code returned directly

        let runner = HostedEditorRunner(initialBody: body, initialSelection: NSRange(location: 6, length: 0))
        runner.key(.shiftDown)

        let edge = NSMaxRange(runner.selection)
        XCTAssertEqual(runner.selection.location, 6, "anchor must stay at the caret's start")
        XCTAssertNotEqual(edge, buggyNaiveGuess,
                          "Shift+Down must not trust the raw-column guess as a verified step near a hidden marker")
        XCTAssertLessThan(edge, buggyNaiveGuess,
                          "line 2 has no hidden characters, so any on-screen-x-preserving edge must land before the raw-column-6 guess")
        XCTAssertGreaterThanOrEqual(edge, lineTwoStart, "edge must still land on line 2")
    }
}
