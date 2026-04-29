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

    /// Set when the caret sits inside a bold / italic / code inline span.
    /// Driven by HybridEditorView's Coordinator on selection and text
    /// changes; consumed by FormattingToolbarView for its active-state
    /// highlight. Coordinator only writes when the value actually differs,
    /// so unrelated keystrokes do not fire SwiftUI re-renders.
    @Published var activeInlineKind: FormattingToolbarView.InlineKind?
}
