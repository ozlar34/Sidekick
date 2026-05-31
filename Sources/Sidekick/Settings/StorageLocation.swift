import Foundation

/// Default storage location for notes. Lives under
/// `~/Library/Application Support/Sidekick/` — Apple's canonical path for
/// app-private data — to avoid the macOS TCC prompt that fires on every
/// rebuild for `~/Documents` access (TCC keys ad-hoc-signed binaries by
/// cdhash, which changes on every `swift build`).
enum StorageLocation {
    static let appSupportSubdir = "Sidekick"
    static let legacyDocumentsSubdir = "Documents/Sidekick"

    static var defaultNotesFolder: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(appSupportSubdir)
    }

    static var legacyNotesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(legacyDocumentsSubdir)
    }

    /// One-shot migration from the legacy `~/Documents/Sidekick/` location to
    /// the new App Support default. Best-effort: on failure, pin the legacy
    /// path in UserDefaults so the app keeps working without data loss.
    /// No-op when the user has explicitly set a custom `notesFolder`.
    static func migrateDefaultLocationIfNeeded() {
        let configured = Defaults.store.string(forKey: Defaults.notesFolder) ?? ""
        guard configured.isEmpty else { return }

        let fm = FileManager.default
        let old = legacyNotesFolder
        let new = defaultNotesFolder

        var oldIsDir: ObjCBool = false
        let oldExists = fm.fileExists(atPath: old.path, isDirectory: &oldIsDir)
        let newExists = fm.fileExists(atPath: new.path)

        guard oldExists, oldIsDir.boolValue, !newExists else { return }

        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try fm.moveItem(at: old, to: new)
            NSLog("[Sidekick] migrated notes folder: \(old.path) -> \(new.path)")
        } catch {
            NSLog("[Sidekick] notes folder migration failed: \(error.localizedDescription) — keeping legacy path")
            Defaults.store.set(old.path, forKey: Defaults.notesFolder)
        }
    }
}
