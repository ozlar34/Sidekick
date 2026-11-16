import AppKit
import Combine
import SwiftUI

/// Bridges the SwiftUI `EditorPaneView` to the AppKit `NoteTextView` inside `NoteEditorView`: it publishes the
/// text view upward (title field focus, Format menu target) and what the toolbar shows for the caret (the active
/// inline styles, heading level and block kind), which the text view pushes through `bindFormatState(to:)`.
///
/// `@StateObject`-owned by `EditorPaneView`, so a fresh instance exists each time the pane mounts.
@MainActor
final class EditorController: ObservableObject {
    /// The editor's text view, written once in `NoteEditorView.makeNSView`. `weak`: the scroll view owns it.
    weak var textView: NoteTextView? {
        willSet { objectWillChange.send() }
    }

    /// Inline styles active at the caret, or on the whole selection (armed styles included).
    @Published var activeInlineKinds: Set<FormattingToolbarView.InlineKind> = []

    /// Heading level (1-3) of the caret's line, or nil when it is not a heading.
    @Published var activeHeadingLevel: Int?

    /// Block kind of the caret's line (bullet, numbered, checklist, quote), or nil for plain lines.
    @Published var activeLinePrefix: FormattingToolbarView.LinePrefix?

    /// Fired when Shift-Tab is pressed with the caret at the start of the text: `EditorPaneView` hands focus
    /// back to the title field. nil leaves the key to the text view.
    var onShiftTabAtBodyStart: (() -> Void)?
}
