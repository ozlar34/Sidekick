import AppKit
import Combine
import SwiftUI

/// Bridges the SwiftUI `EditorPaneView` to the AppKit `NSTextView` that
/// lives inside `HybridEditorView`. Publishes the NSTextView reference
/// upward so toolbar-button handlers can call
/// `FormattingToolbarView.performWrap(in:)` on the live text view.
///
/// Lifecycle: `@StateObject`-owned by `EditorPaneView`; view-lifetime scope
/// (10-CONTEXT.md D-TB-04). A fresh instance is created each time the pane
/// mounts; the view-lifetime NSTextView reference is re-published on mount.
///
/// Pattern: matches `PanelState` shape (`@MainActor final class`,
/// `ObservableObject`; see Sources/Sidekick/PanelState.swift).
///
/// Note: Swift does not allow `@Published weak var` — `@Published` property
/// wrapper and `weak` are mutually exclusive. Instead, the `textView` setter
/// fires `objectWillChange` manually, achieving the same observable behaviour
/// without retaining the NSTextView (D-TB-02, D-TB-03, D-TB-04).
///
/// Reference: 10-CONTEXT.md D-TB-02, D-TB-03, D-TB-04.
@MainActor
final class HybridEditorController: ObservableObject {
    /// The NSTextView hosted inside HybridEditorView. Written once in
    /// `makeNSView`; read from EditorPaneView's toolbar callbacks.
    /// `weak` because the NSTextView lifecycle is owned by the
    /// NSScrollView returned from `makeNSView`; the controller must
    /// not retain it.
    weak var textView: NSTextView? {
        willSet { objectWillChange.send() }
    }

    /// Incremented by EditorPaneView at each GENUINE external-push site
    /// (note switch, reload-from-disk). HybridEditorView.updateNSView
    /// compares this against the value the Coordinator last consumed: a
    /// difference means a real external push (apply the bare-storage
    /// replace); equal means any binding change reaching updateNSView is a
    /// reflexive echo of user typing (skip it — a bare replace would
    /// corrupt the NSTextView undo stack, EDIT-02).
    ///
    /// This replaces the WR-01 single-shot string sentinel: classifying
    /// by an explicit push-site flag means a genuine push whose new body
    /// happens to equal a previously-typed string can never be mistaken
    /// for an echo (the WR-01 false-negative), and — critically — a
    /// reflexive echo can never be mistaken for a genuine push (the
    /// EDIT-02 regression this plan closes).
    @Published var externalPushToken: Int = 0

    /// Set when the caret sits inside a bold / italic / code inline span.
    /// Driven by HybridEditorView's Coordinator on selection and text
    /// changes; consumed by FormattingToolbarView for its active-state
    /// highlight. Coordinator only writes when the value actually differs,
    /// so unrelated keystrokes do not fire SwiftUI re-renders.
    @Published var activeInlineKind: FormattingToolbarView.InlineKind?

    /// Heading level (1…3) of the line containing the caret, or nil when
    /// the line has no `^#{1,6} ` prefix. Display-capped at 3 — H4–H6
    /// lines (rare) report as 3 because the toolbar dropdown only offers
    /// Heading 1–3. The underlying `####…` text is preserved on save.
    /// Same coalesced-write discipline as `activeInlineKind` to avoid
    /// re-rendering on identical updates.
    @Published var activeHeadingLevel: Int?

    /// Line-prefix block format (bullet / numbered / checklist /
    /// blockquote) of the line containing the caret, or nil when the
    /// line has no recognized line prefix. Drives the popover's active-
    /// state highlight on its four list-shape rows so the user can see
    /// when the current line is already in a given format. Coalesced
    /// writes for the same reason as the other publishers.
    @Published var activeLinePrefix: FormattingToolbarView.LinePrefix?

    /// Set of inline kinds currently armed on an empty selection (Cmd+B /
    /// Cmd+I / Cmd+U / Cmd+⇧X / Cmd+⌥C with no selected text). Drives the
    /// OR-ed `isActive` highlight on the toolbar's inline buttons —
    /// active = either "caret is inside an existing pair" (activeInlineKind)
    /// or "armed for next-typed character" (armedInlineKinds.contains(...)).
    ///
    /// Written by HybridTextView via the weak back-pointer; coalesced
    /// (the text view only republishes when the value changes) for the
    /// same SwiftUI re-render reason as the other publishers.
    @Published var armedInlineKinds: Set<FormattingToolbarView.InlineKind> = []

    /// Fired when the user presses Shift-Tab with the caret at body
    /// offset 0 — counterpart to title→body Tab. EditorPaneView wires
    /// this to flip SwiftUI focus back to the title field. nil means
    /// the body editor swallows Shift-Tab (default NSTextView behavior:
    /// insert backtab character or no-op).
    var onShiftTabAtBodyStart: (() -> Void)?
}
