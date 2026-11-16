import Foundation

/// The flattened grid of a table block: cells of a row are joined by a tab, rows by U+2028 (a line separator,
/// so that a text view keeps the whole table in one paragraph). Cells are runs; a cell holds no tab or U+2028.
enum Table {
    static let cellSeparator = "\t"
    static let rowSeparator = "\u{2028}"

    /// Splits flattened runs into rows of cells. Always at least one row with one cell.
    static func rows(from runs: [Run]) -> [[[Run]]] {
        var rows: [[[Run]]] = [[[]]]
        for run in runs {
            if run.pill != nil { rows[rows.count - 1][rows[rows.count - 1].count - 1].append(run); continue }
            var piece = String.UnicodeScalarView()
            func flush() {
                guard !piece.isEmpty else { return }
                var r = run; r.text = String(piece)
                rows[rows.count - 1][rows[rows.count - 1].count - 1].append(r)
                piece = .init()
            }
            for c in run.text.unicodeScalars {
                if c == "\t" { flush(); rows[rows.count - 1].append([]) }
                else if c == "\u{2028}" { flush(); rows.append([[]]) }
                else { piece.append(c) }
            }
            flush()
        }
        return rows
    }

    /// Flattens rows of cells back into runs.
    static func flatten(_ rows: [[[Run]]]) -> [Run] {
        var out: [Run] = []
        for (r, row) in rows.enumerated() {
            if r > 0 { out.append(Run(rowSeparator)) }
            for (c, cell) in row.enumerated() {
                if c > 0 { out.append(Run(cellSeparator)) }
                out += cell
            }
        }
        return out
    }

    /// The text of one cell as written between two pipes: inline text with `|` escaped.
    static func cellText(_ runs: [Run]) -> String {
        // By scalar: a `|` followed by a combining mark is one Character that a string search would not find.
        var out = String.UnicodeScalarView()
        for c in InlineWriter.write(runs, kind: .table).unicodeScalars {
            if c == "|" { out.append("\\") }
            out.append(c)
        }
        return String(out)
    }

    /// The runs of one cell as the reader gets them from the text between two pipes (blanks at its edges are not
    /// part of the cell; a tab or line separator inside it becomes a blank, as it would split the flat form).
    static func readCell(_ text: String) -> [Run] {
        guard let cells = BlockSyntax.rowCells(Array(("|" + text).unicodeScalars)), let cell = cells.first else { return [] }
        return readCell(cell)
    }

    static func readCell(_ cell: [Unicode.Scalar]) -> [Run] {
        var s = cell[...]
        while let f = s.first, BlockSyntax.isBlank(f) { s = s.dropFirst() }
        while let l = s.last, BlockSyntax.isBlank(l) { s = s.dropLast() }
        return InlineReader.read(s.map { $0 == "\t" || $0 == "\u{2028}" ? " " : $0 })
    }

    /// Canonical form: every cell normalised like a line of text, blanks at the cell edges removed (the reader
    /// trims them), line breaks gone.
    static func normalize(_ input: [Run]) -> [Run] {
        let rows = rows(from: input).map { row in row.map(normalizeCell) }
        return Block.normalize(flatten(rows))
    }

    static func normalizeCell(_ cell: [Run]) -> [Run] {
        var runs = Block.normalize(cell.map { var r = $0; r.text = Run.stripLineBreaks(r.text); return r })
        func trimmed(_ r: Run, leading: Bool) -> Run? {
            guard r.hasNoMarks else { return nil }
            let s = r.text.unicodeScalars
            let t = leading ? String(s.drop(while: BlockSyntax.isBlank)) : String(String.UnicodeScalarView(s.reversed().drop(while: BlockSyntax.isBlank).reversed()))
            var out = r; out.text = t
            return out
        }
        if let first = runs.first, let t = trimmed(first, leading: true) { if t.text.isEmpty { runs.removeFirst() } else { runs[0] = t } }
        if let last = runs.last, let t = trimmed(last, leading: false) { if t.text.isEmpty { runs.removeLast() } else { runs[runs.count - 1] = t } }
        return runs
    }
}
