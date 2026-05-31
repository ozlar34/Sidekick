import XCTest
import AppKit
import SwiftUI
@testable import Sidekick

/// Covers interactive editor delegate paths that don't lend themselves to
/// pure-string tests — `textView(_:doCommandBy:)` routing in particular.
///
/// Builds the minimum live four-piece TextKit assembly (storage + layout
/// manager + container + text view) plus a HybridEditorView so we can
/// invoke the Coordinator directly. Mirrors the windowless setup that
/// PerformWrapTests already proves works without an NSWindow.
@MainActor
final class EditorInteractionTests: XCTestCase {

    private func makeStack(body: String, selection: NSRange)
        -> (textView: NSTextView, controller: HybridEditorController, coordinator: HybridEditorView.Coordinator)
    {
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            textContainer: container
        )
        textView.isRichText = false
        textView.allowsUndo = true
        if !body.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: body)
        }
        textView.setSelectedRange(selection)

        let controller = HybridEditorController()
        var binding = body
        let view = HybridEditorView(
            text: Binding(get: { binding }, set: { binding = $0 }),
            controller: controller
        )
        let coordinator = view.makeCoordinator()
        return (textView, controller, coordinator)
    }

    // MARK: - F-04 — Body→title Shift-Tab

    func test_shiftTab_atBodyOffsetZero_firesCallback() {
        let stack = makeStack(body: "hello", selection: NSRange(location: 0, length: 0))
        var fired = false
        stack.controller.onShiftTabAtBodyStart = { fired = true }

        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )
        XCTAssertTrue(handled, "Shift-Tab at offset 0 must be consumed")
        XCTAssertTrue(fired, "Callback must fire so EditorPaneView can pull focus to the title field")
    }

    func test_shiftTab_atMidBody_doesNotFireCallback() {
        let stack = makeStack(body: "hello", selection: NSRange(location: 3, length: 0))
        var fired = false
        stack.controller.onShiftTabAtBodyStart = { fired = true }

        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )
        XCTAssertFalse(handled, "Shift-Tab mid-body falls through to NSTextView default behavior")
        XCTAssertFalse(fired, "Callback must not fire when caret is past offset 0")
    }

    func test_shiftTab_withSelection_doesNotFireCallback() {
        // Caret at 0 but with a non-empty selection — user is range-selecting,
        // not at the very start of the document. Behave like mid-body.
        let stack = makeStack(body: "hello", selection: NSRange(location: 0, length: 3))
        var fired = false
        stack.controller.onShiftTabAtBodyStart = { fired = true }

        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )
        XCTAssertFalse(handled)
        XCTAssertFalse(fired)
    }

    func test_shiftTab_withoutCallback_isNoOp() {
        // Controller without a callback wired (e.g. previews, tests that
        // don't care about focus handoff) must NOT crash and must NOT
        // claim the keystroke.
        let stack = makeStack(body: "hello", selection: NSRange(location: 0, length: 0))
        // Don't set onShiftTabAtBodyStart — leave it nil.

        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )
        XCTAssertFalse(handled, "No callback wired → falls through to default backtab")
    }

    func test_enterStillRoutesToListContinuation_unaffected() {
        // Regression: the Shift-Tab branch must not break the existing
        // Enter routing through handleChecklistReturn / handleBulletReturn /
        // handleNumberedReturn. Sanity-check that an Enter on an empty
        // bullet line still strips the prefix.
        let stack = makeStack(body: "- ", selection: NSRange(location: 2, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled, "Enter on empty bullet must still be consumed by the list-continuation handler")
        XCTAssertEqual(stack.textView.string, "", "Empty bullet prefix stripped")
    }

    // MARK: - Numbered-list Enter continuation (handleNumberedReturn)

    func test_numberedReturn_continuesOnNonEmptyLine() {
        let stack = makeStack(body: "1. hello", selection: NSRange(location: 8, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(stack.textView.string, "1. hello\n2. ")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 12, length: 0))
    }

    func test_numberedReturn_advancesNumber() {
        let stack = makeStack(body: "3. item", selection: NSRange(location: 7, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(stack.textView.string, "3. item\n4. ")
    }

    func test_numberedReturn_emptyPrefix_stripsAndExits() {
        let stack = makeStack(body: "1. ", selection: NSRange(location: 3, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(stack.textView.string, "")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func test_numberedReturn_caretBeforePrefix_fallsThrough() {
        // Caret inside the prefix region should not trigger continuation.
        let stack = makeStack(body: "1. hello", selection: NSRange(location: 1, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertFalse(handled)
    }

    func test_numberedReturn_nonListLine_fallsThrough() {
        let stack = makeStack(body: "plain text", selection: NSRange(location: 5, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertFalse(handled)
    }

    func test_numberedReturn_withSelection_fallsThrough() {
        // Non-empty selection: default NSTextView delete-and-insert should fire.
        let stack = makeStack(body: "1. hello", selection: NSRange(location: 3, length: 3))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertFalse(handled)
    }

    // MARK: - Thematic-break Enter handler (handleThematicBreakReturn)

    func test_thematicBreakReturn_caretAtLineStart_movesCaretToLineAbove() {
        // "\n---\n\n" — empty separator at offset 0, `---` line at 1..4,
        // trailing empty line at 5. Caret at offset 1 (start of HR line,
        // visually at left edge of hairline — the bug repro position).
        let stack = makeStack(body: "\n---\n\n", selection: NSRange(location: 1, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled, "Enter on an HR line must be consumed (no fallthrough to default newline)")
        XCTAssertEqual(stack.textView.string, "\n---\n\n", "Text must not mutate — Enter on HR is a pure caret move")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 0, length: 0),
                       "Caret jumps to end of empty separator line above the HR")
    }

    func test_thematicBreakReturn_caretMidDashes_treatedAsRightEdge() {
        // Caret at offset 2 (between first and second dash) — drawInsertionPoint
        // shifts this visually to the right edge of the hairline. Right-edge
        // semantics: Enter is end-of-block → insert a blank line BELOW the HR.
        // (Pre-fix the handler escaped UP regardless of offset; that felt
        // wrong on the right edge and is what this test now pins against.)
        let stack = makeStack(body: "\n---\n\n", selection: NSRange(location: 2, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(stack.textView.string, "\n---\n\n\n",
                       "Right-edge Enter inserts `\\n` at lineEnd (one past the HR's trailing `\\n`)")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 5, length: 0),
                       "Caret parks on the new blank line below the HR")
    }

    func test_thematicBreakReturn_hrAtDocStart_opensBlankLineAbove() {
        // No separator line exists above the HR — defensive branch inserts
        // a clean `\n` at offset 0 and parks the caret on it.
        let stack = makeStack(body: "---\n\n", selection: NSRange(location: 0, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(stack.textView.string, "\n---\n\n", "One `\\n` opened above the HR")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 0, length: 0),
                       "Caret sits on the newly opened blank line")

        // The opened `\n` must NOT carry the thematic-break attribute — that
        // is exactly the failure mode the handler exists to prevent. After
        // processEditing runs, position 0 should be a plain `\n`.
        XCTAssertNil(
            stack.textView.textStorage?.attribute(.sidekickThematicBreak, at: 0, effectiveRange: nil),
            "Newly inserted `\\n` must not inherit thematic-break attribute"
        )
        // The original `---` (now at offsets 1..3) still carries the attribute.
        XCTAssertNotNil(
            stack.textView.textStorage?.attribute(.sidekickThematicBreak, at: 1, effectiveRange: nil),
            "Original HR survives and keeps its thematic-break attribute"
        )
    }

    func test_thematicBreakReturn_withSelection_fallsThrough() {
        // Non-empty selection on an HR line: default NSTextView delete-and-
        // insert behavior takes over (handler must return false).
        let stack = makeStack(body: "\n---\n\n", selection: NSRange(location: 1, length: 3))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertFalse(handled)
    }

    func test_thematicBreakReturn_nonHRLine_fallsThrough() {
        // Caret on a plain paragraph: handler must not fire.
        let stack = makeStack(body: "plain text\n", selection: NSRange(location: 3, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertFalse(handled)
    }

    // MARK: - F-06 — Sticky H1 typing-attrs after Enter

    /// Reproduce the F-06 sequence using the live four-piece TextKit stack.
    /// After the user presses Enter at end of an H1 line and types a char,
    /// the typed char must render at body font, not H1.
    func test_enterFromH1_thenTypeChar_charIsBodyFont() {
        let stack = makeStack(body: "# Heading", selection: NSRange(location: 9, length: 0))
        // Storage's processEditing has already run on the initial seed via
        // replaceCharacters → applyAttributes, so the heading line carries
        // h1ParagraphStyle on (0..10). When the caret is at the end of the
        // heading line, AppKit auto-reads attrs at offset 8 (last char) which
        // is H1 28pt, and pushes that into typingAttributes.
        stack.textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .paragraphStyle: MarkdownTextStorage.h1ParagraphStyle,
        ]

        // Simulate Enter via the same insertText path AppKit uses.
        stack.textView.insertText("\n", replacementRange: NSRange(location: 9, length: 0))
        XCTAssertEqual(stack.textView.string, "# Heading\n")

        // Selection has moved to offset 10 — fire our delegate hook.
        stack.coordinator.textViewDidChangeSelection(
            Notification(name: NSText.didChangeNotification, object: stack.textView)
        )

        // Now type 'a' — typingAttributes must be body 15pt by this point.
        stack.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(stack.textView.string, "# Heading\na")

        let aFont = stack.textView.textStorage?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        XCTAssertEqual(aFont?.pointSize, 15,
            "F-06: char typed on line 2 after Enter from H1 must render at body 15pt, not H1 28pt")
    }

    /// The character on line 2 also needs bodyParagraphStyle so its line box
    /// is body height and not 32pt (h1). Without this the caret on line 2
    /// remains tall even though the font is body — the paragraph style is
    /// the load-bearing attribute for caret height.
    func test_enterFromH1_thenTypeChar_charHasBodyParagraphStyle() {
        let stack = makeStack(body: "# Heading", selection: NSRange(location: 9, length: 0))
        stack.textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .paragraphStyle: MarkdownTextStorage.h1ParagraphStyle,
        ]
        stack.textView.insertText("\n", replacementRange: NSRange(location: 9, length: 0))
        stack.coordinator.textViewDidChangeSelection(
            Notification(name: NSText.didChangeNotification, object: stack.textView)
        )
        stack.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))

        let aStyle = stack.textView.textStorage?.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(aStyle?.maximumLineHeight, MarkdownTextStorage.bodyParagraphStyle.maximumLineHeight,
            "F-06: line 2 char must use bodyParagraphStyle line box, not h1ParagraphStyle (32pt)")
    }

    // MARK: - F-10 — Title→body Tab handoff

    func test_titleField_tab_invokesCallback() {
        // Build the TitleField coordinator directly, simulate the field
        // editor calling `control(_:textView:doCommandBy: insertTab:)`, and
        // verify the onTab callback fires + the keystroke is consumed.
        // Building the full NSViewRepresentable in a windowless test is
        // overkill; the coordinator is the only piece that owns the routing.
        var titleText = "hello"
        var tabFired = false
        let coordinator = TitleField.Coordinator(
            text: Binding(get: { titleText }, set: { titleText = $0 }),
            onTab: { tabFired = true },
            onSubmit: { }
        )
        let dummyControl = NSTextField()
        let dummyTextView = NSTextView()

        let handled = coordinator.control(
            dummyControl,
            textView: dummyTextView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )
        XCTAssertTrue(handled, "Tab must be consumed so NSTextField does not also do focus traversal")
        XCTAssertTrue(tabFired, "onTab callback must fire so EditorPaneView can move focus to the body editor")
    }

    func test_titleField_return_invokesSubmit() {
        // Counterpart: Return on the title field should also hand off to the
        // body, mirroring the prior `.onSubmit { focusBody() }` behavior.
        var titleText = "hello"
        var submitFired = false
        let coordinator = TitleField.Coordinator(
            text: Binding(get: { titleText }, set: { titleText = $0 }),
            onTab: { },
            onSubmit: { submitFired = true }
        )
        let handled = coordinator.control(
            NSTextField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertTrue(submitFired)
    }

    func test_titleField_otherCommand_fallsThrough() {
        // Sanity: the coordinator must NOT claim arbitrary field-editor
        // commands, otherwise we would break ⌘-C / arrow keys / etc.
        var titleText = "hello"
        let coordinator = TitleField.Coordinator(
            text: Binding(get: { titleText }, set: { titleText = $0 }),
            onTab: { XCTFail("onTab must not fire for unrelated commands") },
            onSubmit: { XCTFail("onSubmit must not fire for unrelated commands") }
        )
        let handled = coordinator.control(
            NSTextField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveLeft(_:))
        )
        XCTAssertFalse(handled, "Non-Tab/non-Return commands fall through to NSTextField default")
    }

    // MARK: - F-07 — Stale replacementRange from emoji picker

    /// Helper: build a HybridTextView with body + selection, no panel/window.
    private func makeHybridTextView(body: String, selection: NSRange) -> HybridTextView {
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let tv = HybridTextView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            textContainer: container
        )
        tv.isRichText = false
        if !body.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: body)
        }
        tv.setSelectedRange(selection)
        return tv
    }

    func test_insertText_staleReplacementRange_fallsBackToCurrentSelection() {
        // Reproduces F-07: emoji picker fires insertText with a replacementRange
        // captured at picker-invocation time. By the time the user picks an
        // emoji, the selection has moved (e.g. user typed " " after picker
        // opened). Honoring the stale range would replace different content
        // than the user expects. Our override falls back to current selection.
        let tv = makeHybridTextView(
            body: "party ",
            selection: NSRange(location: 6, length: 0)
        )
        // Stale range: picker captured the selection at offset 0 (different).
        let stale = NSRange(location: 0, length: 0)
        tv.insertText("🎉", replacementRange: stale)
        XCTAssertEqual(tv.string, "party 🎉",
            "Insert must land at current selection (offset 6), not the stale replacementRange (offset 0)")
    }

    func test_insertText_NSNotFoundReplacementRange_passesThrough() {
        // Sanity: when the picker / IME gives us NSNotFound (the documented
        // "use current selection" sentinel), we don't mangle it.
        let tv = makeHybridTextView(
            body: "hello",
            selection: NSRange(location: 5, length: 0)
        )
        tv.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "hello!")
    }

    func test_insertText_validReplacementRange_isHonored() {
        // Counter-test: when replacementRange MATCHES the current selection,
        // the standard insertText path runs unchanged. This is the normal
        // typing case (NSTextView default uses replacementRange == selection).
        let tv = makeHybridTextView(
            body: "hello",
            selection: NSRange(location: 0, length: 5)
        )
        // Range matches selection — standard replace-selection-with-text path.
        tv.insertText("world", replacementRange: NSRange(location: 0, length: 5))
        XCTAssertEqual(tv.string, "world")
    }

    func test_insertText_noEmojiOverwrite_simulatesF07Sequence() {
        // End-to-end F-07 simulation: insert emoji, then type 't' immediately
        // after. The emoji must remain; 't' must be appended after it.
        let tv = makeHybridTextView(
            body: "party ",
            selection: NSRange(location: 6, length: 0)
        )
        // Step 1: picker fires insertText for the emoji at the (correct,
        // matching) selection.
        tv.insertText("🎉", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(tv.string, "party 🎉")
        // After the insert, NSTextView updates selection to end of insert.
        // 🎉 is 2 UTF-16 units, so selection should now be at offset 8.
        XCTAssertEqual(tv.selectedRange().location, 8)

        // Step 2: simulate the picker's stale replacementRange firing AGAIN
        // on the next typed key (the actual F-07 mechanism per FB13789916).
        // Our override must ignore the stale 6,0 range and append at 8 instead.
        tv.insertText("t", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(tv.string, "party 🎉t",
            "F-07 regression: emoji must not be overwritten by stale replacementRange on the next keystroke")
    }

    // MARK: - EDIT-03 — checklist delete paths

    func test_checklistBackspace_emptyLine_stripsPrefix() {
        // Path A / D-05: empty checklist line, caret at end of the 6-char prefix.
        let stack = makeStack(body: "- [ ] ", selection: NSRange(location: 6, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(handled, "Backspace on empty checklist line must be consumed")
        XCTAssertEqual(stack.textView.string, "", "Whole 6-char prefix stripped — clean empty line")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func test_checklistBackspace_contentStart_demotesLine() {
        // Path B / D-06: caret at start of content — strip prefix, demote to plain line.
        let stack = makeStack(body: "- [ ] task", selection: NSRange(location: 6, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(handled, "Backspace at content start must be consumed")
        XCTAssertEqual(stack.textView.string, "task", "Prefix stripped, content preserved")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func test_checklistForwardDelete_fromLineStart_stripsPrefix() {
        // Path C: forward-delete from line start would remove the `-`; strip whole prefix.
        let stack = makeStack(body: "- [ ] ", selection: NSRange(location: 0, length: 0))
        let handled = stack.coordinator.textView(
            stack.textView, doCommandBy: #selector(NSResponder.deleteForward(_:)))
        XCTAssertTrue(handled, "Forward-delete from line start must be consumed")
        XCTAssertEqual(stack.textView.string, "", "Whole prefix stripped — clean empty line")
        XCTAssertEqual(stack.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func test_checklistBackspace_selection_overlapsPrefix_noRemnant() {
        // Path E: selection starts inside the prefix — union strip leaves no fragment.
        let stack = makeStack(body: "- [ ] task", selection: NSRange(location: 3, length: 5))
        let handled = stack.coordinator.textView(
            stack.textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(handled, "Selection overlapping the prefix must be consumed")
        XCTAssertFalse(stack.textView.string.contains("- ["),
                       "No broken `- [` prefix fragment may remain")
        XCTAssertFalse(stack.textView.string.contains("- [ ]"),
                       "No bare `- [ ]` remnant may remain")
        XCTAssertEqual(stack.textView.string, "sk",
                       "Union strip: lineStart..selectionEnd removed, leaving content tail")
    }

    func test_checklistBackspace_midContent_notIntercepted() {
        // Caret mid-word — handler must decline so default single-char delete runs.
        let stack = makeStack(body: "- [ ] task", selection: NSRange(location: 8, length: 0))
        let handled = FormattingToolbarView.handleChecklistBackspace(in: stack.textView)
        XCTAssertFalse(handled, "Mid-content Backspace must fall through to default delete")
    }

    // MARK: - F-07 — emoji stays visible after subsequent edits

    /// Helper that builds a layout-attached HybridTextView for glyph-property
    /// inspection. Distinct from `makeHybridTextView` because we need access
    /// to the layout manager and need to force layout.
    private func makeLayoutStack(initial: String) -> (HybridTextView, MarkdownLayoutManager, MarkdownTextStorage, NSTextContainer) {
        let storage = MarkdownTextStorage()
        let lm = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 1000))
        storage.addLayoutManager(lm)
        lm.addTextContainer(container)
        let tv = HybridTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: container)
        tv.isRichText = false
        if !initial.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: initial)
        }
        return (tv, lm, storage, container)
    }

    func test_emoji_glyphsRemainVisible_afterTypingNextChar() {
        // F-07 regression. Pre-fix, AppKit's re-layout path after a follow-up
        // keystroke skipped its font-cascade pass and marked the emoji's
        // surrogate halves null because the primary system font has no glyph
        // for them. The fix (MarkdownTextStorage.applyEmojiFont) pins
        // AppleColorEmoji on surrogate-pair ranges so AppKit never has to
        // cascade and the high-surrogate stays visible.
        let (tv, lm, _, container) = makeLayoutStack(initial: "hi ")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertText("🎉", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("t", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "hi 🎉t")
        lm.ensureLayout(for: container)
        // Glyph 3 is the emoji's high surrogate (chars 0..2 are 'h','i',' ').
        let highSurrogateProp = lm.propertyForGlyph(at: 3)
        XCTAssertFalse(highSurrogateProp.contains(.null),
            "F-07 regression: emoji high-surrogate glyph must remain visible after typing the next char")
    }

    func test_emoji_glyphsRemainVisible_onHeadingLine() {
        // Same regression, but on an H1 line — the heading font is 28pt
        // semibold, also lacks emoji glyphs. The fix preserves the ambient
        // point size so the emoji stays sized to the heading.
        let (tv, lm, storage, container) = makeLayoutStack(initial: "# Title")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertText("🎉", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("t", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "# Title🎉t")
        lm.ensureLayout(for: container)
        // Emoji's high surrogate is at glyph index 7 (chars '#',' ' hidden,
        // then 'T','i','t','l','e','🎉hi','🎉lo','t').
        let highSurrogateProp = lm.propertyForGlyph(at: 7)
        XCTAssertFalse(highSurrogateProp.contains(.null),
            "F-07 regression: emoji on heading line must remain visible after typing the next char")
        // Sanity: the pinned font on the emoji range matches the heading
        // point size (28pt), not the body 15pt.
        let emojiFont = storage.attributes(at: 7, effectiveRange: nil)[.font] as? NSFont
        XCTAssertEqual(emojiFont?.pointSize, 28,
            "Pinned emoji font must inherit the heading's point size")
    }
}
