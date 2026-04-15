/// Finds the first `# ` or `## ` line in a markdown body.
///
/// Pattern source: RESEARCH.md §Pattern 4 (Heading extraction)
///
/// Known limitation: false-positive on `#` lines inside fenced code blocks
/// (acceptable for Phase 2 per RESEARCH.md edge cases).
import Foundation

enum HeadingExtractor {
    static func firstHeading(in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("# ") {
                return String(stripped.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if stripped.hasPrefix("## ") {
                return String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
