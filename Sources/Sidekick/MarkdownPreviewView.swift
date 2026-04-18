import AppKit
import MarkdownUI
import SwiftUI

/// Renders a markdown string using swift-markdown-ui with the `.sidekick`
/// theme. Background matches EditorPaneView (D-02: Color(.textBackgroundColor)).
/// Link taps open in the user's default browser via NSWorkspace (D-05).
/// Used by EditorPaneView when isPreviewMode == true (EDIT-02, EDIT-03).
struct MarkdownPreviewView: View {
    let content: String

    var body: some View {
        ScrollView {
            Markdown(displayContent)
                .markdownTheme(.sidekick)
                .font(.system(size: 16))  // match TextEditor base size; heading scales in theme are .em-relative
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    /// If the first non-empty line is plain prose (no existing markdown marker),
    /// render it as an H1. Edit mode stores the body unchanged — this transform
    /// only affects the preview output.
    private var displayContent: String {
        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return content
        }
        let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
        // Skip anything already starting with a markdown block marker.
        let markers: Set<Character> = ["#", "-", "*", ">", "`", "|", "+"]
        if let first = trimmed.first, markers.contains(first) { return content }
        // Skip ordered list pattern: "1." "2." etc.
        if let first = trimmed.first, first.isNumber,
           let dotIdx = trimmed.firstIndex(of: "."),
           trimmed.distance(from: trimmed.startIndex, to: dotIdx) <= 2 {
            return content
        }
        lines[idx] = "# " + lines[idx]
        return lines.joined(separator: "\n")
    }
}
