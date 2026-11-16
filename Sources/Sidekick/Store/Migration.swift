import Foundation

/// The old `.index.json` format. Read only, for the one-time migration.
struct LegacyIndex: Codable, Equatable {
    let version: Int
    var notes: [LegacyEntry]
}

struct LegacyEntry: Codable, Equatable {
    let id: UUID
    var filename: String
    var title: String? = nil
    var pinned: Bool
    var order: Int
    var createdAt: Date? = nil
}

/// One-time migration from slug filenames plus `.index.json` to title filenames plus the order file.
///
/// Steps, in order. Each is one atomic file-system action, and a crash after any of them is repaired
/// by running `run` again:
///
///  1. Back up: copy the whole folder to `<name>-backup-<date>.partial` beside it, verify it equals the
///     original byte for byte, then move it to `<name>-backup-<date>`. No file of the folder changes yet.
///  2. Journal: write the plan (old name, temporary name, final name, pin, order per note) to
///     `.sidekick-migration.json`. From here the plan is read from the journal, never recomputed.
///  3. Stage: move every file that changes name to a temporary hidden name (so swapped or chained names
///     cannot collide), then mark the journal as staged.
///  4. Finish: move each staged file to its final name. A name that a foreign file took meanwhile gets
///     a number suffix; nothing is ever replaced.
///  5. Write the order file from the plan; when one exists already, merge the plan into it.
///  6. Keep the old index: move `.index.json` to `.index.json.migrated`.
///  7. Record completion: write `.sidekick-migrated.json`, then remove the journal.
///
/// A folder with neither `.index.json` nor a journal is new format and is left untouched.
/// The migration did not finish and could not be completed by itself. It is tried again next launch.
struct MigrationFailure: Error {
    let reason: String
    /// Name of a complete backup folder beside the notes folder, when one was made.
    let backup: String?
    /// True when some files were already renamed before it failed (the next launch finishes the job).
    var partlyDone = false
    /// True while some note files sit under their temporary names, so they are not in the list.
    var temporarilyMissing = false

    /// One line for the editor pane.
    var noticeText: String {
        var text = "Your notes could not be converted to the new format (\(reason)). "
        if temporarilyMissing {
            text += "Some notes are temporarily missing from the list; they will reappear when Sidekick finishes the conversion on next launch. No note text was changed."
        } else if partlyDone {
            text += "Some files were already renamed; no note text was changed. Sidekick tries again next launch."
        } else {
            text += "Nothing was changed; the notes are shown as they are. Sidekick tries again next launch."
        }
        if let backup { text += " A backup of the folder is beside it: \(backup)." }
        return text
    }
}

enum Migration {
    static let markerName = ".sidekick-migrated.json"
    static let journalName = ".sidekick-migration.json"
    static let indexName = ".index.json"
    static let retiredIndexName = ".index.json.migrated"

    enum Outcome: Equatable {
        case notNeeded
        case alreadyDone
        case migrated(renamed: Int, backup: String)
    }

    private struct Journal: Codable {
        struct Entry: Codable {
            var old: String
            var new: String
            var base: String
            var temp: String?        // nil: the file keeps its name
            var pinned: Bool
            var order: Int
        }
        var version = 1
        var backup: String
        /// True once every renamed file has been moved to its temporary name. From then on an old name may
        /// belong to a different file (a swapped title), so staging is never run again.
        var staged = false
        /// The order file as it was before the first rename, if there was a valid one. The merge in step 5 starts
        /// from this copy, so repeating it after a crash gives the same file (the file itself may already hold final names).
        var priorOrder: OrderFile?
        var entries: [Entry]
    }

    private struct Marker: Codable {
        var version = 1
        var completedAt: String
        var backup: String
        var renamed: Int
    }

    /// `checkpoint` is called after each step with its name; tests throw from it to simulate a crash.
    /// Any failure is reported as a `MigrationFailure`; the next call picks up where this one stopped.
    /// The folder is resolved first: a notes folder that is a symlink is backed up as the real directory it points to.
    static func run(folder: URL, now: Date = Date(), checkpoint: ((String) throws -> Void)? = nil) throws -> Outcome {
        var progress = Progress()
        do {
            return try runResolved(folder: folder.resolvingSymlinksInPath(), now: now, checkpoint: checkpoint, progress: &progress)
        } catch let failure as MigrationFailure {
            throw failure
        } catch {
            let hidden = ((try? FileManager.default.contentsOfDirectory(atPath: folder.resolvingSymlinksInPath().path)) ?? [])
                .contains { $0.hasPrefix(".sidekick-migrating-") }
            throw MigrationFailure(reason: error.localizedDescription, backup: progress.backup,
                                   partlyDone: progress.renamed || hidden, temporarilyMissing: hidden)
        }
    }

    private struct Progress {
        var backup: String?
        /// A file has actually been moved (in this run or an earlier one).
        var renamed = false
    }

