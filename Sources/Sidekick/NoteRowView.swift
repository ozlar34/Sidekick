import Foundation

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
