import AppKit

/// Web and mail addresses written as plain text (`google.com`, `www.x.org/path`, `melati.ge`, `a@b.com`). The note's
/// markdown has no link there, so they are found in the buffer, drawn like links and opened on Cmd+click. They are a
/// view of the text only: the buffer and the file never change.
enum NoteFoundLinks {
    struct Found: Equatable {
        var range: NSRange
        var address: String
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// A name with a two-letter country ending (`melati.ge`, `x.co.uk/p`), which the system detector misses for the less
    /// common endings. Not after a letter, digit, `.`, `@`, `/` or `-`, so it never starts inside another word or address.
    private static let countryDomain = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9.@/\-])(?:[A-Za-z0-9\-]+\.)+([A-Za-z]{2})(?![A-Za-z0-9\-])(?:/[^\s]*)?"#)

    /// Two-letter endings that are far more often file names (`README.md`, `main.py`) than addresses.
    private static let fileEndings: Set<String> = ["md", "py", "sh", "rs", "pl", "rb", "cs", "ts", "js", "db", "gz", "so", "mm"]

    /// Every address in the plain text of `storage`, in order. Text in a link, a pill or inline code is never one.
    static func find(in storage: NSAttributedString) -> [Found] {
        let text = storage.string as NSString
        let all = NSRange(location: 0, length: text.length)
        guard all.length > 0 else { return [] }
        var out: [Found] = []
        func taken(_ r: NSRange) -> Bool { out.contains { NSIntersectionRange($0.range, r).length > 0 } }

        for m in detector?.matches(in: storage.string, range: all) ?? [] {
            guard let url = m.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { continue }
            var address = url.absoluteString
            // Written without a scheme: open it over https, not the http the detector adds.
            if url.scheme == "http", !text.substring(with: m.range).lowercased().hasPrefix("http") {
                address = "https" + address.dropFirst(4)
            }
            out.append(Found(range: m.range, address: address))
        }
        for m in countryDomain?.matches(in: storage.string, range: all) ?? [] {
            let ending = text.substring(with: m.range(at: 1)).lowercased()
            var r = m.range
            while r.length > 0, ".,;:!?'\")".contains(text.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1))) { r.length -= 1 }
            guard !fileEndings.contains(ending), !taken(r) else { continue }
            out.append(Found(range: r, address: "https://" + text.substring(with: r)))
        }
        return out.filter { isPlain($0.range, in: storage) }.sorted { $0.range.location < $1.range.location }
    }

    /// True if no character in `range` is part of a link, a pill or inline code.
    private static func isPlain(_ range: NSRange, in storage: NSAttributedString) -> Bool {
        var plain = true
        storage.enumerateAttribute(.noteStyle, in: range, options: []) { value, _, stop in
            if let s = value as? NoteRunStyle, s.link != nil || s.pill != nil || s.code { plain = false; stop.pointee = true }
        }
        return plain
    }
}