    private static func runResolved(folder: URL, now: Date, checkpoint: ((String) throws -> Void)?, progress: inout Progress) throws -> Outcome {
        func hit(_ name: String) throws { try checkpoint?(name) }
        let marker = folder.appendingPathComponent(markerName)
        let journalURL = folder.appendingPathComponent(journalName)
        let indexURL = folder.appendingPathComponent(indexName)

        if FileOps.exists(marker) {
            try? FileManager.default.removeItem(at: journalURL)
            return .alreadyDone
        }
        guard FileOps.exists(journalURL) || FileOps.exists(indexURL) else { return .notNeeded }
        try hit("start")

        var journal: Journal
        if let data = try? Data(contentsOf: journalURL), let existing = try? JSONDecoder().decode(Journal.self, from: data) {
            journal = existing
            progress.backup = existing.backup
            progress.renamed = existing.staged
        } else {
            // An index that cannot be read is a failure, not an empty index: dropping it would drop every
            // title, pin and the order for good. Nothing is touched; the next launch tries again.
            guard let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(LegacyIndex.self, from: data) else {
                throw MigrationFailure(reason: "the old index file \(indexName) cannot be read", backup: nil)
            }
            let backupName = try makeBackup(of: folder, now: now, hit: hit)
            progress.backup = backupName
            let entries = plan(index: index, in: folder)
            let prior = (try? Data(contentsOf: folder.appendingPathComponent(OrderFile.filename))).flatMap(OrderFile.decode)
            journal = Journal(backup: backupName, priorOrder: prior, entries: entries)
            try write(journal, to: journalURL)
            try hit("journal-written")
        }

        let moving = journal.entries.indices.filter { journal.entries[$0].temp != nil }
        if !journal.staged {
            for (n, i) in moving.enumerated() {
                let e = journal.entries[i]
                let names = listing(folder).keys
                if names.contains(key(e.old)), !names.contains(key(e.temp!)) {
                    try FileOps.moveNoClobber(folder.appendingPathComponent(e.old), to: folder.appendingPathComponent(e.temp!))
                    progress.renamed = true
                }
                try hit("rename-a-\(n)")
            }
            journal.staged = true
            try write(journal, to: journalURL)
            try hit("renames-staged")
        }
        for (n, i) in moving.enumerated() {
            let temp = journal.entries[i].temp!
            if listing(folder).keys.contains(key(temp)) {
                var attempt = 1
                while true {
                    do {
                        try FileOps.moveNoClobber(folder.appendingPathComponent(temp),
                                                  to: folder.appendingPathComponent(journal.entries[i].new))
                        progress.renamed = true
                        break
                    } catch FileOpsError.exists {
                        // A file that is not ours took the name while we worked: never replace it.
                        attempt += 1
                        journal.entries[i].new = freeName(base: journal.entries[i].base, in: folder, startingAt: attempt)
                        try write(journal, to: journalURL)
                    }
                }
            }
            try hit("rename-b-\(n)")
        }

        let orderURL = folder.appendingPathComponent(OrderFile.filename)
        if !journal.entries.isEmpty {
            let sorted = journal.entries.sorted { ($0.pinned ? 0 : 1, $0.order) < ($1.pinned ? 0 : 1, $1.order) }
            let planned = OrderFile(pinned: sorted.filter(\.pinned).map(\.new), order: sorted.map(\.new))
            let merged: OrderFile
            if let existing = journal.priorOrder {
                // An order file made since (an earlier attempt failed and the app ran on the old names): its
                // entries keep their places and pins, names are carried through the renames, and the old
                // index's pins and order are added. Applying this twice gives the same file.
                let renamed = Dictionary(journal.entries.map { ($0.old, $0.new) }, uniquingKeysWith: { first, _ in first })
                let order = existing.order.map { renamed[$0] ?? $0 }
                let pinned = existing.pinned.map { renamed[$0] ?? $0 }
                merged = OrderFile(pinned: pinned + planned.pinned.filter { !pinned.contains($0) },
                                   order: order + planned.order.filter { !order.contains($0) })
            } else {
                merged = planned
            }
            if (try? Data(contentsOf: orderURL)).flatMap(OrderFile.decode) != merged {
                try merged.encoded().write(to: orderURL, options: [.atomic])
            }
        }
        try hit("order-written")

        if FileOps.exists(indexURL) {
            var retired = folder.appendingPathComponent(retiredIndexName)
            var n = 1
            while FileOps.exists(retired) { n += 1; retired = folder.appendingPathComponent("\(retiredIndexName)-\(n)") }
            try FileOps.moveNoClobber(indexURL, to: retired)
        }
        try hit("index-retired")

        let stamp = ISO8601DateFormatter().string(from: now)
        try write(Marker(completedAt: stamp, backup: journal.backup, renamed: moving.count), to: marker)
        try hit("marker-written")
        try? FileManager.default.removeItem(at: journalURL)
        try hit("journal-removed")
        return .migrated(renamed: moving.count, backup: journal.backup)
    }

