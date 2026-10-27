import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keep SwiftUI's click, rename and context-menu handling; take over only an actual drag.
/// AppKit supplies the end position on macOS 15 as well as newer releases.
struct WindowTabDragSource: NSViewRepresentable {
    let tab: TabDragPayload
    let label: String
    let sessionName: String?
    let detach: (CGPoint) -> Void
    @Environment(\.workbenchTabContext) private var tabContext

    init(windowID: String, label: String, sessionName: String? = nil, detach: @escaping (CGPoint) -> Void) {
        self.init(tab: .window(windowID), label: label, sessionName: sessionName, detach: detach)
    }

    init(tab: TabDragPayload, label: String, sessionName: String? = nil, detach: @escaping (CGPoint) -> Void) {
        self.tab = tab
        self.label = label
        self.sessionName = sessionName
        self.detach = detach
    }

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.tab = tab
        view.label = label
        view.sessionName = sessionName
        view.dragContext = tabContext
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
        tabStripFrame: CGRect,
    ) -> Bool {
        operation.isEmpty && !cancelled && mouseReleased && !tabStripFrame.insetBy(dx: -24, dy: -24).contains(point)
    }

    static func tabStripFrame(tabFrame: CGRect, windowFrame: CGRect, isSession: Bool = false) -> CGRect {
        if isSession {
            return windowFrame
        }
        // Horizontal movement within the window remains tab reordering, even over an empty slot.
        return CGRect(x: windowFrame.minX, y: tabFrame.minY, width: windowFrame.width, height: tabFrame.height)
    }

    static func screenPoint(for event: NSEvent) -> CGPoint {
        let point = event.locationInWindow
        // Windowless mouse events already carry screen coordinates.
        return event.window?.convertPoint(toScreen: point) ?? point
    }

    final class DragView: NSView, NSDraggingSource {
        var tab = TabDragPayload.window("")
        var label = ""
        var sessionName: String?
        var dragContext: WorkbenchTabContext?
        var detach: ((CGPoint) -> Void)?
        private var monitor: Any?
        private var mouseDown: NSEvent?
        private var dragSession: NSDraggingSession?
        private var tabStripFrame = CGRect.zero
        private var cancelled = false
        private var mouseReleasePoint: CGPoint?

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
            if dragSession != nil {
                // AppKit can finish the drag after a later mouse-move event has arrived.
                if event.type == .leftMouseUp { mouseReleasePoint = WindowTabDragSource.screenPoint(for: event) }
                return event
            }
            switch event.type {
            case .leftMouseDown:
                guard
                    event.window === window, !isHiddenOrHasHiddenAncestor,
                    WindowTabDragSource.containsDragOrigin(
                        convert(event.locationInWindow, from: nil), bounds: bounds, visibleRect: visibleRect,
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
                        event.locationInWindow.y - start.locationInWindow.y,
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
            mouseReleasePoint = nil
            let item = NSPasteboardItem()
            do {
                if let sessionName {
                    item.setString(sessionName, forType: .init("com.jicezeng.ctrlx.session-window"))
                } else {
                    let data = try JSONEncoder().encode(tab)
                    item.setData(data, forType: NSPasteboard.PasteboardType(UTType.ctrlxTabDrag.identifier))
                    if let drag = dragContext?.drag(tab) {
                        try item.setData(JSONEncoder().encode(drag), forType: NSPasteboard.PasteboardType(UTType.ctrlxWorkbenchTab.identifier))
                    }
                }
            } catch {
                assertionFailure("Cannot encode a workbench tab: \(error)")
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
            tabStripFrame = WindowTabDragSource.tabStripFrame(
                tabFrame: window.convertToScreen(convert(bounds, to: nil)), windowFrame: window.frame, isSession: sessionName != nil,
            )
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
                    mouseReleased: mouseReleasePoint != nil || NSApp.currentEvent?.type == .leftMouseUp,
                    point: mouseReleasePoint ?? screenPoint,
                    tabStripFrame: tabStripFrame,
                ) {
                detach?(mouseReleasePoint ?? screenPoint)
            }
        }
    }
}
