@testable import Sidekick
import Foundation

enum DiskSnapshotFixture {
    static func make(_ entries: [(filename: String, mtimeSecondsAgo: Int)]) -> [DiskEntry] {
        entries.map {
            DiskEntry(
                filename: $0.filename,
                mtime: Date(timeIntervalSinceNow: -Double($0.mtimeSecondsAgo))
            )
        }
    }
}
