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
    var startWidthProvider: (() -> CGFloat)? = nil
    var growsRight: Bool = false

    func makeNSView(context: Context) -> ResizeNSView {
        ResizeNSView(onDrag: onDrag, onDragEnd: onDragEnd,
                     startWidthProvider: startWidthProvider, growsRight: growsRight)
    }
    func updateNSView(_ nsView: ResizeNSView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onDragEnd = onDragEnd
        nsView.startWidthProvider = startWidthProvider
        nsView.growsRight = growsRight
    }
}

final class ResizeNSView: NSView {
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void
    var startWidthProvider: (() -> CGFloat)?
    var growsRight: Bool
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    init(onDrag: @escaping (CGFloat) -> Void, onDragEnd: @escaping () -> Void,
         startWidthProvider: (() -> CGFloat)? = nil, growsRight: Bool = false) {
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        self.startWidthProvider = startWidthProvider
        self.growsRight = growsRight
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
        startWidth = startWidthProvider?() ?? (window?.frame.width ?? 0)
    }

    override func mouseDragged(with event: NSEvent) {
        let deltaX = startX - event.locationInWindow.x   // drag left → grow (left edge)
        let newWidth = growsRight ? startWidth - deltaX : startWidth + deltaX
        onDrag(newWidth)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd()
    }
}
