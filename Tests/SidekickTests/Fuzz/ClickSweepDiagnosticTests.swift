import XCTest
import AppKit
@testable import Sidekick

/// Headless geometric click sweep — the in-test twin of the DebugHarness
/// sweep. For every visible glyph in a fixture body it clicks the glyph's
/// left edge (expect caret BEFORE the char) and right edge (expect caret
/// AFTER it), plus the empty space right of every line fragment (expect the
/// fragment's trailing boundary). Mismatches are printed, not asserted:
/// several are legitimate rescues (checkbox toggle, chip half-geometry, HR
/// relocation), so a human classifies them. Opt-in via
/// `SIDEKICK_CLICK_SWEEP=1` so the regular suite stays fast and silent.
@MainActor
final class ClickSweepDiagnosticTests: XCTestCase {

    static let fixtures: [(String, String)] = [
        ("links", """
        Intro line with a [styled link](https://example.com/path) in the middle and more words after it.
        Bare URL follows https://example.com/bare then text.
        Two links [one](https://a.io) and [two](https://b.io) close together.
        Trailing link at end [tail](https://c.io)
        """),
        ("lists", """
        Plain paragraph first.
        - bullet one
        - bullet two with **bold** inside
        - [ ] task open
        - [x] task done
        1. numbered one
        2. numbered two
        > quoted line
        Last plain line.
        """),
        ("rules", """
        Above the rule
        ---
        Below the rule
        ***
        Second below

        ---
        After blank then rule
        """),
        ("mixed", """
        # Heading one
        Some *italic* and `code` and a [link](https://x.io) here.
        - [ ] check with [link](https://y.io) inside
        ---
        - bullet after rule
        Final line.
        """),
    ]

    func test_sweepFixtures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDEKICK_CLICK_SWEEP"] == "1",
                          "opt-in diagnostic; set SIDEKICK_CLICK_SWEEP=1")
        for (name, body) in Self.fixtures {
            sweep(name: name, body: body)
        }
    }

    private func sweep(name: String, body: String) {
        let runner = HostedEditorRunner(initialBody: body, windowSize: CGSize(width: 190, height: 800))
        let lm = runner.inner.layoutManager
        let tc = runner.inner.container
        let storage = runner.inner.storage
        lm.ensureLayout(for: tc)
        let ns = storage.string as NSString
        let n = ns.length
        var lines: [String] = []

        func markers(_ i: Int) -> String {
            var m: [String] = []
            for key: NSAttributedString.Key in [.sidekickHiddenMarker, .sidekickThematicBreak, .sidekickChecklistMarker, .sidekickLinkChip, .sidekickLinkTailAnchor] {
                if storage.attribute(key, at: i, effectiveRange: nil) != nil { m.append(key.rawValue.replacingOccurrences(of: "sidekick", with: "")) }
            }
            if storage.attribute(.link, at: i, effectiveRange: nil) != nil { m.append("link") }
            return m.joined(separator: ",")
        }
        func ctx(_ i: Int) -> String {
            let a = ns.substring(with: NSRange(location: max(0, i - 6), length: i - max(0, i - 6)))
            let b = ns.substring(with: NSRange(location: i, length: min(6, n - i)))
            return (a + "|" + b).replacingOccurrences(of: "\n", with: "⏎")
        }
        func report(_ kind: String, _ i: Int, _ got: NSRange, _ p: NSPoint) {
            lines.append(String(format: "  %-7@ idx=%3d got=%3d/%d at=(%.1f,%.1f) [%@] %@",
                                kind as NSString, i, got.location, got.length, p.x, p.y, markers(min(i, n - 1)) as NSString, ctx(i) as NSString))
        }

        var fragments: [(NSRect, [Int])] = []
        for i in 0..<n {
            let g = lm.glyphIndexForCharacter(at: i)
            guard g < lm.numberOfGlyphs else { continue }
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            if let idx = fragments.firstIndex(where: { $0.0 == frag }) { fragments[idx].1.append(i) } else { fragments.append((frag, [i])) }
            let ch = ns.character(at: i)
            if ch == 10 { continue }
            if lm.propertyForGlyph(at: g).contains(.null) { continue }
            // Glyph extent = [this glyph's x, next visible glyph's x on the same
            // fragment). boundingRect(forGlyphRange:) is unreliable on heading lines.
            let x0 = frag.origin.x + lm.location(forGlyphAt: g).x
            var x1: CGFloat? = nil
            var j = i + 1
            while j < n, x1 == nil {
                let gj = lm.glyphIndexForCharacter(at: j)
                if gj < lm.numberOfGlyphs,
                   lm.lineFragmentRect(forGlyphAt: gj, effectiveRange: nil) == frag,
                   !lm.propertyForGlyph(at: gj).contains(.null) {
                    let xj = frag.origin.x + lm.location(forGlyphAt: gj).x
                    if xj > x0 { x1 = xj } else { break }
                } else if lm.lineFragmentRect(forGlyphAt: gj, effectiveRange: nil) != frag { break }
                j += 1
            }
            guard let x1 else { continue }
            let rect = NSRect(x: x0, y: frag.origin.y, width: x1 - x0, height: frag.height)
            let y = frag.midY
            let left = NSPoint(x: rect.minX + min(1.5, rect.width / 4), y: y)
            runner.select(NSRange(location: n, length: 0))
            runner.click(atTextPoint: left)
            if runner.selection != NSRange(location: i, length: 0) { report("left", i, runner.selection, left) }
            let right = NSPoint(x: rect.maxX - min(1.5, rect.width / 4), y: y)
            runner.select(NSRange(location: 0, length: 0))
            runner.click(atTextPoint: right)
            if runner.selection != NSRange(location: i + 1, length: 0) { report("right", i, runner.selection, right) }
        }
        for (frag, idxs) in fragments {
            let visible = idxs.filter { ns.character(at: $0) != 10 }
            let expected = (visible.max() ?? idxs[0]) + (visible.isEmpty ? 0 : 1)
            let p = NSPoint(x: frag.maxX - 2, y: frag.midY)
            runner.select(NSRange(location: 0, length: 0))
            runner.click(atTextPoint: p)
            if runner.selection != NSRange(location: expected, length: 0) { report("lineend", expected, runner.selection, p) }
        }
        print("== sweep \(name): \(n) chars, \(lines.count) mismatches")
        lines.forEach { print($0) }
    }
}
