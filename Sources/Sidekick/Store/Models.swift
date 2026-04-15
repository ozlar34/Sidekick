import Foundation

struct Note: Identifiable, Equatable {
    let id: UUID
    var filename: String
    var body: String
    var pinned: Bool
    var order: Int
}

struct NoteIndex: Codable, Equatable {
    let version: Int          // == 1, CONTEXT.md schema
    var notes: [IndexEntry]
}

struct IndexEntry: Codable, Equatable {
    let id: UUID
    var filename: String
    var pinned: Bool
    var order: Int
}

struct DiskEntry: Equatable {
    let filename: String
    let mtime: Date
}

enum ChangeEvent: Equatable {
    case externalModification(ids: Set<UUID>)
}

enum FolderEvent { case mayHaveChanged }  // internal, used by plan 02-02 watcher
