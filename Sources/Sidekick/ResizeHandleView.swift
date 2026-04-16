/// 6pt-wide NSViewRepresentable drag zone on the left edge of the panel.
///
/// Pattern sources:
///   - RESEARCH.md §Pattern 3 (Left-Edge Drag Handle)
///   - RESEARCH.md Pitfall 2 (NSCursor reset by SwiftUI — must use cursorUpdate override)
///   - CONTEXT.md: P-01..P-06
import AppKit
import SwiftUI

struct ResizeHandleView: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void

    func makeNSView(context: Context) -> ResizeNSView {
        ResizeNSView(onDrag: onDrag, onDragEnd: onDragEnd)
    }
    func updateNSView(_ nsView: ResizeNSView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onDragEnd = onDragEnd
    }
}

final class ResizeNSView: NSView {
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    init(onDrag: @escaping (CGFloat) -> Void, onDragEnd: @escaping () -> Void) {
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        if let w = window { startWidth = w.frame.width }
    }

    override func mouseDragged(with event: NSEvent) {
        let deltaX = startX - event.locationInWindow.x   // drag left → grow
        onDrag(startWidth + deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd()
    }
}
