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
