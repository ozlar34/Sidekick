/// Pure ASCII-slug pipeline: folds diacritics, strips non-alphanumerics,
/// collapses hyphens, caps at 80 chars, and resolves collisions via `-2`/`-3`.
///
/// Pattern sources:
///   - RESEARCH.md §Pattern 3 (Slug derivation pipeline)
///   - RESEARCH.md Pitfall 6 (Turkish `lowercased` trap → `en_US_POSIX`)
///
/// Empty input → returns `""`; caller must fall back to `untitled-{uuid8}`.
import Foundation

enum Slug {
    private static let maxLen = 80  // CONTEXT.md locks 80-char cap

    static func make(from heading: String, existing: Set<String>) -> String {
        // 1. fold diacritics: "Café" -> "Cafe"
        let folded = heading.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        // 2. lowercase, keep only ASCII alnum + separators → hyphens
        let mapped = folded.lowercased(with: Locale(identifier: "en_US_POSIX")).unicodeScalars.map { s -> Character in
            if s.isASCII, CharacterSet.alphanumerics.contains(s) { return Character(s) }
            return "-"
        }
        // 3. collapse runs of hyphens
        var out = ""
        var prevHyphen = false
        for ch in mapped {
            if ch == "-" {
                if prevHyphen { continue }
                prevHyphen = true
            } else {
                prevHyphen = false
            }
            out.append(ch)
        }
        // 4. trim leading/trailing hyphens, length cap
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var base = String(trimmed.prefix(maxLen))
        // re-trim if prefix landed on a hyphen
        while base.hasSuffix("-") { base.removeLast() }

        if base.isEmpty { return "" }  // caller falls back to untitled-{uuid8}

        // 5. collision: append -2, -3, ... (against `existing` which contains
        //    filenames WITHOUT .md extension, excluding the note being renamed)
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
