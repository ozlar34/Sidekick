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
