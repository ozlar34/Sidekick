import XCTest
import AppKit
@testable import Sidekick

// Synthetic-mouse layer for HostedEditorRunner (Layer 4). The existing tests
// drive caret placement via setSelectedRange, which bypasses HybridTextView's
// mouseDown geometry (checklist tap-zone, super.mouseDown hit-testing, HR
// relocation) — exactly where the click-geometry cluster bugs live. This adds a
// real NSEvent mouseDown path.
//
// The trick: NSTextView.mouseDown enters a drag-tracking loop that pumps events
// until mouseUp. We post a matching mouseUp FIRST so the loop consumes it and
// returns immediately — no hang, no real run loop needed.
extension HostedEditorRunner {

    /// Left-click at a point given in TEXT-CONTAINER coordinates (same space the
    /// layout manager reports fragment rects in). Drives the full mouseDown path.
    /// `modifierFlags` rides on both events (e.g. `.shift` for extend-selection).
    @MainActor
    func click(atTextPoint textPoint: NSPoint, clickCount: Int = 1,
               modifierFlags: NSEvent.ModifierFlags = []) {
        let tv = inner.textView
        // The window must be key for NSTextView's mouseDown tracking loop to
        // resolve a synthetic click as a zero-length caret. On a non-key window
        // the loop leaves a spurious RANGE selection (anchored at the click,
        // extending to a stale point), which bypasses caret-relocation code
        // guarded on `selectedRange().length == 0`.
        window.makeKeyAndOrderFront(nil)
        let viewPoint = NSPoint(x: textPoint.x + tv.textContainerOrigin.x,
                                y: textPoint.y + tv.textContainerOrigin.y)
        let winPoint = tv.convert(viewPoint, to: nil)
        let ts = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, at timestamp: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: winPoint, modifierFlags: modifierFlags,
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            )
        }
        // The mouseUp MUST carry a later timestamp than the mouseDown. With an
        // identical timestamp, NSTextView's mouseDown tracking loop reads the
        // pair as a zero-duration drag and leaves a spurious RANGE selection
        // (anchored at the click, extending to a stale point) instead of a
        // zero-length caret — which then bypasses any caret-relocation code
        // guarded on `selectedRange().length == 0`. A small positive delta makes
        // it a clean click-and-release.
        guard let down = ev(.leftMouseDown, at: ts),
              let up = ev(.leftMouseUp, at: ts + 0.05) else { return }
        window.postEvent(up, atStart: false)   // queue mouseUp so the loop exits
        tv.mouseDown(with: down)
        inner.layoutManager.ensureLayout(for: inner.container)
    }

    /// Left-drag from one TEXT-CONTAINER point to another. Queues the dragged
    /// and mouseUp events (later timestamps, destination point) before driving
    /// mouseDown, so whichever tracking loop runs sees a real drag and exits.
    @MainActor
    func drag(fromTextPoint from: NSPoint, toTextPoint to: NSPoint,
              modifierFlags: NSEvent.ModifierFlags = []) {
        let tv = inner.textView
        window.makeKeyAndOrderFront(nil)
        func winPoint(_ p: NSPoint) -> NSPoint {
            tv.convert(NSPoint(x: p.x + tv.textContainerOrigin.x,
                               y: p.y + tv.textContainerOrigin.y), to: nil)
        }
        let ts = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, at p: NSPoint, timestamp: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: modifierFlags,
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let down = ev(.leftMouseDown, at: winPoint(from), timestamp: ts),
              let dragged = ev(.leftMouseDragged, at: winPoint(to), timestamp: ts + 0.03),
              let up = ev(.leftMouseUp, at: winPoint(to), timestamp: ts + 0.06) else { return }
        window.postEvent(dragged, atStart: false)
        window.postEvent(up, atStart: false)
        tv.mouseDown(with: down)
        inner.layoutManager.ensureLayout(for: inner.container)
    }

    /// A text-container point just past the right edge of the visual line
    /// fragment that contains `charIndex`, vertically centered — mimics a click
    /// in the empty space to the right of a line's text.
    @MainActor
    func rightEdgePoint(ofCharAt charIndex: Int, beyond: CGFloat = 40) -> NSPoint {
        let lm = inner.layoutManager
        let glyph = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 0),
                                  actualCharacterRange: nil).location
        let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSPoint(x: frag.maxX + beyond, y: frag.midY)
    }
}
