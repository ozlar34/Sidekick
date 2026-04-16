import Foundation
import SwiftUI

/// Pure-function formatters for note row title + preview. Extracted so
/// formatting can be unit-tested without SwiftUI view instantiation.
enum NoteRowFormatting {
    static func title(for body: String) -> String {
        HeadingExtractor.firstHeading(in: body) ?? "Untitled"
    }

    static func preview(for body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") { continue }
            // IN-02: only strip list/quote prefix when the token is followed
            // by whitespace. `drop(while:)` on "-*>" characters would turn
            // `-42 is the answer` into `42 is the answer`; real markdown
            // bullets/quotes always include a trailing space.
            let stripped: String
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("> ") {
                stripped = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else {
                stripped = trimmed
            }
            guard !stripped.isEmpty else { continue }
            return String(stripped.prefix(50))
        }
        return nil
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
