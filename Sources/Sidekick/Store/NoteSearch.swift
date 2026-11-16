import Foundation
import NoteDocument

/// Search across all notes. A note matches when every word of the query is in its title or its text; case and
/// accents do not count. The text is what the editor shows, not the markdown: a link matches by its label, not its
/// address, and markers such as `**` or `- [ ]` never match. Pure functions over the store's notes: no disk reads.
enum NoteSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The query's words. An empty list means "no search": show every note.
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The notes that match `query`, in their given order.
    static func matches(_ notes: [Note], query: String) -> [Note] {
        let terms = terms(query)
        guard !terms.isEmpty else { return notes }
        return notes.filter { note in
            let text = visibleLines(of: note).joined(separator: "\n")
            return terms.allSatisfy { contains(note.title, $0) || contains(text, $0) }
        }
    }

    /// The sidebar's search results: the matching notes, pinned ones first, each group in the store's order.
    static func results(_ notes: [Note], query: String) -> [Note] {
        matches(notes.filter(\.pinned) + notes.filter { !$0.pinned }, query: query)
    }

    /// The first line of the note's text that holds a query word; nil when only the title matches. A match far into
    /// the line starts the snippet a few words before it, after "…", so a one-line row still shows the match.
    static func snippet(for note: Note, query: String) -> String? {
        let terms = terms(query)
        guard !terms.isEmpty else { return nil }
        for line in visibleLines(of: note) {
            let hits = terms.compactMap { line.range(of: $0, options: options)?.lowerBound }
            guard let hit = hits.min() else { continue }
            guard line.distance(from: line.startIndex, to: hit) > snippetLead else { return line }
            // Back up `snippetLead` characters, then forward to the start of a word.
            let back = line.index(hit, offsetBy: -snippetLead)
            let wordStart = line[back..<hit].firstIndex(of: " ").map { line.index(after: $0) } ?? back
            return "…" + line[wordStart...]
        }
        return nil
    }

    /// How many characters of the line a snippet keeps before the match.
    private static let snippetLead = 16

    /// The text of each block as the editor shows it, without empty lines.
    private static func visibleLines(of note: Note) -> [String] {
        NoteDocument(markdown: note.body).blocks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: options) != nil
    }
}
