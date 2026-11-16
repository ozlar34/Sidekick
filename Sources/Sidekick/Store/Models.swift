import Foundation

/// One `.md` file. `filename` is its identity and `title` is the filename without ".md". `id` only
/// lives for one session (nothing on disk stores it); a rename made by the store keeps it.
struct Note: Identifiable, Equatable {
    let id: UUID
    var filename: String
    var title: String = ""
    var body: String
    var pinned: Bool
    var order: Int
    var modified: Date? = nil
    var createdAt: Date? = nil
}

struct DiskEntry: Equatable {
    let filename: String
    let mtime: Date
    var created: Date? = nil
}

enum ChangeEvent: Equatable {
    case externalModification(ids: Set<UUID>)
}

/// What the folder watcher reports: the `.md` files that were added, removed or changed.
enum FolderEvent { case filesChanged(Set<String>) }

enum NoteStoreError: Error, Equatable {
    /// The file on disk is not what the caller last read or wrote.
    case conflict
    /// The store has no note with this id.
    case unknownNote
}
