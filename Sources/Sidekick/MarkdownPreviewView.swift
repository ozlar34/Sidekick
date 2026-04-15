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
            Markdown(content)
                .markdownTheme(.sidekick)
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
}
