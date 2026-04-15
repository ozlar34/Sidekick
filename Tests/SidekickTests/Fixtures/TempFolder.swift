import Foundation

/// RAII temporary directory helper for tests.
/// Creates a unique subdirectory under `FileManager.default.temporaryDirectory`
/// on init and removes the entire tree on deinit.
final class TempFolder {
    let url: URL

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidekickTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        self.url = dir
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
