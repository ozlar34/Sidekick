import Foundation

/// The last selected note is remembered by filename: ids only live for one session.
enum SelectionMemory {
    static func restored(lastFilename: String, in notes: [Note]) -> UUID? {
        guard !lastFilename.isEmpty else { return nil }
        return notes.first { $0.filename == lastFilename }?.id
    }
}
