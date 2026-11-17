import Foundation
import NoteDocument
import SwiftUI

/// Pure-function formatters for note row title + preview. Extracted so
/// formatting can be unit-tested without SwiftUI view instantiation.
enum NoteRowFormatting {
    /// The row's one-line preview: the first line of the note's text as the editor shows it (no markdown markers,
    /// a link by its label), skipping headings, dividers, code blocks and tables. Nil for a note without such a line.
    static func firstMeaningfulLine(for body: String) -> String? {
        for block in NoteDocument(markdown: body).blocks {
            switch block.kind {
            case .heading, .divider, .fence, .table: continue
            case .paragraph, .bullet, .numbered, .checklist, .quote:
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static let timeOfDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()

    /// Compact relative-modified label for sidebar rows. Apple-Notes / Mail-style:
    /// today → "10:34 AM"; yesterday → "Yesterday"; within 7 days → weekday name;
    /// this year → "Apr 15"; older → "Apr 15, 2024". `now` is injectable for tests.
    static func formattedModifiedTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            return timeOfDayFormatter.string(from: date)
        }
        if let yesterdayStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)),
           cal.isDate(date, inSameDayAs: yesterdayStart) {
            return "Yesterday"
        }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day,
           days >= 0 && days < 7 {
            return weekdayFormatter.string(from: date)
        }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return monthDayFormatter.string(from: date)
        }
        return monthDayYearFormatter.string(from: date)
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
    /// While searching: the note's first line that matches, shown under the title.
    var snippet: String? = nil

    @State private var isHovered = false

    private var isSelected: Bool { note.id == selectedID }

    /// The line under the title: the search snippet while searching, else the note's first line of text.
    private var detail: String? {
        snippet ?? NoteRowFormatting.firstMeaningfulLine(for: note.body)
    }

    private var time: String? {
        note.modified.map { NoteRowFormatting.formattedModifiedTime($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if note.pinned {
                    Spacer(minLength: 0)
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }

            // One line: the time, then the preview (or the search snippet), cut with "…".
            HStack(spacing: 6) {
                if let time {
                    Text(time)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(detail ?? "No additional text")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15)
                      : isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help(note.title.isEmpty ? "Untitled" : note.title)
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
        body: "Sample note body for the regular state preview.\nA second line that should appear in the preview area.",
        pinned: false,
        order: 0,
        modified: Date().addingTimeInterval(-3600)
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
