import XCTest
import AppKit
@testable import Sidekick

/// `HostedEditorRunner` — Layer 4 of the headless test harness.
///
/// Wraps a `KeystrokeRunner` inside a real `NSWindow` + `NSScrollView` so the
/// paths that need a window or first responder to run (layout, glyph generation,
/// cacheable display, focus-dependent commands) take effect. Everything below
/// the window is the same TextKit stack `KeystrokeRunner` already drives, so
/// the typing / key / select API is identical and pass-through.
///
/// What this adds on top of Layer 1 (`KeystrokeRunner`):
///   * Real `NSWindow` hosting the text view → layout manager produces glyph
///     positions, `cacheDisplay(in:to:)` works for image snapshots.
///   * Text view as first responder → command selectors that walk the responder
///     chain resolve correctly.
///   * `attributedString` accessor → enables attribute-snapshot assertions
///     against the full styling surface (font traits, colors, paragraph style,
///     custom `sidekick*` markers).
///   * `renderImage()` / `writePNG(to:)` → ad-hoc visual capture (not yet wired
///     into automated diffs; opt-in for manual review).
///
/// Use Layer 4 when the bug being hunted lives in the view layer: marker glyph
/// substitution, font/color attribute correctness, HR rendering, paragraph
/// style coalescing. Use Layer 1 (`KeystrokeRunner` alone) when you only need
/// body string + selection assertions — it's faster and has no window.
@MainActor
final class HostedEditorRunner {

    // MARK: - Stored

    let inner: KeystrokeRunner
    let scrollView: NSScrollView
    let window: NSWindow

    // MARK: - Init

    /// Default `windowSize` (400×300) matches the smallest production note
    /// window size — wide enough that headings + bullet indents don't wrap on
    /// short test bodies, tall enough that 5–10 paragraphs lay out fully.
    init(initialBody: String = "",
         initialSelection: NSRange = NSRange(location: 0, length: 0),
         windowSize: CGSize = CGSize(width: 400, height: 300))
    {
        self.inner = KeystrokeRunner(
            initialBody: initialBody,
            initialSelection: initialSelection
        )

        let frame = NSRect(origin: .zero, size: windowSize)

        // Resize the text view + container that KeystrokeRunner created to
        // match the window. Defaults were 200×1000 (windowless) which would
        // cause wrap behavior to diverge from production.
        let tv = inner.textView
        tv.frame = frame
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        inner.container.containerSize = NSSize(
            width: windowSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        inner.container.widthTracksTextView = true

        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        self.scrollView = scroll

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.contentView = scroll
        win.makeFirstResponder(tv)
        self.window = win

        // Force initial layout so glyph generation runs against the resized
        // container before the first assertion reads attributes / pixels.
        inner.layoutManager.ensureLayout(for: inner.container)
    }

    // MARK: - Pass-through API (delegates to KeystrokeRunner, plus relayout)

    func type(_ text: String) {
        inner.type(text)
        forceLayout()
    }

    func key(_ key: KeystrokeRunner.Key) {
        inner.key(key)
        forceLayout()
    }

    func select(_ range: NSRange) {
        inner.select(range)
    }

    func assertBody(_ expected: String,
                    file: StaticString = #file,
                    line: UInt = #line)
    {
        inner.assertBody(expected, file: file, line: line)
    }

    func assertSelection(_ expected: NSRange,
                         file: StaticString = #file,
                         line: UInt = #line)
    {
        inner.assertSelection(expected, file: file, line: line)
    }

    var body: String { inner.body }
    var selection: NSRange { inner.selection }
    func transcriptDump() -> String { inner.transcriptDump() }

    // MARK: - Layer 4 additions

    /// Immutable copy of the current attributed string from
    /// `MarkdownTextStorage`. Stable to pass through `AttributeSnapshot.serialize`
    /// for snapshot assertions.
    var attributedString: NSAttributedString {
        NSAttributedString(attributedString: inner.storage)
    }

    /// Render the text view to an `NSImage` for ad-hoc visual capture. Not
    /// wired into automated diffs — call from a test and save via
    /// `writePNG(to:)` for manual review, or feed into a pixel-diff helper.
    func renderImage() -> NSImage {
        let tv = inner.textView
        tv.layoutSubtreeIfNeeded()
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else {
            return NSImage(size: tv.bounds.size)
        }
        tv.cacheDisplay(in: tv.bounds, to: rep)
        let img = NSImage(size: tv.bounds.size)
        img.addRepresentation(rep)
        return img
    }

    /// Save `renderImage()` to PNG at `url`. Used during snapshot authoring
    /// to drop a baseline image alongside the textual attribute snapshot.
    func writePNG(to url: URL) throws {
        let img = renderImage()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try png.write(to: url)
    }

    // MARK: - Helpers

    private func forceLayout() {
        inner.layoutManager.ensureLayout(for: inner.container)
    }
}
