import XCTest
import AppKit
import SwiftUI
@testable import Sidekick

/// `KeystrokeRunner` — Layer 1 of the headless test harness.
///
/// A windowless TextKit stack (storage + layout manager + container + text
/// view) wired to a real `HybridEditorView.Coordinator`. Tests drive keystrokes
/// through the same paths that AppKit hits at runtime:
///   * `textView.insertText(_:replacementRange:)` for printable input — runs
///     the HybridTextView F-07 override and armed-inline consumption-on-type.
///   * `coordinator.textView(_:doCommandBy:)` for special keys (Enter,
///     Backspace, Tab, arrows) — runs the Coordinator's command-selector
///     dispatch (handleThematicBreakReturn, handleAtomicMarkerBackspace, etc).
///     When the Coordinator declines (returns false), the call falls through
///     to `textView.doCommand(by:)` so default NSTextView behavior runs.
///
/// Stack assembly mirrors `EditorInteractionTests.makeStack` (lines 17-43 of
/// that file) but uses `HybridTextView` instead of plain `NSTextView` so the
/// F-07 `insertText(_:replacementRange:)` override and the armed-inline
/// consumption path are also exercised. The text view is a nested
/// `TestableHybridTextView` subclass that injects a local `UndoManager` —
/// windowless NSTextViews have no undoManager via the responder chain.
/// Pattern copied from `PerformWrapTests.TestableTextView` (lines 9-12).
///
/// Used by `TranscriptRunnerTests` (smoke), `InvariantFuzzTests` (Layer 2
/// fuzzer), and `Regressions/*Tests` (Layer 3 starter).
@MainActor
final class KeystrokeRunner {

    // MARK: - Key vocabulary

    /// Special keys the runner can dispatch via `coordinator.textView(_:doCommandBy:)`.
    /// Mapping mirrors the selectors used in `EditorInteractionTests` and the
    /// Coordinator's `doCommandBy` dispatch table.
    enum Key {
        case enter
        case backspace
        case delete
        case tab
        case shiftTab
        case left
        case right
        case up
        case down

        var selector: Selector {
            switch self {
            case .enter:     return #selector(NSResponder.insertNewline(_:))
            case .backspace: return #selector(NSResponder.deleteBackward(_:))
            case .delete:    return #selector(NSResponder.deleteForward(_:))
            case .tab:       return #selector(NSResponder.insertTab(_:))
            case .shiftTab:  return #selector(NSResponder.insertBacktab(_:))
            case .left:      return #selector(NSResponder.moveLeft(_:))
            case .right:     return #selector(NSResponder.moveRight(_:))
            case .up:        return #selector(NSResponder.moveUp(_:))
            case .down:      return #selector(NSResponder.moveDown(_:))
            }
        }

        /// Source-code label used by `transcriptDump` so failures emit
        /// paste-ready Swift.
        var transcriptLabel: String {
            switch self {
            case .enter:     return ".enter"
            case .backspace: return ".backspace"
            case .delete:    return ".delete"
            case .tab:       return ".tab"
            case .shiftTab:  return ".shiftTab"
            case .left:      return ".left"
            case .right:     return ".right"
            case .up:        return ".up"
            case .down:      return ".down"
            }
        }
    }

    // MARK: - Internal step log (drives transcriptDump)

    private enum Step {
        case type(String)
        case key(Key)
        case select(NSRange)
    }

    // MARK: - HybridTextView subclass with injected UndoManager
    //
    // Pattern copied from PerformWrapTests.TestableTextView (lines 9-12).
    // Windowless text views have no responder chain, so `undoManager` is
    // nil by default. Overriding the property injects a local UndoManager
    // so edit-sandwich paths that go through `shouldChangeText` / undo
    // registration work as expected.

    private final class TestableHybridTextView: HybridTextView {
        private let _undoManager = UndoManager()
        override var undoManager: UndoManager? { _undoManager }
    }

    // MARK: - Stack pieces (mirrors EditorInteractionTests.makeStack)

    let storage: MarkdownTextStorage
    let layoutManager: MarkdownLayoutManager
    let container: NSTextContainer
    let textView: HybridTextView
    let controller: HybridEditorController
    let coordinator: HybridEditorView.Coordinator

    /// Backing for the SwiftUI binding the view holds. Boxed so the binding
    /// captures a reference (closures can't capture `self` before all stored
    /// properties are initialized). Updated in lockstep with `textView.string`
    /// after each keystroke so the binding round-trip reflects edits.
    private final class StringBox { var value: String = "" }
    private let bodyBox: StringBox

    /// Convenience accessor for the boxed binding string.
    private var bodyBinding: String {
        get { bodyBox.value }
        set { bodyBox.value = newValue }
    }

    /// Initial body used as the first line of `transcriptDump()` output.
    private let initialBody: String
    private let initialSelection: NSRange

    /// Captured return value of the last `coordinator.textView(_:doCommandBy:)`
    /// call. Tests can assert on this if they care about whether the
    /// Coordinator consumed the keystroke or fell through.
    private(set) var lastWasHandled: Bool = false

