/// UserDefaults key constants for Phase 5 settings.
///
/// Pattern sources:
///   - RESEARCH.md §Code Examples "UserDefaults Keys (new in Phase 5)"
///   - CONTEXT.md: SET-03, P-04, WS-01
enum Defaults {
    static let panelWidth = "panelWidth"
    static let notesFolder = "notesFolder"
    static let filenameFollowsTitle = "filenameFollowsTitle"
    static let lastSelectedNoteID = "lastSelectedNoteID"
    // launchAtLogin is NOT stored in UserDefaults — read from SMAppService.mainApp.status (RESEARCH Pitfall 1)
    // hotkey stored automatically by KeyboardShortcuts library
}
