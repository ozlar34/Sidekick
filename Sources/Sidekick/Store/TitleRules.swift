import Foundation

/// The note's title is its filename without ".md". These rules turn what the user typed into a name.
///
/// Replaced: `/` and `:` (not allowed in a Finder name), control characters and line breaks. Dropped at
/// the ends: whitespace, leading dots (the file would be hidden and vanish from the list) and trailing
/// dots. An empty result is "Untitled". Names stay under 200 UTF-8 bytes so ".md" and a number suffix
/// fit inside the 255-byte limit.
enum TitleRules {
    static let untitled = "Untitled"
    static let maxBytes = 200

    static func fileBase(forTitle title: String) -> String {
        let replaced = String(String.UnicodeScalarView(title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar == "/" || scalar == ":" || isControl(scalar) { return "-" }
            return scalar
        }))
        var base = trimmed(replaced)
        if base.utf8.count > maxBytes {
            var cut = ""
            for ch in base {
                if cut.utf8.count + String(ch).utf8.count > maxBytes { break }
                cut.append(ch)
            }
            base = trimmed(cut)
        }
        return base.isEmpty ? untitled : base
    }

    /// "Untitled", "Untitled 2", ...: the names a new note gets, which the title field offers for renaming.
    static func isPlaceholder(_ title: String) -> Bool {
        title == untitled || (title.hasPrefix(untitled + " ") && Int(title.dropFirst(untitled.count + 1)) != nil)
    }

    /// "Name", then "Name 2", "Name 3" ...
    static func candidate(base: String, number: Int) -> String { number <= 1 ? base : "\(base) \(number)" }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || (0x7F...0x9F).contains(s.value) || s.value == 0x2028 || s.value == 0x2029
    }

    private static func trimmed(_ s: String) -> String {
        var scalars = Substring(s)
        while let first = scalars.unicodeScalars.first, first == "." || CharacterSet.whitespaces.contains(first) { scalars = scalars.dropFirst() }
        while let last = scalars.unicodeScalars.last, last == "." || CharacterSet.whitespaces.contains(last) { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
