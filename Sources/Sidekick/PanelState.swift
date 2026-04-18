import Foundation
import Combine

/// Shared panel-scoped state. Held by `PanelController` and injected into
/// `SidebarView` / `EditorPaneView` via `@ObservedObject`. AppDelegate menu
/// actions (Plan 04) read and mutate these properties directly; SwiftUI
/// views observe through `@Published`.
///
/// Pattern: matches `NoteStore` shape (`@MainActor final class`, `@Published`
/// var; see Sources/Sidekick/Store/NoteStore.swift:13-20). Unlike NoteStore
/// which gates writes through methods (`create`, `update`, etc.) and keeps
/// `@Published private(set)`, PanelState exposes writable `@Published var`
/// because AppDelegate must mutate these properties from `@objc` handlers
/// (see CONTEXT D-R-02 + D-R-01).
///
/// Single source of truth replaces two prior local `@State` properties:
///   - `SidebarView.@State selectedID`   → `panelState.selectedNoteID`
///   - `EditorPaneView.@State isPreviewMode` → `panelState.isPreviewMode`
@MainActor
final class PanelState: ObservableObject {
    @Published var selectedNoteID: UUID? = nil
    @Published var isPreviewMode: Bool = true
}
