/// `FormattingToolbarView` — LinePrefix detection and the pure string transforms for block formats
/// (bulleted list, heading level, numbered list, blockquote, checklist).

import AppKit
import SwiftUI

extension FormattingToolbarView {

    /// Line-prefix block format of the caret's line. Drives the popover
    /// active-state highlight for the four list-shape rows. Mutually
    /// exclusive — a line is either bulleted, numbered, a checklist, a
    /// blockquote, or none of these. Headings are NOT included here; they
    /// have their own publisher (`activeHeadingLevel`).
    internal enum LinePrefix { case bullet, numbered, checklist, blockquote }

    /// Classify the line containing the caret. Single-line scan over the
    /// recognized prefixes — cheaper than re-running the full parser for
    /// what is purely a UI hint. Mirrors the `updateActiveHeadingLevel`
    /// pattern in HybridEditorView.Coordinator.
    ///
    /// Order matters: checklist (`- [ ] ` / `- [x] `) is detected before
    /// bullet (`- `), since the checklist prefix begins with a bullet
    /// prefix and the more-specific match wins.
    internal static func activeLinePrefix(body: String, selection: NSRange) -> LinePrefix? {
        let nsBody = body as NSString
        guard selection.location >= 0,
              selection.location <= nsBody.length else { return nil }
        let probe = NSRange(location: min(selection.location, nsBody.length), length: 0)
        let lineRange = nsBody.lineRange(for: probe)
        let line = nsBody.substring(with: lineRange) as NSString

        // Checklist: `- [ ] ` or `- [x] ` / `- [X] `
        if line.length >= 6,
           line.character(at: 0) == 0x2D,   // '-'
           line.character(at: 1) == 0x20,   // ' '
           line.character(at: 2) == 0x5B,   // '['
           line.character(at: 4) == 0x5D,   // ']'
           line.character(at: 5) == 0x20 {  // ' '
            let state = line.character(at: 3)
            if state == 0x20 || state == 0x78 || state == 0x58 {
                return .checklist
            }
        }

        // Bullet: `- ` or `* `
        if line.length >= 2,
           (line.character(at: 0) == 0x2D || line.character(at: 0) == 0x2A),
           line.character(at: 1) == 0x20 {
            return .bullet
        }

        // Numbered: `<digits>+. `
        var i = 0
        while i < line.length, line.character(at: i) >= 0x30, line.character(at: i) <= 0x39 {
            i += 1
        }
        if i > 0,
           i + 1 < line.length,
           line.character(at: i) == 0x2E,       // '.'
           line.character(at: i + 1) == 0x20 {  // ' '
            return .numbered
        }

        // Blockquote: `> `
        if line.length >= 2,
           line.character(at: 0) == 0x3E,   // '>'
           line.character(at: 1) == 0x20 {
            return .blockquote
        }

        return nil
    }

    /// Pure string transformation: toggles a `"- "` prefix on every line in
    /// the block containing `range`. Mirrors the Apple Notes / Bear
    /// convention: if every non-empty line in the expanded block already
    /// starts with `"- "`, the prefix is stripped from each line
    /// (toggle off). Otherwise — mixed or no prefixes — `"- "` is prepended
    /// to EVERY line in the block, including empty lines (an empty bullet
    /// `"- "` is a real thing in Notes).
    ///
    /// - Returns `newBody` and `newSelection` (NSRange) covering the
    ///   transformed line block. Callers re-select the block so the user
    ///   can hit ⌘⇧8 again to toggle off.
    ///
    /// UTF-16 discipline (same as `applyMarkdownWrap`): `body` is treated as
    /// NSString; lineRange(for:) returns UTF-16 spans that include the
    /// trailing `\n` (or end-of-string when the final line has no newline).
    ///
    /// Empty selection (`range.length == 0`) still works — `lineRange(for:)`
    /// returns the enclosing line's span, so the caret's x-position doesn't
    /// affect where the prefix lands (it's always line-start).
    internal static func applyBulletedList(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString

        // Clamp defensively — mirrors applyMarkdownWrap's safe-range pattern.
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        // Expand to line-block bounds. lineRange(for:) returns the NSRange
        // covering full lines, including any trailing "\n".
        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)

        // Preserve trailing newline on rejoin if the block ends with one.
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        // Split lines. components(separatedBy:) yields a trailing "" when
        // the string ends with "\n" — we handle that explicitly on rejoin.
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Determine mode: all non-empty lines prefixed → strip; otherwise add.
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { ($0 as NSString).hasPrefix("- ") }

