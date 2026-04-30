import Foundation
import SwiftUI

/// Pure-function formatters for note row title + preview. Extracted so
/// formatting can be unit-tested without SwiftUI view instantiation.
enum NoteRowFormatting {
    /// All meaningful lines in body order: non-empty, non-heading, with leading
    /// `- `/`* `/`> ` markers stripped (only when followed by whitespace, per IN-02).
    static func meaningfulLines(in body: String) -> [String] {
        var result: [String] = []
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
            result.append(stripped)
        }
        return result
    }

    static func firstMeaningfulLine(for body: String) -> String? {
        return meaningfulLines(in: body).first
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

    /// Preview — the line *after* whatever became the title.
    /// - Heading present: title is the heading, preview = first meaningful body line.
    /// - No heading: title is the first meaningful line, preview = the second.
    /// 50-char cap. Returns nil when there is no distinct preview line.
    static func preview(for body: String) -> String? {
        let lines = meaningfulLines(in: body)
        if HeadingExtractor.firstHeading(in: body) != nil {
            return lines.first.map { String($0.prefix(50)) }
        }
        guard lines.count >= 2 else { return nil }
        return String(lines[1].prefix(50))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(NoteRowFormatting.title(for: note.body))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let modified = note.modified {
                    Text(NoteRowFormatting.formattedModifiedTime(modified))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }

            if let preview = NoteRowFormatting.preview(for: note.body) {
                Text(preview)
                    .font(.system(size: 11))
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