    private var steps: [Step] = []

    // MARK: - Init

    init(initialBody: String = "",
         initialSelection: NSRange = NSRange(location: 0, length: 0))
    {
        self.initialBody = initialBody
        self.initialSelection = initialSelection
        let box = StringBox()
        box.value = initialBody
        self.bodyBox = box

        // Four-piece TextKit assembly — ORDER MATTERS:
        //   1. storage
        //   2. layoutManager (added to storage)
        //   3. container (added to layoutManager)
        //   4. textView (created with container)
        self.storage = MarkdownTextStorage()
        self.layoutManager = MarkdownLayoutManager()
        self.container = NSTextContainer(size: NSSize(width: 200, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let tv = TestableHybridTextView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            textContainer: container
        )
        tv.isRichText = false
        tv.allowsUndo = true
        // F-07 defaults match production: disable smart-quotes / dash /
        // autocorrect / link detection so the same keystrokes produce the
        // same byte output the runner asserts on.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false

        if !initialBody.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                      with: initialBody)
        }
        tv.setSelectedRange(initialSelection)
        self.textView = tv

        // HybridEditorController + Coordinator wiring — same pattern as
        // EditorInteractionTests.makeStack lines 35-42. The binding's get
        // closure captures `self` weakly via a back-channel (we re-read
        // bodyBinding via a closure pair).
        let ctl = HybridEditorController()
        self.controller = ctl

        // Capture the StringBox so the binding stays alive without
        // requiring `self` (which isn't fully initialized yet).
        let binding = Binding<String>(
            get: { box.value },
            set: { box.value = $0 }
        )
        let view = HybridEditorView(text: binding, controller: ctl)
        self.coordinator = view.makeCoordinator()

        // Hook coordinator → textView and back so delegate callbacks can
        // resolve the view. EditorInteractionTests' makeStack does not set
        // this because its tests call the delegate directly with the
        // textView arg. We do the same here, but also set it so any
        // notification-driven paths find the view.
        ctl.textView = tv
        tv.hybridController = ctl
        tv.delegate = coordinator
    }

    // MARK: - Public API

    /// Type a printable string, character-by-character, through the real
    /// `HybridTextView.insertText(_:replacementRange:)` path. Each character
    /// is inserted at the current selection (NSNotFound as replacementRange
    /// is the standard NSTextInputClient contract for "use current selection").
    func type(_ text: String) {
        for c in text {
            textView.insertText(String(c),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        steps.append(.type(text))
        // Keep the binding in sync — the production path runs
        // `textDidChange` which is what triggers binding updates, but in
        // headless tests we don't always get notifications fired. Read
        // direct.
        bodyBinding = textView.string
    }

    /// Dispatch a special key through `coordinator.textView(_:doCommandBy:)`.
    /// If the coordinator declines (returns false), invoke the default
    /// NSTextView behavior via `textView.doCommand(by:)` so arrow keys,
    /// plain newlines in non-list lines, etc. still take effect.
    func key(_ key: Key) {
        lastWasHandled = coordinator.textView(textView, doCommandBy: key.selector)
        if !lastWasHandled {
            textView.doCommand(by: key.selector)
        }
        steps.append(.key(key))
        bodyBinding = textView.string
    }

    /// Programmatically set the selection and fire the selection-change
    /// delegate notification so F-06-style hooks (and the armed-inline
    /// cancel path) run.
    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
        steps.append(.select(range))
    }

    // MARK: - Assertions (XCTest-aware)

    func assertBody(_ expected: String,
                    file: StaticString = #file,
                    line: UInt = #line)
    {
        XCTAssertEqual(textView.string, expected, file: file, line: line)
    }

    func assertSelection(_ expected: NSRange,
                         file: StaticString = #file,
                         line: UInt = #line)
    {
        XCTAssertEqual(textView.selectedRange(), expected, file: file, line: line)
    }

    // MARK: - Ad-hoc reads

    var body: String { textView.string }
    var selection: NSRange { textView.selectedRange() }

    // MARK: - Transcript dump

    /// Render the step log as paste-ready Swift. The output is multi-line
    /// and starts with the initializer call so failures from the fuzzer
    /// can be dropped verbatim into a new test file.
    func transcriptDump() -> String {
        var lines: [String] = []
        lines.append(
            "let runner = KeystrokeRunner(initialBody: \(quoted(initialBody)), " +
            "initialSelection: NSRange(location: \(initialSelection.location), " +
            "length: \(initialSelection.length)))"
        )
        for step in steps {
            switch step {
            case .type(let s):
                lines.append("runner.type(\(quoted(s)))")
            case .key(let k):
                lines.append("runner.key(\(k.transcriptLabel))")
            case .select(let r):
                lines.append(
                    "runner.select(NSRange(location: \(r.location), length: \(r.length)))"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Produce a Swift-string-literal representation of `s` with `"`, `\`,
    /// `\n`, `\t`, `\r` escaped. Used by `transcriptDump`.
    private func quoted(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            case "\r": out.append("\\r")
            default:   out.append(c)
            }
        }
        out.append("\"")
        return out
    }
}