        let transformed: [String]
        if allPrefixed {
            // Strip mode: drop leading "- " (2 UTF-16 units) from each
            // non-empty line. Empty lines stay untouched.
            transformed = lines.map { line -> String in
                let ns = line as NSString
                if ns.hasPrefix("- ") {
                    return ns.substring(from: 2)
                }
                return line
            }
        } else {
            // Add mode: prepend "- " to EVERY line (including empties —
            // consistent with Apple Notes behavior).
            transformed = lines.map { "- " + $0 }
        }

        // Rejoin, preserving the trailing newline if the original had one.
        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: applies, swaps, or strips a heading
    /// prefix (`# `, `## `, `### `, …) on every line in the block containing
    /// `range`. Mirrors `applyBulletedList`'s shape: line-block expansion,
    /// per-line prefix manipulation, toggle-off on re-pick.
    ///
    /// - `level`: `nil` → strip any heading prefix from every line (force
    ///   Body). `1…6` → apply that heading level to every line.
    /// - **Toggle rule**: if `level != nil` AND every non-empty line in the
    ///   expanded block already has exactly that level, the call is treated
    ///   as `level = nil` (strip → Body). This mirrors the bullet toggle
    ///   convention and lets ⌘⌥2 on an H2 line strip back to body.
    /// - Existing heading prefixes are stripped before the new prefix is
    ///   prepended, so applying H1 to an H2 line produces an H1 line (level
    ///   swap, not stacked hashes).
    /// - Empty lines: when applying a level, an empty line still gets the
    ///   prefix (consistent with bullet behaviour — an empty heading line
    ///   `"## "` is a real thing). When stripping, empty lines stay empty.
    ///
    /// Returns `newBody` and `newSelection` (NSRange) covering the
    /// transformed line block. Callers re-select the block so a follow-up
    /// shortcut press can toggle it off cleanly.
    internal static func applyHeadingLevel(
        body: String,
        range: NSRange,
        level: Int?
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString

        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let requestedLevel: Int?
        if let lvl = level, lvl >= 1, lvl <= 6 {
            requestedLevel = lvl
        } else {
            requestedLevel = nil
        }

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Returns (level, prefixLength) for a line whose first chars are
        // 1–6 `#` followed by a single space; nil otherwise. Single-line
        // scan is cheaper than re-running the full parser per line.
        func headingPrefix(of line: String) -> (level: Int, prefixLen: Int)? {
            let ns = line as NSString
            var hashes = 0
            while hashes < ns.length, ns.character(at: hashes) == 0x23 /* # */ {
                hashes += 1
            }
            guard hashes >= 1, hashes <= 6,
                  hashes < ns.length, ns.character(at: hashes) == 0x20 /* space */
            else { return nil }
            return (hashes, hashes + 1)
        }

        // Toggle detection — only triggers when the caller specified a level.
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let effectiveLevel: Int?
        if let lvl = requestedLevel,
           !nonEmptyLines.isEmpty,
           nonEmptyLines.allSatisfy({ headingPrefix(of: $0)?.level == lvl }) {
            effectiveLevel = nil
        } else {
            effectiveLevel = requestedLevel
        }

        let newPrefix: String = effectiveLevel.map { String(repeating: "#", count: $0) + " " } ?? ""

        let transformed: [String] = lines.map { line in
            let stripped: String
            if let h = headingPrefix(of: line) {
                stripped = (line as NSString).substring(from: h.prefixLen)
            } else {
                stripped = line
            }
            if effectiveLevel == nil {
                return stripped
            }
            return newPrefix + stripped
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: toggles a numbered-list prefix (`1. `,
    /// `2. `, … sequentially per line, restarting at 1 across the block) on
    /// every line in the block containing `range`. Mirrors `applyBulletedList`
    /// exactly: line-block expansion, all-prefixed-toggle-off rule, UTF-16
    /// discipline. The "all prefixed" check accepts any `<digits>+. ` prefix
    /// (so a hand-edited `5. foo\n7. bar` block still toggles off cleanly).
    /// On add, any pre-existing numeric prefix is stripped first and the
    /// block is re-numbered from 1 — guarantees readable raw markdown.
    internal static func applyNumberedList(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Returns prefix length if the line starts with `<digits>+. `; nil
        // otherwise. Single-line scan — cheaper than a NSRegularExpression.
        func numberedPrefixLen(of line: String) -> Int? {
            let ns = line as NSString
            var i = 0
            while i < ns.length, ns.character(at: i) >= 0x30 /* 0 */, ns.character(at: i) <= 0x39 /* 9 */ {
                i += 1
            }
            guard i > 0,
                  i + 1 < ns.length,
                  ns.character(at: i) == 0x2E /* . */,
                  ns.character(at: i + 1) == 0x20 /* space */
            else { return nil }
            return i + 2
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { numberedPrefixLen(of: $0) != nil }

        let transformed: [String]
        if allPrefixed {
            transformed = lines.map { line -> String in
                if let p = numberedPrefixLen(of: line) {
                    return (line as NSString).substring(from: p)
                }
                return line
            }
        } else {
            // Add mode: strip any existing numeric prefix, re-number from 1.
            var counter = 1
            transformed = lines.map { line -> String in
                let stripped: String
                if let p = numberedPrefixLen(of: line) {
                    stripped = (line as NSString).substring(from: p)
                } else {
                    stripped = line
                }
                let prefix = "\(counter). "
                counter += 1
                return prefix + stripped
            }
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: toggles a `"> "` prefix on every line in
    /// the block containing `range`. Mirrors `applyBulletedList` exactly with
    /// `"> "` instead of `"- "` — same line-block expansion, same toggle rule.
    internal static func applyBlockQuote(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { ($0 as NSString).hasPrefix("> ") }

        let transformed: [String]
        if allPrefixed {
            transformed = lines.map { line -> String in
                let ns = line as NSString
                if ns.hasPrefix("> ") {
                    return ns.substring(from: 2)
                }
                return line
            }
        } else {
            transformed = lines.map { "> " + $0 }
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }

    /// Pure string transformation: toggles a GFM task-list prefix
    /// (`- [ ] `) on every line in the block containing `range`. Mirrors
    /// `applyBulletedList` exactly — line-block expansion, all-prefixed-
    /// toggle-off rule, UTF-16 discipline. Both unchecked (`- [ ] `) and
    /// checked (`- [x] ` / `- [X] `) prefixes count as "prefixed" for the
    /// toggle-off check, so flipping a partially-completed list off works.
    /// On add, an unchecked `- [ ] ` prefix is prepended to every line
    /// (including empties — a blank task line is real).
    internal static func applyChecklist(
        body: String,
        range: NSRange
    ) -> (newBody: String, newSelection: NSRange) {
        let nsBody = body as NSString
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let blockRange = nsBody.lineRange(for: safeRange)
        let blockSubstring = nsBody.substring(with: blockRange)
        let endsWithNewline = blockSubstring.hasSuffix("\n")
        var lines = blockSubstring.components(separatedBy: "\n")
        let trailingEmpty: Bool
        if endsWithNewline, let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailingEmpty = true
        } else {
            trailingEmpty = false
        }

        // Returns the prefix length (always 6) if the line starts with a GFM
        // task-list prefix, nil otherwise. Single-line scan — cheaper than
        // running NSRegularExpression per line.
        func checklistPrefixLen(of line: String) -> Int? {
            let ns = line as NSString
            guard ns.length >= 6 else { return nil }
            // `- [` → first 3 chars
            if ns.character(at: 0) != 0x2D /* - */ { return nil }
            if ns.character(at: 1) != 0x20 /* space */ { return nil }
            if ns.character(at: 2) != 0x5B /* [ */ { return nil }
            let state = ns.character(at: 3)
            // space, x, or X
            guard state == 0x20 || state == 0x78 || state == 0x58 else { return nil }
            if ns.character(at: 4) != 0x5D /* ] */ { return nil }
            if ns.character(at: 5) != 0x20 /* space */ { return nil }
            return 6
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let allPrefixed = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { checklistPrefixLen(of: $0) != nil }

        let transformed: [String]
        if allPrefixed {
            transformed = lines.map { line -> String in
                if let p = checklistPrefixLen(of: line) {
                    return (line as NSString).substring(from: p)
                }
                return line
            }
        } else {
            // Add mode: `- [ ] ` prepended to every line, including empties.
            transformed = lines.map { "- [ ] " + $0 }
        }

        var newBlock = transformed.joined(separator: "\n")
        if trailingEmpty {
            newBlock += "\n"
        }

        let newBody = nsBody.replacingCharacters(in: blockRange, with: newBlock)
        let newSelection = NSRange(
            location: blockRange.location,
            length: (newBlock as NSString).length
        )
        return (newBody, newSelection)
    }
}
