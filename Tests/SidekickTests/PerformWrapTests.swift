import XCTest
import AppKit
@testable import Sidekick

/// NSTextView subclass used only in tests to supply an explicit UndoManager.
/// Windowless NSTextViews have no responder chain, so `undoManager` is nil
/// by default. Overriding the property injects a local UndoManager so the
/// edit-sandwich undo assertions are reliable without a real window.
private final class TestableTextView: NSTextView {
    private let _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }
}

/// Covers MENU-02 — the shared NSTextView edit-sandwich path that both
/// `EditorPaneView.wrapSelection` (toolbar buttons) and `AppDelegate.format*`
/// menu actions (Plan 04) call into.
///
/// Pattern: FormattingToolbarTests (static-method assertion style) +
/// `@MainActor` because NSTextView is main-actor-bound.
@MainActor
final class PerformWrapTests: XCTestCase {

    /// Build a fresh NSTextView with the given body and selection.
    /// Uses `TestableTextView` so that `undoManager` is non-nil even without
    /// a window. `allowsUndo = true` is required so the edit sandwich
    /// registers on it.
    private func makeTextView(_ body: String, selection: NSRange) -> NSTextView {
        let tv = TestableTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.string = body
        tv.setSelectedRange(selection)
        return tv
    }

    func test_performWrap_boldNonEmptySelection_mutatesTextViewString() {
        let tv = makeTextView("hello world", selection: NSRange(location: 0, length: 5))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "**hello** world",
                       "Non-empty selection must wrap with prefix + selection + suffix")
        // Inner text ("hello") stays selected so the user can hit ⌘B again to
        // toggle off — re-wrap → un-wrap → re-wrap cycles without re-selecting.
        XCTAssertEqual(tv.selectedRange().location, 2,
                       "Selection moves to start of inner content after wrap")
        XCTAssertEqual(tv.selectedRange().length, 5,
                       "Inner selection length = original selection length")
    }

    func test_performWrap_toggleCycle_wrapUnwrapRewrap() {
        // Regression guard: ⌘B three times on the same word must end back at
        // **hello**. Each step leaves the inner text selected so no manual
        // re-select between presses is needed.
        let tv = makeTextView("hello", selection: NSRange(location: 0, length: 5))

        // 1) wrap → "**hello**", selection on "hello"
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "**hello**")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 5))

        // 2) unwrap → "hello", selection still on "hello"
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "hello")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 5))

        // 3) wrap again → back to "**hello**"
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "**hello**",
                       "Third ⌘B must re-bold — selection persisted between presses")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 5))
    }

    func test_performWrap_boldCycle_realEditorStack() {
        // Same cycle as test_performWrap_toggleCycle_wrapUnwrapRewrap but using
        // the same storage+layout-manager+container stack HybridEditorView.swift
        // assembles at runtime. Guards against a failure mode the simple
        // NSTextView test can't catch: a MarkdownTextStorage processEditing
        // side effect (attribute reapply, layout invalidation) resetting the
        // selection set by performWrap.
        let storage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 100))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        final class TestableEditor: NSTextView {
            private let _undo = UndoManager()
            override var undoManager: UndoManager? { _undo }
        }
        let tv = TestableEditor(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            textContainer: container
        )
        tv.isRichText = false
        tv.allowsUndo = true

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")
        tv.setSelectedRange(NSRange(location: 0, length: 5))

        // 1) wrap
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "**hello**", "Step 1: wrap")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 5),
                       "Step 1: inner text re-selected through MarkdownTextStorage stack")

        // 2) unwrap
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "hello", "Step 2: unwrap")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 5),
                       "Step 2: inner text stays selected after toggle-off")

        // 3) re-wrap
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "**hello**", "Step 3: re-wrap — third press must re-bold")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 5))
    }

    func test_performWrap_linkWrap_cursorLandsInsideParens_notInnerSelection() {
        // Link case is special — cursor must land inside `()` for URL entry.
        let tv = makeTextView("hello", selection: NSRange(location: 0, length: 5))
        FormattingToolbarView.performWrap(prefix: "[", suffix: "]()", in: tv)
        XCTAssertEqual(tv.string, "[hello]()")
        XCTAssertEqual(tv.selectedRange().location, 8,
                       "Cursor inside `()` = location + 1 + selected.length + 2 (D-UX-01)")
        XCTAssertEqual(tv.selectedRange().length, 0,
                       "Link wrap collapses to caret, not a selection")
    }

    func test_performWrap_registersUndo() {
        let tv = makeTextView("abc", selection: NSRange(location: 0, length: 3))
        FormattingToolbarView.performWrap(prefix: "*", suffix: "*", in: tv)
        XCTAssertEqual(tv.string, "*abc*", "Italic wrap applied")
        XCTAssertTrue(tv.undoManager?.canUndo ?? false,
                      "NSTextView edit sandwich must register on undoManager automatically")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "abc",
                       "Undo must restore original body via the registered edit")
    }

    func test_performWrap_emptySelection_insertsMarkers() {
        let tv = makeTextView("abc", selection: NSRange(location: 3, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "abc****",
                       "Empty selection must insert prefix + suffix at caret")
        XCTAssertEqual(tv.selectedRange().location, 5,
                       "Cursor must land between the two '**' markers (location 3 + 2-char prefix = 5)")
    }

    // MARK: - Toggle-off at NSTextView level (D-T-03)

    func test_performWrap_boldToggleOff_selectionSpanPreserved() {
        // ⌘B on pre-wrapped "**foo**" with "foo" selected → strips markers; selection stays on "foo"
        let tv = makeTextView("**foo**", selection: NSRange(location: 2, length: 3))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "foo", "Toggle-off strips the outer **")
        XCTAssertEqual(tv.selectedRange().location, 0, "Cursor at start of formerly-stripped span")
        XCTAssertEqual(tv.selectedRange().length, 3, "Selection length == original selected length (D-TG-02 re-select)")
    }

    func test_performWrap_italicToggleOff_underscoreWrap_cmdI() {
        // ⌘I on _foo_ with "foo" selected → strips underscores (D-TG-04); selection stays on "foo"
        let tv = makeTextView("_foo_", selection: NSRange(location: 1, length: 3))
        FormattingToolbarView.performWrap(prefix: "*", suffix: "*", in: tv)
        XCTAssertEqual(tv.string, "foo", "⌘I on _foo_ strips underscores (D-TG-04)")
        XCTAssertEqual(tv.selectedRange().length, 3, "Selection length preserved")
        XCTAssertEqual(tv.selectedRange().location, 0)
    }

    func test_performWrap_selectionWrapsMarkers_reselectsInner() {
        // Selection covers full "**foo**" (e.g. triple-click). ⌘B strips markers
        // and re-selects the inner "foo" so the user can hit ⌘B again to re-bold.
        let tv = makeTextView("**foo**", selection: NSRange(location: 0, length: 7))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange().location, 0)
        XCTAssertEqual(tv.selectedRange().length, 3, "Inner text re-selected (original len − 2×marker len)")
    }

    func test_performWrap_caretOnly_insideBoldPair_strips() {
        // ⌘B with caret inside the bold pair (no selection) → strip markers.
        let tv = makeTextView("**foo**", selection: NSRange(location: 4, length: 0))
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tv)
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange().location, 2, "Caret tracks the character it was against")
        XCTAssertEqual(tv.selectedRange().length, 0)
    }

    func test_performWrap_caretOnly_menuPathEquivalence() {
        // Menu path (AppDelegate.formatBold) converges on the same performWrap
        // call, so this test also covers "Format > Bold" toggling off.
        let tv = makeTextView("*foo*", selection: NSRange(location: 2, length: 0))
        FormattingToolbarView.performWrap(prefix: "*", suffix: "*", in: tv)
        XCTAssertEqual(tv.string, "foo")
        XCTAssertEqual(tv.selectedRange().location, 1)
    }
}
