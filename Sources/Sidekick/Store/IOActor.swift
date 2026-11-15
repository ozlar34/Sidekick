/// Off-main file I/O actor. Owns the notes folder URL; serializes all
/// reads/writes/scan/rename operations so slug collision detection and
/// atomic writes cannot race.
///
/// Pattern sources:
///   - RESEARCH.md §Code Examples (writeNote, renameNote, loadIndex, saveIndex, scan)
///   - RESEARCH.md Pitfall 3 (rename race → actor isolation)
///   - CONTEXT.md: all writes atomic, .index.json authoritative
import Foundation

actor IOActor {

    let folder: URL
    /// Moves a file to the Trash. Tests inject a plain removal so they never touch the real Trash.
    private let trash: @Sendable (URL) throws -> Void

    init(folder: URL, trash: (@Sendable (URL) throws -> Void)? = nil) {
        self.folder = folder
        self.trash = trash ?? { url in
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
            NSLog("[Sidekick] trashed \(url.lastPathComponent) → \(resultURL?.path ?? "?")")
        }
    }

    // MARK: - Notes

    func writeNote(_ body: String, filename: String) throws {
        let url = folder.appendingPathComponent(filename)
        let data = Data(body.utf8)
        // .atomic writes to a sibling temp file and rename(2)s into place.
        // Single watcher event; no partial-write window.
        try data.write(to: url, options: [.atomic])
    }

    /// Atomic write that only happens when the file's current bytes equal `baseline`. When
    /// `newFilename` differs the note moves there, and the old file goes after the new one is in place.
    /// Throws `NoteStoreError.conflict` (and writes nothing) when the file changed or is gone.
    func writeConditional(_ data: Data, filename: String, newFilename: String, baseline: Data) throws {
        let url = folder.appendingPathComponent(filename)
        guard let current = try? Data(contentsOf: url), current == baseline else { throw NoteStoreError.conflict }
        let target = folder.appendingPathComponent(newFilename)
        try data.write(to: target, options: [.atomic])
        if newFilename != filename { try FileManager.default.removeItem(at: url) }
    }

    func readNote(filename: String) throws -> String {
        let url = folder.appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func mtime(filename: String) -> Date? {
        let url = folder.appendingPathComponent(filename)
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return vals?.contentModificationDate
    }

    func deleteNote(filename: String) throws {
        let url = folder.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: url)
    }

    func trashNote(filename: String) throws {
        let url = folder.appendingPathComponent(filename)
        try trash(url)
    }

    func renameNote(oldFilename: String, newFilename: String) throws {
        guard oldFilename != newFilename else { return }
        let oldURL = folder.appendingPathComponent(oldFilename)
        let newURL = folder.appendingPathComponent(newFilename)
        // Read old body, write new atomically, then delete old.
        // On write failure, old file is intact (CONTEXT.md rule).
        let body = try String(contentsOf: oldURL, encoding: .utf8)
        try Data(body.utf8).write(to: newURL, options: [.atomic])
        try FileManager.default.removeItem(at: oldURL)
    }

    // MARK: - Index

    func loadIndex() -> NoteIndex? {
        let url = folder.appendingPathComponent(".index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(NoteIndex.self, from: data)
        } catch {
            // Move to .bak for post-mortem, return nil to trigger rebuild.
            NSLog("[Sidekick] IOActor: corrupt .index.json, moving to .bak — \(error)")
            let bak = folder.appendingPathComponent(".index.json.bak")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.moveItem(at: url, to: bak)
            return nil
        }
    }

    func saveIndex(_ index: NoteIndex) throws {
        let url = folder.appendingPathComponent(".index.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Scan

    func scan() throws -> [DiskEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url in
            guard url.pathExtension == "md" else { return nil }
            guard !url.lastPathComponent.hasSuffix(".md.tmp") else { return nil }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            guard vals?.isRegularFile == true else { return nil }
            return DiskEntry(
                filename: url.lastPathComponent,
                mtime: vals?.contentModificationDate ?? .distantPast
            )
        }
    }

    // MARK: - Slug

    /// Computes a collision-free slug for the given heading, excluding the
    /// current filename of the note being renamed (by `idToSkip`).
    /// Actor isolation ensures no two concurrent creates/renames race on the
    /// same `existing` set. (RESEARCH.md Pitfall 3)
    func slug(for heading: String, excluding idToSkip: UUID?, index: NoteIndex) -> String {
        let existing: Set<String> = Set(
            index.notes
                .filter { idToSkip == nil || $0.id != idToSkip }
                .map { String($0.filename.dropLast(3)) } // strip ".md"
        )
        return Slug.make(from: heading, existing: existing)
    }
}
