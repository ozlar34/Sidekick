import XCTest
import AppKit
@testable import Sidekick

// Bug (2026-11-16): in the panel the editor's text view was always 100 pt wider than the visible area of its scroll
// view (measured live with the debug harness: 290 against 190, 470 against 370), so long lines, dividers and code blocks
// ran under the panel's right edge. The view is made 100 pt wide, the scroll view has no size at that time, and the
// width autoresizing kept that difference at every size.
// This test guards the rule on the app's own assembly (`NoteEditorView.makeScrollView`): the text view is exactly as
// wide as the visible area at every size. It did NOT fail before the fix: in a test process AppKit sets the view to the
// visible width when it goes into the scroll view, in the app it did not. The live check is `/state` of the harness:
// `editor.frame.w` must equal `editor.clipBounds.w`.
@MainActor
final class EditorWidthMatchesVisibleAreaTests: XCTestCase {

    func test_textViewIsAsWideAsTheVisibleArea() {
        let tv = NoteTextView.make()
        let scroll = NoteEditorView.makeScrollView(for: tv)
        for width in [370, 190, 520] as [CGFloat] {
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(tv.frame.width, scroll.contentSize.width,
                           "the text view must be as wide as the visible area at scroll view width \(width)")
        }
    }
}
