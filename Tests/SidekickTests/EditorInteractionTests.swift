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
}
