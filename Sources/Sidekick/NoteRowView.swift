import Foundation
import SwiftUI

/// Pure-function formatters for note row title + preview. Extracted so
/// formatting can be unit-tested without SwiftUI view instantiation.
enum NoteRowFormatting {
    /// G-04: First non-empty, non-heading, whitespace-guarded-bullet-stripped line.
    /// Shared between title() (cap 80) and preview() (cap 50). No cap applied here —
    /// callers handle their own truncation.
    /// IN-02 rule: only strip `- `, `* `, `> ` when followed by whitespace.
    static func firstMeaningfulLine(for body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") { continue }
            let stripped: String
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("> ") {
                stripped = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else {
                stripped = trimmed
            }
            guard !stripped.isEmpty else { continue }
            return stripped
        }
        return nil
    }

    /// G-04: Title derivation chain —
    ///   firstHeading → firstMeaningfulLine → "Untitled"
    /// Cap at 80 chars (SwiftUI .lineLimit(1).truncationMode(.tail) further truncates visually,
    /// but the 80-char hard cap avoids pathological thousand-character single-line bodies).
    static func title(for body: String) -> String {
        if let heading = HeadingExtractor.firstHeading(in: body) {
            return String(heading.prefix(80))
        }
        if let line = firstMeaningfulLine(for: body) {
            return String(line.prefix(80))
        }
        return "Untitled"
    }

    /// Preview line — consumes firstMeaningfulLine, applies 50-char cap.
    static func preview(for body: String) -> String? {
        guard let line = firstMeaningfulLine(for: body) else { return nil }
        return String(line.prefix(50))
    }

    /// G-03: Successor-selection rule for post-delete reassignment.
    /// - Returns: next note's id if the deleted note is not last; previous note's
    ///   id if the deleted note was last; nil if the deleted note was the only
    ///   one OR not in the list.
    static func successorID(afterDeleting id: UUID, in notes: [Note]) -> UUID? {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return nil }
        guard notes.count > 1 else { return nil }
        if idx < notes.count - 1 { return notes[idx + 1].id }
        return notes[idx - 1].id
    }
}

struct NoteRowView: View {
    let note: Note
    @ObservedObject var store: NoteStore
    @Binding var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NoteRowFormatting.title(for: note.body))
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let preview = NoteRowFormatting.preview(for: note.body) {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if note.pinned {
                Button("Unpin") {
                    Task { try? await store.setPinned(note.id, false) }
                }
            } else {
                Button("Pin") {
                    Task { try? await store.setPinned(note.id, true) }
                }
            }
            Button("Delete", role: .destructive) {
                // G-03: compute successor from the CURRENT snapshot. store.notes is
                // @MainActor + @Published; we read it synchronously here on the main
                // thread before the async delete mutates it.
                let successor = NoteRowFormatting.successorID(afterDeleting: note.id, in: store.notes)
                Task {
                    try? await store.delete(note.id)
                    await MainActor.run { selectedID = successor }
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Regular") {
    let note = Note(
        id: UUID(),
        filename: "example.md",
        body: "Sample note body for the regular state preview.",
        pinned: false,
        order: 0
    )
    let store = PreviewFixtures.makeStore(notes: [note])
    return NoteRowView(note: note, store: store, selectedID: .constant(nil))
        .frame(width: 220)
}

#Preview("Pinned") {
    let note = PreviewFixtures.pinnedNote()
    let store = PreviewFixtures.makeStore(notes: [note])
    return NoteRowView(note: note, store: store, selectedID: .constant(note.id))
        .frame(width: 220)
}

#Preview("Long title (truncated)") {
    let note = PreviewFixtures.longTitleNote()
    let store = PreviewFixtures.makeStore(notes: [note])
    return NoteRowView(note: note, store: store, selectedID: .constant(nil))
        .frame(width: 220)
}
#endif
