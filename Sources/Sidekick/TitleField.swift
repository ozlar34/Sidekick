import AppKit
import SwiftUI

/// Bridge handle for `TitleField`. Holds a weak reference to the underlying
/// NSTextField so EditorPaneView can pull focus to the title from outside —
/// e.g. when Shift-Tab fires from the body editor (F-04 counterpart) or when
/// a fresh empty note mounts (`seedFocusForCurrentNote`).
///
/// Mirrors `HybridEditorController`'s shape: `@MainActor`, ObservableObject,
/// weak NSView ref written in `makeNSView`. We don't need any @Published state
/// here yet, but adopting the pattern keeps both controllers symmetrical.
@MainActor
final class TitleFieldController: ObservableObject {
    weak var textField: NSTextField?

    /// Make the title field first responder. No-op if the field isn't in a
    /// window yet (e.g. called before view mount).
    func focus() {
        guard let tf = textField else { return }
        tf.window?.makeFirstResponder(tf)
    }
}

/// SwiftUI wrapper around NSTextField that exposes a Tab callback.
///
/// Why this exists: `.onKeyPress(.tab)` on a SwiftUI TextField does not fire
/// on macOS. The underlying NSTextField uses a shared field editor, and the
/// field editor intercepts Tab as `insertTab:` to drive focus traversal
/// (`selectNextKeyView:`) before SwiftUI's gesture layer sees the keystroke.
/// Wrapping NSTextField directly lets us hook `control(_:textView:doCommandBy:)`
/// and route Tab to a callback (F-10).
struct TitleField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let controller: TitleFieldController
    var onTab: () -> Void = {}
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTab: onTab, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.placeholderString = placeholder
        tf.font = font
        tf.delegate = context.coordinator
        tf.target = context.coordinator
        tf.action = #selector(Coordinator.submit(_:))
        // Single-line behavior: don't wrap, scroll horizontally on overflow.
        tf.cell?.wraps = false
        tf.cell?.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.stringValue = text
        controller.textField = tf
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Only push the binding value into the field when it actually
        // diverges — otherwise re-assigning stringValue on every SwiftUI
        // update would clobber the user's mid-edit cursor.
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.font != font { nsView.font = font }
        if nsView.placeholderString != placeholder { nsView.placeholderString = placeholder }
        // Keep callbacks fresh — SwiftUI struct closures are recreated each
        // body re-evaluation, so the coordinator must capture the latest.
        context.coordinator.onTab = onTab
        context.coordinator.onSubmit = onSubmit
        context.coordinator.binding = $text
        // Re-bind controller in case the parent recreated it on note switch.
        if controller.textField !== nsView {
            controller.textField = nsView
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var binding: Binding<String>
        var onTab: () -> Void
        var onSubmit: () -> Void

        init(text: Binding<String>,
             onTab: @escaping () -> Void,
             onSubmit: @escaping () -> Void) {
            self.binding = text
            self.onTab = onTab
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                binding.wrappedValue = tf.stringValue
            }
        }

        /// Field-editor command interception. Called for every NSResponder
        /// command the field editor cannot resolve itself. We claim Tab and
        /// Return to drive the title→body handoff; everything else falls
        /// through to standard NSTextField behavior.
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTab()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }

        @objc func submit(_ sender: Any?) { onSubmit() }
    }
}
