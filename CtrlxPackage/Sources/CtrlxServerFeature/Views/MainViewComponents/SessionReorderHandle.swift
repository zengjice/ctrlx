import AppKit
import CtrlxCommon
import SwiftUI

@MainActor
struct SessionReorderHandle: View {
    let isDragging: Bool
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void
    @State private var globalOrigin = CGPoint.zero

    var body: some View {
        Symbols.line3Horizontal.image
            .foregroundStyle(isDragging ? Color.accentColor : .secondary)
            .frame(width: 28, height: 28)
            .overlay {
                SessionDragCapture(
                    globalOrigin: globalOrigin, onChanged: onChanged,
                    onEnded: onEnded, onCancelled: onCancelled
                )
                .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                if globalOrigin != origin { globalOrigin = origin }
            }
    }
}

// AppKit owns the complete mouse sequence. List's selection gesture can cancel
// a SwiftUI DragGesture before onEnded, even when it has high priority.
@MainActor
private struct SessionDragCapture: NSViewRepresentable {
    let globalOrigin: CGPoint
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeNSView(context: Context) -> SessionDragCaptureView { SessionDragCaptureView() }

    func updateNSView(_ view: SessionDragCaptureView, context: Context) {
        view.globalOrigin = globalOrigin
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onCancelled = onCancelled
    }

    static func dismantleNSView(_ view: SessionDragCaptureView, coordinator: ()) { view.cancelDrag() }
}

@MainActor
final class SessionDragCaptureView: NSView {
    var globalOrigin = CGPoint.zero
    var onChanged: (CGPoint) -> Void = { _ in }
    var onEnded: (CGPoint) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    private var startPoint: CGPoint?
    private var isDragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard isDragging || hypot(point.x - startPoint.x, point.y - startPoint.y) >= 2 else { return }
        isDragging = true
        onChanged(globalPoint(point))
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        startPoint = nil
        isDragging = false
        if wasDragging { onEnded(globalPoint(convert(event.locationInWindow, from: nil))) }
    }

    func cancelDrag() {
        let wasDragging = isDragging
        startPoint = nil
        isDragging = false
        if wasDragging { onCancelled() }
    }

    private func globalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: globalOrigin.x + point.x, y: globalOrigin.y + point.y)
    }
}
