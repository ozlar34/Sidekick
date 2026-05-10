import Foundation

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

struct NoteIndex: Codable, Equatable {
    let version: Int          // == 1, CONTEXT.md schema
    var notes: [IndexEntry]
}

struct IndexEntry: Codable, Equatable {
    let id: UUID
    var filename: String
    // Optional for backwards compat with pre-migration .index.json files
    // (Decodable synthesis tolerates missing keys for Optional). Populated
    // lazily by NoteStore.applyIndex from HeadingExtractor → first
    // meaningful line → "Untitled" when nil, then persisted on next save.
    var title: String? = nil
    var pinned: Bool
    var order: Int
    // Optional for backwards compat with pre-migration .index.json files.
    // Backfilled in NoteStore.applyIndex from filesystem creation date the
    // first time an old index is loaded; persisted on the next save.
    var createdAt: Date? = nil
}

struct DiskEntry: Equatable {
    let filename: String
    let mtime: Date
}

enum ChangeEvent: Equatable {
    case externalModification(ids: Set<UUID>)
}

enum FolderEvent { case mayHaveChanged }  // internal, used by plan 02-02 watcher
