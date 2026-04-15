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
            let stripped = trimmed
                .drop(while: { "-*>".contains($0) })
                .trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            return String(stripped.prefix(50))
        }
        return nil
    }
}

struct NoteRowView: View {
    let note: Note
    @ObservedObject var store: NoteStore

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
        }
    }
}
