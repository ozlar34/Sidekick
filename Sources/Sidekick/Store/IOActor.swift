/// Off-main file I/O actor. Owns the notes folder URL; every read, write, scan and rename of the
/// folder goes through it.
///
/// Files are the only truth: a note is a `.md` file, its title is the filename. No operation here
/// replaces a file it did not write: creates are exclusive, renames never take a taken name, and a
/// conditional write checks the file's current bytes against the caller's baseline first.
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

    /// Creates an empty `<base>.md`, or `<base> 2.md`, ... and returns its filename. The check and the
    /// create are one kernel call, so a file made by another tool a moment earlier is never replaced.
    func createNote(base: String) throws -> String {
        let safeBase = TitleRules.fileBase(forTitle: base)
        var n = 1
        while true {
            let name = TitleRules.candidate(base: safeBase, number: n) + ".md"
            do {
                try FileOps.createExclusive(folder.appendingPathComponent(name))
                return name
            } catch FileOpsError.exists {
                n += 1
            }
        }
    }

    /// Writes `data` to the note's file and, when `wantedBase` is given, renames the file to that title
    /// (or to the first free "<title> 2", ...). Returns the filename the note has afterwards.
    ///
    /// With a `baseline` the write happens only when the file's current bytes equal it: otherwise
    /// `NoteStoreError.conflict` is thrown and nothing changes, not even a rename. Without one
    /// the write is unconditional and recreates a file that is gone.
    func save(_ data: Data, filename: String, wantedBase: String?, baseline: Data?) throws -> String {
        let url = folder.appendingPathComponent(filename)
        let present = FileOps.exists(url)
        if let baseline {
            guard present, let current = try? Data(contentsOf: url), current == baseline else { throw NoteStoreError.conflict }
        }
        let created = present ? FileOps.creationDate(url) : nil
        var finalName = filename
        if present, let wantedBase { finalName = try move(url, named: filename, toTitle: wantedBase) }
        let target = folder.appendingPathComponent(finalName)
        do {
            try data.write(to: target, options: [.atomic])
        } catch {
            if finalName != filename { try? FileOps.moveNoClobber(target, to: url) }   // undo the rename: nothing half done
            throw error
        }
        FileOps.setCreationDate(created, of: target)
        return finalName
    }

    /// Moves the file to the first free name for `base` (or keeps its name when that is the first free one).
    private func move(_ url: URL, named filename: String, toTitle base: String) throws -> String {
        var n = 1
        while true {
            let name = TitleRules.candidate(base: base, number: n) + ".md"
            if name.precomposedStringWithCanonicalMapping == filename.precomposedStringWithCanonicalMapping { return filename }
            do {
                try FileOps.moveNoClobber(url, to: folder.appendingPathComponent(name))
                return name
            } catch FileOpsError.exists {
                n += 1
            }
        }
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

    func trashNote(filename: String) throws {
        let url = folder.appendingPathComponent(filename)
        try trash(url)
    }

    // MARK: - Order file

    enum OrderLoad {
        case missing
        case loaded(OrderFile)
        /// The file was not a valid order file; it was moved aside to the first free `.sidekick-order.json.damaged`, `... 2`, ....
        case damaged
    }

    func loadOrder() -> OrderLoad {
        let url = folder.appendingPathComponent(OrderFile.filename)
        guard FileOps.exists(url) else { return .missing }
        if let data = try? Data(contentsOf: url), let order = OrderFile.decode(data) { return .loaded(order) }
        NSLog("[Sidekick] IOActor: damaged \(OrderFile.filename), moving it aside — order and pins reset")
        // Never delete or replace a file this run did not create: take the first free ".damaged", ".damaged 2", ...
        var n = 1
        while n < 1000 {
            let aside = folder.appendingPathComponent(OrderFile.filename + ".damaged" + (n == 1 ? "" : " \(n)"))
            if !FileOps.exists(aside), (try? FileOps.moveNoClobber(url, to: aside)) != nil { break }
            n += 1
        }
        return .damaged
    }

    func saveOrder(_ order: OrderFile) throws {
        try order.encoded().write(to: folder.appendingPathComponent(OrderFile.filename), options: [.atomic])
    }

    // MARK: - Migration

    func migrate(now: Date = Date()) throws -> Migration.Outcome {
        try Migration.run(folder: folder, now: now)
    }

    // MARK: - Scan

    func scan() throws -> [DiskEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url in
            guard url.pathExtension == "md" else { return nil }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            guard vals?.isRegularFile == true else { return nil }
            return DiskEntry(
                filename: url.lastPathComponent,
                mtime: vals?.contentModificationDate ?? .distantPast,
                created: vals?.creationDate
            )
        }
    }
}
