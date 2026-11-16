import Foundation
@testable import Sidekick

/// A synthetic old-format notes folder (slug filenames plus `.index.json`). All content is invented.
/// The tricky titles are the ones the migration must survive: path characters, leading dots, emoji,
/// duplicates, an empty title, a very long title, and names that differ only by case or accent.
enum OldFormatFixture {
    struct Item {
        let slug: String
        let title: String?
        let body: String
        let pinned: Bool
        let order: Int
    }

    static let longTitle = String(repeating: "A very long title that keeps going ", count: 12)

    static let items: [Item] = [
        Item(slug: "meeting-notes", title: "Meeting notes", body: "# Meeting\nagenda\n", pinned: true, order: 0),
        Item(slug: "a-b-plan", title: "A/B plan", body: "slash in the title\n", pinned: false, order: 3),
        Item(slug: "time-12-30", title: "Time: 12:30", body: "colons\r\nwith CRLF\r\n", pinned: true, order: 1),
        Item(slug: "dotted", title: "...hidden?", body: "leading dots", pinned: false, order: 4),
        Item(slug: "party", title: "Party \u{1F389}", body: "emoji \u{1F389} and caf\u{E9}\n", pinned: false, order: 5),
        Item(slug: "same", title: "Same", body: "first same\n", pinned: false, order: 6),
        Item(slug: "same-2", title: "Same", body: "second same\n", pinned: false, order: 7),
        Item(slug: "untitled-1a2b3c4d", title: "", body: "", pinned: false, order: 8),
        Item(slug: "long", title: longTitle, body: "long\n", pinned: false, order: 9),
        Item(slug: "ideas", title: "Ideas", body: "upper\n", pinned: false, order: 10),
        Item(slug: "ideas-2", title: "ideas", body: "lower\n", pinned: false, order: 11),
        Item(slug: "cafe", title: "Caf\u{E9}", body: "accent\n", pinned: false, order: 12),
        Item(slug: "cafe-2", title: "cafe", body: "plain\n", pinned: false, order: 13),
        Item(slug: "no-title-key", title: nil, body: "pre-title index entry\n", pinned: false, order: 2),
    ]

    @discardableResult
    static func write(into folder: URL, items: [Item] = items) throws -> LegacyIndex {
        var entries: [LegacyEntry] = []
        for (i, item) in items.enumerated() {
            let url = folder.appendingPathComponent(item.slug + ".md")
            try Data(item.body.utf8).write(to: url)
            // Distinct, stable modification times.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)],
                                                  ofItemAtPath: url.path)
            entries.append(LegacyEntry(id: UUID(), filename: item.slug + ".md", title: item.title,
                                       pinned: item.pinned, order: item.order,
                                       createdAt: Date(timeIntervalSince1970: 1_690_000_000 + Double(i))))
        }
        let index = LegacyIndex(version: 1, notes: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: folder.appendingPathComponent(".index.json"))
        return index
    }
}

enum FolderTree {
    /// Every entry under `url`, hidden files included: relative path to bytes (a directory is "name/" with no bytes).
    static func snapshot(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return result }
        for case let rel as String in walker {
            let full = url.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
            if isDir.boolValue { result[rel.precomposedStringWithCanonicalMapping + "/"] = Data() }
            else { result[rel.precomposedStringWithCanonicalMapping] = try Data(contentsOf: full) }
        }
        return result
    }
}
