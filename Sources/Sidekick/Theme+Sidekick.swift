import MarkdownUI
import SwiftUI

/// Native macOS theme for swift-markdown-ui rendering inside Sidekick.
/// Per CONTEXT D-01: system fonts (.body / .headline scale), tight line
/// height, system accent color for links. All colors use SwiftUI semantic
/// tokens (.primary, .accentColor, .separatorColor) that adapt to system
/// appearance automatically — satisfies EDIT-03 dark-mode requirement.
extension Theme {
    static let sidekick = Theme()
        .text {
            ForegroundColor(.primary)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(.accentColor)
            UnderlineStyle(.single)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color(.separatorColor).opacity(0.15))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 16, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.5))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 12)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.2))
        }
        .codeBlock { configuration in
            configuration.label
                .padding(8)
                .background(Color(.separatorColor).opacity(0.1))
                .cornerRadius(6)
        }
}
