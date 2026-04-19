import AppKit
import SwiftUI

/// Markdown formatting toolbar shown below the TextEditor in edit mode.
/// Buttons call the `wrapSelection` closure (provided by EditorPaneView)
/// which bridges to NSTextView. All string manipulation logic is
/// extracted into `applyMarkdownWrap` (pure, unit-testable — no AppKit).
struct FormattingToolbarView: View {
    let wrapSelection: (String, String) -> Void
    let applyLinePrefix: () -> Void
    let togglePreview: () -> Void
    let isPreviewMode: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Preview toggle first so its x-position is stable across modes —
            // in preview mode the format buttons collapse away, and the
            // eye/pencil stays fixed at the leading edge (feels like an
            // in-place toggle rather than a jumping icon).
            Button {
                togglePreview()
            } label: {
                // Eye glyph is visually wider than square.and.pencil at the
                // same font size — drop it by 2pt so both render at a
                // matching optical size, and pin a fixed frame so the
                // clickable bounds + x-position stay identical across modes.
                Image(systemName: isPreviewMode ? "square.and.pencil" : "eye")
                    .font(.system(size: isPreviewMode ? 13 : 11, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isPreviewMode ? "Back to edit mode (⌘⇧P)" : "Preview (⌘⇧P)")

            // Format buttons only work when the TextEditor is in the responder
            // chain — hide them in preview mode to avoid dead clicks.
            if !isPreviewMode {
                Button {
                    wrapSelection("**", "**")
                } label: {
                    Image(systemName: "bold")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Bold (⌘B)")

                Button {
                    wrapSelection("*", "*")
                } label: {
                    Image(systemName: "italic")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Italic (⌘I)")

                Button {
                    wrapSelection("`", "`")
                } label: {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Inline code (⌘⌥C)")

                Button {
                    wrapSelection("[", "]()")
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Link (⌘K)")

                Button {
                    applyLinePrefix()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Bulleted list (⌘⇧8)")
            }

            Spacer()
        }
    }

    /// Pure string transformation: insert or wrap markdown markers around
    /// the specified range. Returns the new body plus the cursor location
    /// (UTF-16 units, 0-length selection) where the NSTextView should
    /// place the caret after the insert.
    ///
    /// - With a non-empty selection: wraps with `prefix + selected + suffix`;
    ///   cursor lands after the inserted suffix (range.location + prefix + selection + suffix).
    /// - With an empty selection: inserts `prefix + suffix` and places the
    ///   cursor between them (range.location + prefix.utf16.count). Exception:
    ///   if prefix ends with `[` (link case), still use prefix.utf16.count so
    ///   the cursor lands inside the brackets for link-text entry.
    ///
    /// `body` is treated as NSString for range arithmetic — all offsets are
    /// UTF-16 code units to match NSRange semantics (PreviewToggleTests pins
    /// the same UTF-16 contract for cursor offsets elsewhere in the app).
    internal static func applyMarkdownWrap(
        prefix: String,
        suffix: String,
        body: String,
        range: NSRange
    ) -> (newBody: String, cursorLocation: Int) {
        let nsBody = body as NSString
        // Clamp range defensively — inputs from NSTextView are trusted
        // in production but tests may pass sub-optimal ranges.
        let safeLocation = max(0, min(range.location, nsBody.length))
        let safeLength = max(0, min(range.length, nsBody.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let selected = safeLength > 0 ? nsBody.substring(with: safeRange) : ""
        let insert: String
        let cursor: Int
        if selected.isEmpty {
            insert = prefix + suffix
            cursor = safeLocation + (prefix as NSString).length
        } else {
            insert = prefix + selected + suffix
            cursor = safeLocation + (insert as NSString).length
        }
        let newBody = nsBody.replacingCharacters(in: safeRange, with: insert)
        return (newBody, cursor)
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

    /// Applies markdown wrap directly on an NSTextView using AppKit's edit
    /// sandwich: `shouldChangeText` → `replaceCharacters` → `didChangeText`.
    /// This registers the change on the text view's own `undoManager`
    /// automatically — no manual `UndoManager.registerUndo` is needed.
    ///
    /// Called from two paths (D-R-03):
    ///   1. `EditorPaneView.wrapSelection(prefix:suffix:)` — toolbar button taps.
    ///   2. `AppDelegate.formatBold(_:)` / `formatItalic(_:)` / `formatInlineCode(_:)`
    ///      / `formatLink(_:)` — menu actions (Plan 04 wires these).
    ///
    /// The edit is applied to the SELECTION range only (not the full body —
    /// RESEARCH Code Examples refinement). The cursor location returned by
    /// `applyMarkdownWrap` is computed against the full body and is used
    /// verbatim for `setSelectedRange`.
    ///
    /// Pattern source: NSTextView documentation (shouldChangeText /
    /// replaceCharacters / didChangeText) + christiantietze.de/posts/2022/09/
    /// undoable-text-changes (the sandwich is the canonical Apple pattern for
    /// programmatic edits that participate in the NSTextView undo stack).
    static func performWrap(prefix: String, suffix: String, in textView: NSTextView) {
        let body = textView.string
        let range = textView.selectedRange()
        let (_, cursor) = applyMarkdownWrap(
            prefix: prefix,
            suffix: suffix,
            body: body,
            range: range
        )

        // Build the replacement for the SELECTION range only.
        let inserted: String
        if range.length == 0 {
            inserted = prefix + suffix
        } else {
            let selected = (body as NSString).substring(with: range)
            inserted = prefix + selected + suffix
        }

        // Edit sandwich — registers undo on textView.undoManager automatically.
        guard textView.shouldChangeText(in: range, replacementString: inserted) else { return }
        textView.replaceCharacters(in: range, with: inserted)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
    }

    /// Applies a line-prefix toggle (bulleted list) directly on an NSTextView,
    /// using the same edit-sandwich pattern as `performWrap`:
    /// `shouldChangeText` → `replaceCharacters` → `didChangeText`. Undo
    /// registers on `textView.undoManager` automatically (no manual
    /// `registerUndo` call).
    ///
    /// Called from two paths (mirrors `performWrap` — D-R-03):
    ///   1. `EditorPaneView.applyLinePrefix()` — toolbar button taps.
    ///      (Note: the toolbar path uses the $localBody mutation instead,
    ///      for the same SwiftUI-source-of-truth reason as wrapSelection.
    ///      Only the MENU path calls `performLinePrefix` directly.)
    ///   2. `AppDelegate.formatBulletedList(_:)` — ⌘⇧8 menu action.
    ///
    /// Edits only the line-block range (lineRange(for: selection)), not the
    /// full body. The caret/selection restore mirrors `performWrap`: for an
    /// empty selection on a single transformed line, the caret lands
    /// immediately after the inserted `"- "` so the user can start typing
    /// the bullet content. For multi-line or non-empty selection, the whole
    /// transformed block is re-selected so the next ⌘⇧8 can toggle it off.
    static func performLinePrefix(in textView: NSTextView) {
        let body = textView.string
        let range = textView.selectedRange()
        let (fullNewBody, _) = applyBulletedList(body: body, range: range)

        let nsBody = body as NSString
        let blockRange = nsBody.lineRange(for: range)

        // Extract the replacement block from fullNewBody at the same start
        // offset. blockRange.location is unchanged by the transform (the
        // edit is local to the block); the new block's length is the old
        // block's length plus the delta in total body length.
        let deltaLength = (fullNewBody as NSString).length - nsBody.length
        let newBlockLength = blockRange.length + deltaLength
        let newBlock = (fullNewBody as NSString).substring(
            with: NSRange(location: blockRange.location, length: newBlockLength)
        )

        // Edit sandwich — registers undo on textView.undoManager automatically.
        guard textView.shouldChangeText(in: blockRange, replacementString: newBlock) else { return }
        textView.replaceCharacters(in: blockRange, with: newBlock)
        textView.didChangeText()

        // Caret / selection restore:
        //   - Empty selection AND single-line result → caret AFTER the "- "
        //     (add mode) or at line start (strip mode). Detect by length
        //     delta: positive → we added "- " → caret at location + 2.
        //   - Otherwise → re-select the full transformed block.
        if range.length == 0, !newBlock.contains("\n") {
            let caretOffset = deltaLength > 0 ? 2 : 0
            textView.setSelectedRange(
                NSRange(location: blockRange.location + max(0, caretOffset), length: 0)
            )
        } else {
            textView.setSelectedRange(
                NSRange(location: blockRange.location, length: (newBlock as NSString).length)
            )
        }
    }
}
