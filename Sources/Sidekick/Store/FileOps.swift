import Foundation
import Darwin

enum FileOpsError: Error, Equatable {
    /// The destination name is taken by a different file.
    case exists
}

/// File-system helpers where "never replace a file that is already there" is decided by the kernel,
/// not by a look at the folder a moment before.
enum FileOps {
    private static let renameExclusive: UInt32 = 0x0000_0004   // RENAME_EXCL

    /// True when something (a file, a directory, a dangling link) is at `url`. On a case-insensitive
    /// volume a name that differs only by case counts as the same name.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        var x = stat(), y = stat()
        guard lstat(a.path, &x) == 0, lstat(b.path, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// True when both paths lead to the same directory (links followed).
    static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        var x = stat(), y = stat()
        guard stat(a.path, &x) == 0, stat(b.path, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// Moves `from` to `to`. A destination that is already taken by another file throws `.exists` and
    /// nothing changes. The one allowed "taken" destination is the file's own name written with other
    /// letter case (case-insensitive volume), which is a rename of the same file.
    static func moveNoClobber(_ from: URL, to: URL) throws {
        if from.lastPathComponent != to.lastPathComponent, exists(to), isSameFile(from, to) {
            if rename(from.path, to.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        if renamex_np(from.path, to.path, renameExclusive) != 0 {
            let code = errno
            if code == EEXIST { throw FileOpsError.exists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Creates an empty file at `url`; throws `.exists` when the name is taken.
    static func createExclusive(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            let code = errno
            if code == EEXIST { throw FileOpsError.exists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        close(fd)
    }

    static func creationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    static func setCreationDate(_ date: Date?, of url: URL) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    }
}
