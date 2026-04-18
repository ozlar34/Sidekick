import AppKit
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var panelState: PanelState
    let note: Note
    @Binding var selectedID: UUID?

    @State private var localBody: String = ""
    @State private var debouncer = Debouncer(interval: 0.5)
    @FocusState private var editorFocused: Bool
    @Environment(\.setDocumentEdited) private var setDocumentEdited

    // Phase 4 — markdown preview toggle (EDIT-02, D-04)
    // @State isPreviewMode migrated to panelState.isPreviewMode (Phase 8 D-R-02)
    @State private var cursorOffset: Int = 0

    // Phase 7 — formatting toolbar: cache TV ref + range so button clicks
    // (which steal first responder before the action fires) still work.
    @State private var cachedTextView: NSTextView? = nil
    @State private var cachedSelection: NSRange = NSRange(location: 0, length: 0)

    // Phase 5 plan 03 — external-edit banner + disk-write toast (STORE-07, REL-01)
    // Banner state is derived from store.externallyChangedIDs (WR-06): a single
    // long-lived @Published Set on NoteStore means we don't miss events across
    // note switches or while the editor is unmounted (empty state).
    @State private var diskWriteError: Bool = false

    private var showExternalChangeBanner: Bool {
        store.externallyChangedIDs.contains(note.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // External-edit banner (STORE-07) — top of editor
            if showExternalChangeBanner {
                HStack {
                    Text("⚠ File changed on disk").font(.body)
                    Spacer()
                    Button("Reload") {
                        Task { await reloadFromDisk() }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.15))
            }

            // Editor / preview content
            ZStack(alignment: .topLeading) {
                if panelState.isPreviewMode {
                    MarkdownPreviewView(content: localBody)
                } else {
                    TextEditor(text: $localBody)
                        .focused($editorFocused)
                        .font(.body)
                        .padding(.top, 24)   // P7-PAD-01: breathing room at note top
                        .onChange(of: localBody) { _, newValue in
                            scheduleAutoSave(body: newValue)
                        }

                    if localBody.isEmpty {
                        Text("Start writing...")
                            .foregroundStyle(.secondary)
                            .font(.body)
                            .padding(.leading, 13)   // TextEditor internal inset (~5pt) + 8pt outer pad
                            .padding(.top, 40)        // TextEditor internal inset (~8pt) + 32pt outer pad (24 TE pad + 8 placeholder breathing)
                            .allowsHitTesting(false)
                    }
                }

            }
            .background(Color(.textBackgroundColor))
            .onReceive(NotificationCenter.default.publisher(
                for: NSTextView.didChangeSelectionNotification
            )) { note in
                // Cache TV ref + selection before any button click can steal
                // first responder. The notification fires on the TV's own thread
                // but @State writes are safe from any thread in SwiftUI.
                guard let tv = note.object as? NSTextView else { return }
                cachedTextView = tv
                cachedSelection = tv.selectedRange()
            }

            // Formatting toolbar (P7-TOOL-01, P7-TOOL-02) — edit mode only.
            // Hidden in preview mode because NSTextView is not in the
            // responder chain (RESEARCH Pitfall 2).
            if !panelState.isPreviewMode {
                FormattingToolbarView(wrapSelection: wrapSelection)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.controlBackgroundColor))
            }

            // Disk-write failure toast (REL-01) — bottom of editor
            if diskWriteError {
                HStack {
                    Text("Could not save — check disk permissions.").font(.body)
                    Spacer()
                    Button("Retry") {
                        diskWriteError = false
                        scheduleAutoSave(body: localBody)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color(.controlBackgroundColor))
                .shadow(radius: 4)
            }
        }
        .onAppear {
            localBody = note.body
            focusEditorAfterDelay()
        }
        .onChange(of: note.id) { _, _ in
            localBody = note.body
            cursorOffset = 0          // reset stale offset on note switch
            panelState.isPreviewMode = false     // return to edit mode on note switch
            diskWriteError = false
            focusEditorAfterDelay()
        }
        .onChange(of: panelState.isPreviewMode) { _, newValue in
            // D-K-02: run the cursor capture/restore dance around preview
            // toggles triggered by AppDelegate.togglePreview (menu path) OR
            // the deleted togglePreviewMode() function (removed in Plan 04).
            if newValue {
                captureCursorOffset()
            } else {
                restoreCursorOffset()
            }
        }
    }

    // MARK: - Auto-save (STORE-05, EDIT-04, EDIT-05)

    private func scheduleAutoSave(body: String) {
        // Immediate unsaved indicator (EDIT-05)
        setDocumentEdited(true)

        let id = note.id
        let editedSetter = setDocumentEdited
        let storeRef = store
        Task {
            await debouncer.schedule {
                do {
                    try await storeRef.update(id, body: body)
                    await MainActor.run { editedSetter(false) }
                } catch {
                    NSLog("[Sidekick] autosave failed: \(error.localizedDescription)")
                    await MainActor.run {
                        diskWriteError = true
                        editedSetter(false)
                    }
                    // IN-03: Fire-and-forget auto-dismiss outside the
                    // debouncer's cancellable chain. If the user types again
                    // or hits Retry within 5s, the debouncer cancels the
                    // active schedule — we do NOT want that cancellation to
                    // throw out of Task.sleep and clear the flag prematurely.
                    // A detached @MainActor task is immune to debouncer reset.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        diskWriteError = false
                    }
                }
            }
        }
    }

    // MARK: - Auto-focus (RESEARCH Pitfall 2: 50ms delay required)

    private func focusEditorAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            editorFocused = true
        }
    }

    // MARK: - External changes (Phase 5: banner trigger instead of silent reload)

    private func reloadFromDisk() async {
        await store.reloadNote(id: note.id)
        if let updated = store.notes.first(where: { $0.id == note.id }) {
            localBody = updated.body
        }
        store.acknowledgeExternalChange(id: note.id)
    }

    // MARK: - Phase 4 markdown preview toggle (EDIT-02, D-04)

    /// Clamp a UTF-16 cursor offset to the bounds of `body`. D-04 fallback:
    /// when cursorOffset is out of range (e.g. note body shrank externally),
    /// return `body.utf16.count` (end of document). NSRange.location is in
    /// UTF-16 code units, so we MUST use `utf16.count` not `count`
    /// (RESEARCH Pitfall 2 + Open Question 2).
    internal static func clampOffset(_ offset: Int, in body: String) -> Int {
        let upper = body.utf16.count
        if offset < 0 { return 0 }
        if offset > upper { return upper }
        return offset
    }

    private func captureCursorOffset() {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        cursorOffset = tv.selectedRange().location
    }

    // MARK: - Phase 7 formatting toolbar (P7-TOOL-01, P7-TOOL-02)

    /// Walk the key window's view hierarchy to find the TextEditor's NSTextView.
    /// This works even after a toolbar button has stolen first responder, because
    /// NSTextView keeps its selection range when it's no longer first responder
    /// (the selection just renders greyed out).
    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view = view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for subview in view.subviews {
            if let tv = findTextView(in: subview) { return tv }
        }
        return nil
    }

    /// Bridge from FormattingToolbarView button taps to the editor's NSTextView.
    ///
    /// Delegates to the shared static helper `FormattingToolbarView.performWrap`
    /// (D-R-03) so that the toolbar-button path and the menu-action path (Plan 04
    /// AppDelegate handlers) use the same NSTextView edit-sandwich code.
    ///
    /// Undo is registered automatically on `textView.undoManager` via the
    /// sandwich — no manual `UndoManager.registerUndo` needed (RESEARCH Pitfall 2).
    private func wrapSelection(prefix: String, suffix: String) {
        guard !panelState.isPreviewMode else { return }
        // Toolbar-button path: SwiftUI Button fires this synchronously inside
        // SwiftUI's state-update cycle. Calling NSTextView.replaceCharacters
        // from here is silently reverted by SwiftUI because the TextEditor is
        // bound to $localBody — SwiftUI re-pushes localBody into the NSTextView
        // after we mutate it. The menu-bar path works because it fires from an
        // AppKit target/action *outside* SwiftUI's update cycle.
        //
        // Fix: update localBody (SwiftUI's source of truth) directly. SwiftUI
        // propagates the change into the NSTextView. Restore the cursor on the
        // next run loop, once SwiftUI has re-rendered.
        let tv = cachedTextView
            ?? findTextView(in: NSApp.keyWindow?.contentView)
            ?? NSApp.windows.lazy.compactMap { findTextView(in: $0.contentView) }.first
        let range = tv?.selectedRange() ?? cachedSelection
        let (newBody, cursor) = FormattingToolbarView.applyMarkdownWrap(
            prefix: prefix,
            suffix: suffix,
            body: localBody,
            range: range
        )
        localBody = newBody
        DispatchQueue.main.async {
            let target = tv ?? (NSApp.keyWindow?.firstResponder as? NSTextView)
            target?.setSelectedRange(NSRange(location: cursor, length: 0))
        }
    }

    private func restoreCursorOffset() {
        // 50ms delay — matches focusEditorAfterDelay; gives SwiftUI time to re-mount
        // the TextEditor and AppKit responder chain to settle (RESEARCH Pitfall 3).
        Task { @MainActor in
            editorFocused = true
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let safeOffset = EditorPaneView.clampOffset(cursorOffset, in: localBody)
            tv.setSelectedRange(NSRange(location: safeOffset, length: 0))
        }
    }

}
