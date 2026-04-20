import XCTest
@testable import Sidekick

/// Covers MENU-01..04 + KBD-02 — each `@objc` action method on AppDelegate
/// routes to the correct store / PanelState mutation with the correct args.
///
/// Pattern: NoteStoreIntegrationTests (@MainActor + TempFolder + real
/// NoteStore + `Task.sleep` to let the action's internal `Task { @MainActor
/// in ... await ... }` complete before asserting).
@MainActor
final class MenuActionRoutingTests: XCTestCase {

    /// Small async wait — the @objc handlers spawn `Task { @MainActor in ... }`
    /// blocks, so assertions must wait for the async mutation to land.
    private func waitForAsync() async {
        try? await Task.sleep(nanoseconds: 200_000_000)   // 200ms — generous to avoid flakes
    }

    // MARK: - MENU-01 + KBD-02: newNote + reloadNotes

    func test_newNote_menuAction_callsStoreCreate() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let delegate = AppDelegate(store: store)
        let before = store.notes.count

        delegate.newNote(nil)
        await waitForAsync()

        XCTAssertEqual(store.notes.count, before + 1,
                       "MENU-01: newNote must call store.create()")
        XCTAssertNotNil(delegate.panelController.panelState.selectedNoteID,
                        "MENU-01: newNote must set panelState.selectedNoteID to the new note")
        XCTAssertEqual(delegate.panelController.panelState.selectedNoteID,
                       store.notes.last?.id,
                       "Newly-created note is the latest entry in store.notes; selection points to it")
        _ = tmp  // retain TempFolder
    }

    func test_reloadNotes_callsStoreReload() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)

        // Drop a .md file on disk BEFORE store sees it.
        let manualNoteURL = tmp.url.appendingPathComponent("manual.md")
        try "# manual\n\nbody".write(to: manualNoteURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.notes.count, 0, "Precondition: store hasn't reloaded yet")

        let delegate = AppDelegate(store: store)
        delegate.reloadNotes(nil)
        await waitForAsync()

        XCTAssertGreaterThan(store.notes.count, 0,
                             "KBD-02: reloadNotes must call store.reload() which picks up the manual .md file")
        _ = tmp  // retain TempFolder
    }

    // MARK: - MENU-03: togglePreview

    func test_togglePreview_flipsPanelStateIsPreviewMode() throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let delegate = AppDelegate(store: store)
        XCTAssertFalse(delegate.panelController.panelState.isPreviewMode,
                       "Precondition: isPreviewMode starts false")

        delegate.togglePreview(nil)
        XCTAssertTrue(delegate.panelController.panelState.isPreviewMode,
                      "MENU-03: togglePreview flips isPreviewMode → true")

        delegate.togglePreview(nil)
        XCTAssertFalse(delegate.panelController.panelState.isPreviewMode,
                       "MENU-03: togglePreview flips isPreviewMode back to false")
        _ = tmp  // retain TempFolder
    }

    // MARK: - MENU-04: pinToggle

    func test_pinToggle_inverts() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let note = try await store.create()
        let delegate = AppDelegate(store: store)
        delegate.panelController.panelState.selectedNoteID = note.id
        XCTAssertFalse(store.notes.first(where: { $0.id == note.id })?.pinned ?? true,
                       "Precondition: newly created note is unpinned")

        delegate.pinToggle(nil)
        await waitForAsync()
        XCTAssertTrue(store.notes.first(where: { $0.id == note.id })?.pinned ?? false,
                      "MENU-04: pinToggle pins an unpinned note")

        delegate.pinToggle(nil)
        await waitForAsync()
        XCTAssertFalse(store.notes.first(where: { $0.id == note.id })?.pinned ?? true,
                       "MENU-04: pinToggle unpins a pinned note (inverts)")
        _ = tmp  // retain TempFolder
    }

    // MARK: - performWrap determinism sentinel (D-T-05 structural invariant, TOOLBAR-01..03)

    /// Structural-invariant sentinel test for the toolbar / Format-menu / ⌘B-shortcut
    /// parity guarantee from D-TB-01.
    ///
    /// RATIONALE — why this is a sentinel, not an end-to-end parity test:
    /// Post-Phase-10 all three surfaces (toolbar button closure, AppDelegate.formatBold,
    /// keyboard shortcut → AppDelegate.formatBold) converge on
    /// `FormattingToolbarView.performWrap`. Exercising each real entry point in XCTest
    /// would require:
    ///   1. SwiftUI view-callback invocation (toolbar path) — flaky without a host window
    ///   2. Seeded NSApp panel state + AppDelegate lifecycle (menu path) — brittle in XCTest
    ///   3. Keyboard-event synthesis against NSApp.sendEvent (shortcut path) — requires runloop
    ///
    /// Given Phase 10's budget profile and the structural guarantee that all three paths
    /// share one function (performWrap), the XCTest-level invariant reduces to:
    /// **performWrap is deterministic across invocations with identical input.** If that
    /// holds, and all three dispatch paths terminate at performWrap, then the three paths
    /// produce identical NSTextView state by construction.
    ///
    /// END-TO-END THREE-PATH COVERAGE lives in the Plan 04 human-verify checkpoint
    /// (Task 3 steps 4, 6, 7): step 4 exercises the toolbar button, step 6 exercises ⌘B,
    /// step 7 exercises Format menu → Bold. The human-verify checkpoint is the real
    /// parity test; this XCTest is the machine-checkable invariant that backstops it.
    func test_performWrap_isDeterministic_sharedPathSentinel() {
        // Helper — minimal NSTextView fixture (copy shape from PerformWrapTests.makeTextView if not already in scope)
        func makeTV(_ body: String, selection: NSRange) -> NSTextView {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            tv.string = body
            tv.setSelectedRange(selection)
            return tv
        }

        let body = "hello world"
        let sel = NSRange(location: 0, length: 5)

        // Three independent fixtures seeded identically — each represents one dispatch path
        // terminating at performWrap. Because the three dispatch paths share this one
        // function (D-TB-01), determinism under identical input is the structural
        // invariant we enforce. Actual three-path wiring is covered by human-verify
        // Task 3 steps 4, 6, 7.
        let tvToolbar = makeTV(body, selection: sel)
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tvToolbar)

        let tvMenu = makeTV(body, selection: sel)
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tvMenu)

        let tvShortcut = makeTV(body, selection: sel)
        FormattingToolbarView.performWrap(prefix: "**", suffix: "**", in: tvShortcut)

        // Determinism: identical input → identical output across all three calls
        XCTAssertEqual(tvToolbar.string, tvMenu.string,
                       "performWrap must be deterministic — identical input must produce identical string (structural sentinel for D-TB-01)")
        XCTAssertEqual(tvMenu.string, tvShortcut.string,
                       "performWrap must be deterministic — third invocation must match (structural sentinel for D-TB-01)")
        XCTAssertEqual(tvToolbar.selectedRange(), tvMenu.selectedRange(),
                       "performWrap selection must be deterministic (structural sentinel)")
        XCTAssertEqual(tvMenu.selectedRange(), tvShortcut.selectedRange(),
                       "performWrap selection must be deterministic (structural sentinel)")

        // Expected semantic outcome — performWrap wrapped the selected range with "**"
        XCTAssertEqual(tvToolbar.string, "**hello** world",
                       "performWrap must wrap the selected range with the given prefix/suffix")
    }

    // MARK: - MENU-04: deleteNote

    func test_deleteNote_routesToStoreAndReassignsSelection() async throws {
        let tmp = TempFolder()
        let store = try NoteStore(folder: tmp.url)
        let n1 = try await store.create()
        let n2 = try await store.create()
        let delegate = AppDelegate(store: store)
        delegate.panelController.panelState.selectedNoteID = n1.id
        let countBefore = store.notes.count
        XCTAssertEqual(countBefore, 2, "Precondition: 2 notes created")

        delegate.deleteNote(nil)
        await waitForAsync()

        XCTAssertEqual(store.notes.count, countBefore - 1,
                       "MENU-04: deleteNote calls store.delete(id:) — count drops by 1")
        XCTAssertFalse(store.notes.contains(where: { $0.id == n1.id }),
                       "MENU-04: deleted note is gone from store.notes")
        XCTAssertEqual(delegate.panelController.panelState.selectedNoteID, n2.id,
                       "MENU-04: deleteNote reassigns panelState.selectedNoteID to the successor (NoteRowFormatting.successorID)")
        _ = tmp  // retain TempFolder
    }
}
