import Foundation

/// The rule for the one-time welcome window: it shows to a person who has never used this install, and never again
/// once it was dismissed.
enum FirstRun {
    static let seenKey = "firstRunSeen"

    /// Keys that only exist after the app was used once. An install that has any of them predates the welcome window,
    /// so its owner is not greeted after an update.
    private static let earlierUseKeys = [Defaults.panelWidth, Defaults.lastSelectedNoteFilename]

    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: seenKey) { return false }
        return !earlierUseKeys.contains { defaults.object(forKey: $0) != nil }
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}
