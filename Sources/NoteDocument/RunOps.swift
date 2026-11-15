import Foundation

/// Run-level helpers behind the text and mark edits. Offsets are UTF-16 units of the joined run texts.
enum RunOps {
    /// Splits runs so that `offset` (clamped) lies on a run boundary and returns that boundary's index.
    /// A pill is not split: an offset inside it goes to its start, or to its end with `snapUp`.
    /// An offset inside a surrogate pair goes down to the scalar start, or up to its end with `snapUp`.
    static func boundary(_ runs: inout [Run], _ offset: Int, snapUp: Bool) -> Int {
        var pos = 0
        let target = max(0, offset)
        for k in runs.indices {
            let len = runs[k].text.utf16.count
            if target <= pos { return k }
            if target < pos + len {
                if runs[k].pill != nil { return snapUp ? k + 1 : k }
                var n = target - pos
                let text = runs[k].text
                var index = text.utf16.index(text.utf16.startIndex, offsetBy: n)
                while index.samePosition(in: text.unicodeScalars) == nil { n += snapUp ? 1 : -1; index = text.utf16.index(text.utf16.startIndex, offsetBy: n) }
                if n == 0 { return k }
                if n == len { return k + 1 }
                let split = index.samePosition(in: text.unicodeScalars)!
                var tail = runs[k]
                tail.text = String(text.unicodeScalars[split...])
                runs[k].text = String(text.unicodeScalars[..<split])
                runs.insert(tail, at: k + 1)
                return k + 1
            }
            pos += len
        }
        return runs.count
    }

    /// Run index range covering `range`.
    static func span(_ runs: inout [Run], _ range: Range<Int>) -> (Int, Int) {
        let lo = boundary(&runs, range.lowerBound, snapUp: false)
        let hi = boundary(&runs, range.upperBound, snapUp: true)
        return (lo, max(lo, hi))
    }

    /// The run for text typed between two neighbours: marks of the one before (else after); a link only inside a
    /// link; never a pill.
    static func typed(_ text: String, between before: Run?, and after: Run?) -> Run {
        var r = before ?? after ?? Run("")
        r.text = text
        r.pill = nil
        if let b = before, let a = after, let bl = b.link, let al = a.link, bl == al { r.link = bl } else { r.link = nil }
        return r
    }

    static func apply(_ mark: Mark, setting: Bool, to r: inout Run, bold: BoldDelimiter, italic: ItalicDelimiter) {
        switch mark {
        case .code:
            if setting { r = Run(r.text, code: true) } else { r.code = false }
        case .bold:
            if setting { if !r.code { r.bold = bold } } else { r.bold = nil }
        case .italic:
            if setting { if !r.code { r.italic = italic } } else { r.italic = nil }
        case .underline:
            if setting { if !r.code { r.underline = true } } else { r.underline = false }
        case .strikethrough:
            if setting { if !r.code { r.strikethrough = true } } else { r.strikethrough = false }
        case .link(let url):
            if setting { if !r.code { r.pill = nil; r.link = url } }
            else { r.link = nil; if r.pill == .link { r.pill = nil } }
        }
    }
}
