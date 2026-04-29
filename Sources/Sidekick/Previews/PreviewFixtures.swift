#if DEBUG
import Foundation

/// Preview fixture factories for Xcode Canvas previews.
/// All types in this file are excluded from Release builds via the
/// enclosing `#if DEBUG` gate. Do NOT add production code here.
///
/// Usage in a #Preview block:
///   let store = PreviewFixtures.makeStore(notes: PreviewFixtures.sampleNotes())
struct PreviewFixtures {

    // MARK: - Store factory

    /// Creates a NoteStore pointed at a unique per-call temp directory,
    /// seeded with the supplied notes array. No disk watcher is started.
    /// Each call gets its own UUID-scoped temp path — prevents cross-preview
    /// state bleed when Canvas re-renders multiple previews in parallel.
    @MainActor
    static func makeStore(notes: [Note] = []) -> NoteStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidekickPreview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true,
            attributes: nil
        )
        // Force-unwrap is intentional: if the DEBUG convenience init throws,
        // it means createDirectory failed on a writable temp path — a
        // programming error, not a recoverable runtime condition in previews.
        return try! NoteStore(folder: tmp, seededNotes: notes)
    }

    // MARK: - Note factories

    /// Two regular sample notes for the SidebarView "Populated" preview and
    /// NoteRowView "Regular" preview.
    static func sampleNotes() -> [Note] {
        [
            Note(
                id: UUID(),
                filename: "meeting-notes.md",
                body: "# Meeting Notes\nDiscussed Q2 roadmap and release timeline.",
                pinned: false,
                order: 0,
                modified: Date().addingTimeInterval(-3600)
            ),
            Note(
                id: UUID(),
                filename: "ideas.md",
                body: "Random ideas for the next project.\nA few more lines of brainstorming below.",
                pinned: false,
                order: 1,
                modified: Date().addingTimeInterval(-86400 * 2)
            )
        ]
    }

    /// A single pinned note for the NoteRowView "Pinned" preview.
    static func pinnedNote() -> Note {
        Note(
            id: UUID(),
            filename: "pinned.md",
            body: "# Pinned Note\nThis note is pinned to the top.",
            pinned: true,
            order: 0,
            modified: Date().addingTimeInterval(-86400 * 5)
        )
    }

    /// A note whose title will be visually truncated in NoteRowView —
    /// 120-character heading followed by a body line.
    static func longTitleNote() -> Note {
        let longHeading = "# " + String(repeating: "Long Title Word ", count: 8)
        return Note(
            id: UUID(),
            filename: "long-title.md",
            body: longHeading + "\nThis is the second line of the note body.",
            pinned: false,
            order: 0,
            modified: Date()
        )
    }
}
#endif
