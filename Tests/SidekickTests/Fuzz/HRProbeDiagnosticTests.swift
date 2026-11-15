import XCTest
import AppKit
@testable import Sidekick

/// Headless HR keystroke probes — prints body + selection after each
/// transcript so a human can spot misbehaviour the existing HR tests do not
/// pin. Opt-in via `SIDEKICK_HR_PROBE=1`.
@MainActor
final class HRProbeDiagnosticTests: XCTestCase {

    private func show(_ label: String, _ r: KeystrokeRunner) {
        let b = r.body.replacingOccurrences(of: "\n", with: "⏎")
        var marked = b
        let idx = b.index(b.startIndex, offsetBy: min(r.selection.location, b.count))
        marked.insert("¦", at: idx)
        print("  \(label): \(marked)   sel=\(r.selection)")
    }

    func test_probes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDEKICK_HR_PROBE"] == "1")

        print("== HR probes")
        do { // 1. type --- Enter at doc end, then text
            let r = KeystrokeRunner(initialBody: "above", initialSelection: NSRange(location: 5, length: 0))
            r.key(.enter); r.type("---"); show("typed --- (no enter yet)", r)
            r.key(.enter); show("after enter", r)
            r.type("below"); show("typed below", r)
        }
        do { // 2. Enter at end of line above an existing HR
            let r = KeystrokeRunner(initialBody: "above\n---\nbelow", initialSelection: NSRange(location: 5, length: 0))
            r.key(.enter); show("enter at end of 'above'", r)
            r.type("x"); show("typed x", r)
        }
        do { // 3. Enter at start of line below HR
            let r = KeystrokeRunner(initialBody: "above\n---\nbelow", initialSelection: NSRange(location: 10, length: 0))
            r.key(.enter); show("enter at start of 'below'", r)
        }
        do { // 4. Up/Down across HR
            let r = KeystrokeRunner(initialBody: "above\n---\nbelow", initialSelection: NSRange(location: 2, length: 0))
            r.key(.down); show("down from 'above'", r)
            r.key(.up); show("up again", r)
        }
        do { // 5. Right arrow walk across HR from end of above
            let r = KeystrokeRunner(initialBody: "above\n---\nbelow", initialSelection: NSRange(location: 5, length: 0))
            r.key(.right); show("right from end of above", r)
            r.key(.right); show("right again", r)
            r.key(.left); show("left", r)
            r.key(.left); show("left again", r)
        }
        do { // 6. --- immediately followed by typing more chars (should un-HR)
            let r = KeystrokeRunner(initialBody: "a\n---", initialSelection: NSRange(location: 5, length: 0))
            show("start", r)
            r.type("x"); show("typed x after ---", r)
            r.key(.backspace); show("backspace", r)
        }
        do { // 7. Backspace on empty line below a freshly typed HR
            let r = KeystrokeRunner(initialBody: "a", initialSelection: NSRange(location: 1, length: 0))
            r.key(.enter); r.type("---"); r.key(.enter); show("a ⏎ --- ⏎", r)
            r.key(.backspace); show("backspace on empty line below", r)
            r.key(.backspace); show("backspace again", r)
        }
        do { // 8. HR at doc start, type above via Enter? (caret can't be at 0 on HR)
            let r = KeystrokeRunner(initialBody: "---\nbelow", initialSelection: NSRange(location: 4, length: 0))
            show("start (caret at 'below')", r)
            r.key(.left); show("left from below", r)
            r.key(.up); show("up", r)
        }
        do { // 9. Select-all + type replaces HR doc
            let r = KeystrokeRunner(initialBody: "a\n---\nb", initialSelection: NSRange(location: 0, length: 7))
            r.type("z"); show("select all + z", r)
        }
        do { // 10. Undo after one-shot HR delete
            let r = KeystrokeRunner(initialBody: "a\n---\nb", initialSelection: NSRange(location: 6, length: 0))
            r.key(.backspace); show("backspace at start of b", r)
            r.textView.undoManager?.undo(); show("undo", r)
        }
        do { // 11. HR with trailing space / 4 dashes / spaced dashes
            for body in ["a\n--- \nb", "a\n----\nb", "a\n- - -\nb", "a\n***\nb", "a\n___\nb", "a\n  ---\nb"] {
                let r = KeystrokeRunner(initialBody: body, initialSelection: NSRange(location: 0, length: 0))
                let ns = body as NSString
                let hrLine = ns.lineRange(for: NSRange(location: 2, length: 0))
                let isHR = r.storage.attribute(.sidekickThematicBreak, at: hrLine.location, effectiveRange: nil) != nil
                r.select(NSRange(location: 1, length: 0)); r.key(.right); r.key(.right)
                show("\(body.replacingOccurrences(of: "\n", with: "⏎")) hr=\(isHR) → right,right", r)
            }
        }
        do { // 12. Type dashes inside a paragraph: "a---b" should not become HR
            let r = KeystrokeRunner(initialBody: "ab", initialSelection: NSRange(location: 1, length: 0))
            r.type("---"); show("a---b", r)
        }
        do { // 13. Two HRs back to back
            let r = KeystrokeRunner(initialBody: "a\n---\n---\nb", initialSelection: NSRange(location: 1, length: 0))
            r.key(.right); show("right from a (two HRs)", r)
            r.key(.right); show("right again", r)
            r.key(.backspace); show("backspace", r)
        }
        do { // 14. Enter on the line above HR, mid-word
            let r = KeystrokeRunner(initialBody: "above\n---\nbelow", initialSelection: NSRange(location: 3, length: 0))
            r.key(.enter); show("enter mid 'above'", r)
        }
        do { // 15. Forward delete at end of 'above' twice
            let r = KeystrokeRunner(initialBody: "above\n---\nbelow", initialSelection: NSRange(location: 5, length: 0))
            r.key(.delete); show("fwd delete at end of above", r)
            r.key(.delete); show("fwd delete again", r)
        }
    }
}