    // MARK: Plan

    private static func plan(index: LegacyIndex, in folder: URL) -> [Journal.Entry] {
        let present = Set(listing(folder).keys)
        let indexed = index.notes.enumerated()
            .filter { present.contains(key($0.element.filename)) }
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)

        // Pass 1: names that stay. Strays (files the index never named) and notes whose index entry has no
        // title key at all (a pre-title index) keep theirs. An empty title becomes "Untitled", as in the title rules.
        var reserved = Set(present.filter { $0.hasSuffix(".md") }.map { $0.lowercased() })
        for e in indexed { reserved.remove(lowerKey(e.filename)) }
        var bases: [String?] = []
        for e in indexed {
            guard let title = e.title else { reserved.insert(lowerKey(e.filename)); bases.append(nil); continue }
            let base = TitleRules.fileBase(forTitle: title)
            if key(base + ".md") == key(e.filename) { reserved.insert(lowerKey(e.filename)); bases.append(nil) } else { bases.append(base) }
        }
        // Pass 2: the others, in order, take the first free name.
        var entries: [Journal.Entry] = []
        for (i, e) in indexed.enumerated() {
            guard let base = bases[i] else {
                entries.append(.init(old: e.filename, new: e.filename, base: String(e.filename.dropLast(3)), temp: nil, pinned: e.pinned, order: e.order))
                continue
            }
            var n = 1
            var name = TitleRules.candidate(base: base, number: n) + ".md"
            while reserved.contains(lowerKey(name)) { n += 1; name = TitleRules.candidate(base: base, number: n) + ".md" }
            reserved.insert(lowerKey(name))
            if key(name) == key(e.filename) {
                entries.append(.init(old: e.filename, new: e.filename, base: base, temp: nil, pinned: e.pinned, order: e.order))
            } else {
                entries.append(.init(old: e.filename, new: name, base: base, temp: ".sidekick-migrating-\(i).tmp", pinned: e.pinned, order: e.order))
            }
        }
        return entries
    }

    private static func freeName(base: String, in folder: URL, startingAt first: Int) -> String {
        var n = first
        while true {
            let name = TitleRules.candidate(base: base, number: n) + ".md"
            if !FileOps.exists(folder.appendingPathComponent(name)) { return name }
            n += 1
        }
    }

    // MARK: Backup

    /// Returns the name of a complete backup of the folder as it is now (no migration step has changed it yet).
    private static func makeBackup(of folder: URL, now: Date, hit: (String) throws -> Void) throws -> String {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let stem = "\(folder.lastPathComponent)-backup-\(formatter.string(from: now))"
        var n = 1
        while true {
            let name = n == 1 ? stem : "\(stem)-\(n)"
            let dest = parent.appendingPathComponent(name)
            if FileOps.exists(dest) {
                if try treesEqual(dest, folder) { return name }      // an earlier, interrupted run made it
                n += 1
                continue
            }
            // Never touch a path this run did not create: take the first `.partial` name that is free.
            var k = 1
            var partial = parent.appendingPathComponent(name + ".partial")
            while FileOps.exists(partial) { k += 1; partial = parent.appendingPathComponent("\(name)-\(k).partial") }
            // This run made `partial`: any failure takes exactly that directory away again, so a failed
            // attempt leaves no half copy in the parent.
            do {
                try fm.copyItem(at: folder, to: partial)
                try hit("backup-copied")
                guard try treesEqual(partial, folder) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the backup of \(folder.lastPathComponent) does not match the original"])
                }
                try FileOps.moveNoClobber(partial, to: dest)
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
            try hit("backup-verified")
            return name
        }
    }

    /// Same relative paths and the same bytes in every file, hidden files included.
    private static func treesEqual(_ a: URL, _ b: URL) throws -> Bool {
        // A tree compared with itself proves nothing (a backup that is a link to the folder).
        if FileOps.isSameDirectory(a, b) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the backup is the same directory as the notes folder"])
        }
        func entries(_ root: URL) throws -> [String: Bool] {
            var result: [String: Bool] = [:]
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { return result }
            for case let rel as String in walker {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDir)
                result[rel.precomposedStringWithCanonicalMapping] = isDir.boolValue
            }
            return result
        }
        let left = try entries(a), right = try entries(b)
        guard left == right else { return false }
        for (rel, isDir) in left where !isDir {
            guard let x = try? Data(contentsOf: a.appendingPathComponent(rel), options: .mappedIfSafe),
                  let y = try? Data(contentsOf: b.appendingPathComponent(rel), options: .mappedIfSafe), x == y else { return false }
        }
        return true
    }

    // MARK: Helpers

    /// The names in the folder (hidden files included), keyed by their canonical form, mapping to the stored name.
    private static func listing(_ folder: URL) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Dictionary(names.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }
    private static func lowerKey(_ name: String) -> String { key(name).lowercased() }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
