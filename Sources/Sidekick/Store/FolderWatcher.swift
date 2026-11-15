import Foundation
import Dispatch

/// Directory-level file-system watcher built on `DispatchSource.makeFileSystemObjectSource`.
/// Debounces bursts (150ms) and bridges vnode events to an `AsyncStream<FolderEvent>`.
///
/// Pattern sources:
///   - RESEARCH.md §Pattern 1 (Directory watcher with AsyncStream bridge)
///   - SwiftRocks: dispatchsource-detecting-changes-in-files-and-folders-in-swift
///   - GianniCarlo/DirectoryWatcher (O_EVTONLY + cancelHandler protocol)
///
/// IMPORTANT: watches the *parent directory*, never individual files, because
/// atomic writes replace the file inode and destroy per-file watchers.
/// See RESEARCH.md Anti-Patterns.
/// What the watcher compares between two looks at the folder: per `.md` file, its change time and size.
enum FolderSnapshot {
    struct Stamp: Equatable {
        let mtime: Date
        let size: Int
    }

    static func take(_ folder: URL) -> [String: Stamp] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        var result: [String: Stamp] = [:]
        for url in urls where url.pathExtension == "md" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            result[url.lastPathComponent] = Stamp(mtime: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0)
        }
        return result
    }

    /// Files added, removed or changed between two snapshots.
    static func changedFiles(from old: [String: Stamp], to new: [String: Stamp]) -> Set<String> {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }
}

final class FolderWatcher {

    // MARK: - Public API

    let events: AsyncStream<FolderEvent>

    // MARK: - Lifecycle

    private let url: URL
    private let queue = DispatchQueue(label: "sidekick.folderwatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var snapshot: [String: FolderSnapshot.Stamp] = [:]
    private var continuation: AsyncStream<FolderEvent>.Continuation?
    private let debounce: DispatchTimeInterval = .milliseconds(150)  // RESEARCH.md Pattern 1 — 150ms coalesces atomic-write burst

    init(url: URL) {
        self.url = url
        var cont: AsyncStream<FolderEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
        cont.onTermination = { [weak self] _ in self?.stop() }
    }

    func start() throws {
        snapshot = FolderSnapshot.take(url)
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleEmit() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        src.resume()
        self.source = src
    }

    func stop() {
        debounceWorkItem?.cancel()
        source?.cancel()
        source = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Event pump

    private func scheduleEmit() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Runs on `queue`, like every other touch of `snapshot`.
            guard let self else { return }
            let now = FolderSnapshot.take(self.url)
            let changed = FolderSnapshot.changedFiles(from: self.snapshot, to: now)
            self.snapshot = now
            // A folder that vanished or was renamed shows as every file gone: still a change.
            if !changed.isEmpty { self.continuation?.yield(.filesChanged(changed)) }
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)

        // If folder itself was renamed/deleted, the source is now stale.
        // Caller (NoteStore) receives .mayHaveChanged, runs reconcile,
        // discovers folder is gone, and calls start() again after recreating it.
        // (Phase 5 handles the user-facing missing-folder case.)
    }

    deinit { stop() }
}
