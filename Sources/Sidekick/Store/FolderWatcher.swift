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
final class FolderWatcher {

    // MARK: - Public API

    let events: AsyncStream<FolderEvent>

    // MARK: - Lifecycle

    private let url: URL
    private let queue = DispatchQueue(label: "sidekick.folderwatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
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
            self?.continuation?.yield(.mayHaveChanged)
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
