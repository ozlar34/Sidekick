import SwiftUI

/// Closure invoked to set `NSPanel.isDocumentEdited` on the SidekickPanel.
/// Plan 03 wires the real implementation in PanelController.makePanel via
/// `.environment(\.setDocumentEdited) { [weak panel] edited in panel?.isDocumentEdited = edited }`.
/// Default is a no-op so previews and tests work without a panel.
struct DocumentEditedKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var setDocumentEdited: (Bool) -> Void {
        get { self[DocumentEditedKey.self] }
        set { self[DocumentEditedKey.self] = newValue }
    }
}
