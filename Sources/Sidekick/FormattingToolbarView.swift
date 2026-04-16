import AppKit
import SwiftUI

/// Markdown formatting toolbar shown below the TextEditor in edit mode.
/// Buttons call the `wrapSelection` closure (provided by EditorPaneView)
/// which bridges to NSTextView. All string manipulation logic is
/// extracted into `applyMarkdownWrap` (pure, unit-testable — no AppKit).
struct FormattingToolbarView: View {
    let wrapSelection: (String, String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                wrapSelection("**", "**")
            } label: {
                Image(systemName: "bold")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Bold (⌘B)")
            .keyboardShortcut("b", modifiers: .command)

            Button {
                wrapSelection("*", "*")
            } label: {
                Image(systemName: "italic")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Italic (⌘I)")
            .keyboardShortcut("i", modifiers: .command)

            Button {
                wrapSelection("`", "`")
            } label: {
                Image(systemName: "curlybraces")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Inline code (⌘⌥C)")
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button {
                wrapSelection("[", "]()")
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Link (⌘K)")
            .keyboardShortcut("k", modifiers: .command)

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
}
