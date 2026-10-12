import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keep SwiftUI's click, rename and context-menu handling; take over only an actual drag.
/// AppKit supplies the end position on macOS 15 as well as newer releases.
struct WindowTabDragSource: NSViewRepresentable {
    let windowID: String
    let label: String
    let detach: (CGPoint) -> Void

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.windowID = windowID
        view.label = label
        view.detach = detach
    }

    static func dismantleNSView(_ view: DragView, coordinator: ()) {
        view.stopMonitoring()
    }

    static func containsDragOrigin(_ point: CGPoint, bounds: CGRect, visibleRect: CGRect) -> Bool {
        // A SwiftUI hosting ancestor can expose a visibleRect larger than this tab.
        bounds.intersection(visibleRect).contains(point)
    }

    static func shouldDetach(
        operation: NSDragOperation,
        cancelled: Bool,
        mouseReleased: Bool,
        point: CGPoint,
        sourceFrame: CGRect
    ) -> Bool {
        operation.isEmpty && !cancelled && mouseReleased && !sourceFrame.insetBy(dx: -12, dy: -12).contains(point)
    }

    final class DragView: NSView, NSDraggingSource {
        var windowID = ""
        var label = ""
        var detach: ((CGPoint) -> Void)?
        private var monitor: Any?
        private var mouseDown: NSEvent?
        private var dragSession: NSDraggingSession?
        private var sourceFrame = CGRect.zero
        private var cancelled = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            mouseDown = nil
        }

        isolated deinit { stopMonitoring() }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyDown, event.keyCode == 53 {
                cancelled = true
                mouseDown = nil
                return event
            }
            guard dragSession == nil else { return event }
            switch event.type {
            case .leftMouseDown:
                guard
                    event.window === window, !isHiddenOrHasHiddenAncestor,
                    WindowTabDragSource.containsDragOrigin(
                        convert(event.locationInWindow, from: nil), bounds: bounds, visibleRect: visibleRect
                    ),
                    !event.modifierFlags.contains(.control) else { return event }
                mouseDown = event
                cancelled = false
            case .leftMouseUp:
                mouseDown = nil
            case .leftMouseDragged:
                guard let start = mouseDown, let window, event.window === window else { return event }
                guard
                    hypot(
                        event.locationInWindow.x - start.locationInWindow.x,
                        event.locationInWindow.y - start.locationInWindow.y
                    ) >= 5 else { return event }
                mouseDown = nil
                beginDrag(event)
                return nil
            default: break
            }
            return event
        }

        private func beginDrag(_ event: NSEvent) {
            guard let window else { return }
            let item = NSPasteboardItem()
            do {
                let data = try JSONEncoder().encode(TabDragPayload.window(windowID))
                item.setData(data, forType: NSPasteboard.PasteboardType(UTType.ctrlxTabDrag.identifier))
            } catch {
                assertionFailure("Cannot encode a terminal tab: \(error)")
                return
            }
            let preview = NSImage(size: bounds.size)
            preview.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            (label as NSString).draw(at: NSPoint(x: 8, y: 5), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
            preview.unlockFocus()
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(bounds, contents: preview)
            sourceFrame = window.frame
            dragSession = beginDraggingSession(with: [draggingItem], event: event, source: self)
            dragSession?.animatesToStartingPositionsOnCancelOrFail = false
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragSession = nil
            if
                WindowTabDragSource.shouldDetach(
                    operation: operation,
                    cancelled: cancelled,
                    mouseReleased: NSApp.currentEvent?.type == .leftMouseUp,
                    point: screenPoint,
                    sourceFrame: sourceFrame
                ) {
                detach?(screenPoint)
            }
        }
    }
}
