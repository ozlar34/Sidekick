/// UserDefaults key constants for Phase 5 / v1.3 settings.
///
/// Pattern sources:
///   - RESEARCH.md §Code Examples "UserDefaults Keys (new in Phase 5)"
///   - CONTEXT.md: SET-03, P-04, WS-01
enum Defaults {
    static let panelWidth = "panelWidth"
    static let notesFolder = "notesFolder"
    static let lastSelectedNoteID = "lastSelectedNoteID"
    static let sidebarWidth = "sidebarWidth"
    static let showInDock = "showInDock"
    // launchAtLogin is NOT stored in UserDefaults — read from SMAppService.mainApp.status (RESEARCH Pitfall 1)
    // hotkey stored automatically by KeyboardShortcuts library
}
