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
        XCTAssertEqual(tv.selectedRange().location, 9,
                       "Cursor lands after inserted '**hello**' (location 9)")
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
}
