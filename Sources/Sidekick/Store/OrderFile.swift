import Foundation

/// Pin state and manual order, by filename. It holds nothing else: no note text and no title depends
/// on it, so a missing or damaged file costs the order and the pins and nothing more.
///
///     {"order":["Meeting notes.md","Ideas.md","Todo.md"],"pinned":["Meeting notes.md"],"version":2}
struct OrderFile: Codable, Equatable {
    static let filename = ".sidekick-order.json"
    var version = 2
    var pinned: [String]
    var order: [String]

    struct Arranged: Equatable {
        let filename: String
        let pinned: Bool
    }

    /// The notes in display order: pinned first, each group in the stored order. Names the folder does
    /// not hold are ignored; files the order file does not know are appended, newest first.
    func arrange(_ entries: [DiskEntry]) -> [Arranged] {
        let onDisk = Set(entries.map(\.filename))
        var seen = Set<String>()
        var names = order.filter { onDisk.contains($0) && seen.insert($0).inserted }
        let newcomers = entries.filter { !seen.contains($0.filename) }.sorted {
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.filename < $1.filename
        }
        names += newcomers.map(\.filename)
        let pins = Set(pinned)
        let arranged = names.map { Arranged(filename: $0, pinned: pins.contains($0)) }
        return arranged.filter(\.pinned) + arranged.filter { !$0.pinned }
    }

    static func make(from arranged: [Arranged]) -> OrderFile {
        OrderFile(pinned: arranged.filter(\.pinned).map(\.filename), order: arranged.map(\.filename))
    }

    /// nil when the data is not a valid order file.
    static func decode(_ data: Data) -> OrderFile? {
        try? JSONDecoder().decode(OrderFile.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
