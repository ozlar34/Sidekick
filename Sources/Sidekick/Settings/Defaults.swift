/// UserDefaults key constants for Phase 5 / v1.3 settings.
///
/// Pattern sources:
///   - RESEARCH.md §Code Examples "UserDefaults Keys (new in Phase 5)"
///   - CONTEXT.md: SET-03, P-04, WS-01
import Foundation

/// The panel's sizes in points: the defaults of a first launch and the limits of the two drag handles. One home, so the
/// panel, the sidebar and the settings form cannot disagree.
enum PanelSizes {
    static let defaultPanelWidth: CGFloat = 480
    static let minPanelWidth: CGFloat = 320
    static let maxPanelWidth: CGFloat = 560
    static let defaultSidebarWidth: CGFloat = 180
    static let minSidebarWidth: CGFloat = 120
    static let maxSidebarWidth: CGFloat = 280
    /// The editor always keeps this width: the sidebar gives way first.
    static let minEditorWidth: CGFloat = 200

    static func panelWidth(_ wanted: CGFloat) -> CGFloat {
        max(minPanelWidth, min(maxPanelWidth, wanted))
    }

    /// The width the sidebar is shown with in a panel of `panelWidth`: the wanted width inside its own limits, and
    /// never so wide that the editor gets less than `minEditorWidth`.
    static func sidebarWidth(wanted: CGFloat, panelWidth: CGFloat) -> CGFloat {
        let room = max(minSidebarWidth, min(maxSidebarWidth, panelWidth - minEditorWidth))
        return max(minSidebarWidth, min(room, wanted))
    }
}

enum Defaults {
    static let panelWidth = "panelWidth"
    static let notesFolder = "notesFolder"
    /// The last selected note, by filename (a note's id only lives for one session).
    static let lastSelectedNoteFilename = "lastSelectedNoteFilename"
    static let sidebarWidth = "sidebarWidth"
    static let showInDock = "showInDock"
    // launchAtLogin is NOT stored in UserDefaults — read from SMAppService.mainApp.status (RESEARCH Pitfall 1)
    // hotkey stored automatically by KeyboardShortcuts library

    /// Fixed UserDefaults suite for the notes-folder location, shared across
    /// launch identities (the `.app` bundle's `.standard` domain
    /// `com.oguzoral.Sidekick` vs a bare `swift run` executable's `Sidekick`
    /// domain). Routing the `notesFolder` key here means every build resolves
    /// the SAME notes folder, closing the dual-folder data-loss hazard (RC2).
    /// NOTE: the suite name must NOT be the app bundle id, or init returns nil.
    static let store: UserDefaults = {
        let suite = UserDefaults(suiteName: "com.oguzoral.Sidekick.shared") ?? .standard
        // One-time migration: if the shared suite has no notesFolder yet but a
        // legacy custom path was set under .standard, copy it across so a user
        // who had picked a custom folder doesn't get silently reset to default.
        if suite.string(forKey: notesFolder) == nil,
           let legacy = UserDefaults.standard.string(forKey: notesFolder),
           !legacy.isEmpty {
            suite.set(legacy, forKey: notesFolder)
        }
        return suite
    }()
}
