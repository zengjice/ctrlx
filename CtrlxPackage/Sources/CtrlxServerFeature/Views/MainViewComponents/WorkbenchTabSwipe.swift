import AppKit
import SwiftUI

/// A physical scroll gesture owns one axis until lift-off; its momentum never
/// starts another tab switch or scrolls the newly selected tab.
struct WorkbenchTabSwipeGesture {
    private var isTracking = false
    private var isHorizontal: Bool?
    private var distance: CGFloat = 0
    private var verticalDistance: CGFloat = 0

    private var consumesScroll: Bool {
        isHorizontal ?? (abs(distance) > abs(verticalDistance) * 1.5)
    }

    mutating func reset() {
        self = Self()
    }

    mutating func consume(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase = []
    ) -> (consumed: Bool, direction: Int?) {
        if phase.contains(.began) {
            reset()
            isTracking = true
        }
        if !momentumPhase.isEmpty {
            return (isHorizontal == true, nil)
        }
        guard isTracking else { return (false, nil) }
        if phase.contains(.cancelled) {
            let consumed = consumesScroll
            reset()
            return (consumed, nil)
        }
        distance += deltaX
        verticalDistance += deltaY
        // Ignore initial finger jitter before locking the gesture's axis.
        if isHorizontal == nil, max(abs(distance), abs(verticalDistance)) >= 8 {
            isHorizontal = abs(distance) > abs(verticalDistance) * 1.5
        }
        let consumed = consumesScroll
        if phase.contains(.ended) {
            isTracking = false
            isHorizontal = consumed
            // Follow the tab strip: physical left selects previous, right selects next.
            let direction = consumed && abs(distance) >= 60 ? (distance < 0 ? -1 : 1) : nil
            return (consumed, direction)
        }
        return (consumed, nil)
    }
}

/// Observes only the content area's trackpad scrolls, leaving the tab strip,
/// sidebar and modified scrolls to their existing handlers.
struct WorkbenchTabSwipe: NSViewRepresentable {
    let tabs: SessionFileTabsState
    let isEnabled: Bool
    let onSwipe: @MainActor (_ direction: Int, _ onRight: Bool) -> Void

    func makeNSView(context: Context) -> WorkbenchTabSwipeView {
        WorkbenchTabSwipeView()
    }

    func updateNSView(_ view: WorkbenchTabSwipeView, context: Context) {
        view.tabs = tabs
        view.isEnabled = isEnabled
        view.onSwipe = onSwipe
    }

    static func dismantleNSView(_ view: WorkbenchTabSwipeView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class WorkbenchTabSwipeView: NSView {
    weak var tabs: SessionFileTabsState?
    var onSwipe: (@MainActor (_ direction: Int, _ onRight: Bool) -> Void)?
    var isEnabled = true {
        didSet {
            if !isEnabled {
                gesture.reset()
            }
        }
    }

    private var gesture = WorkbenchTabSwipeGesture()
    private var startsOnRight = false
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .scrollWheel else { return event }
        guard
            isEnabled, let window, event.window === window, window.isKeyWindow,
            window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
            event.hasPreciseScrollingDeltas,
            event.modifierFlags.intersection([.option, .command, .control, .shift]).isEmpty,
            !event.phase.isEmpty || !event.momentumPhase.isEmpty
        else {
            gesture.reset()
            return event
        }
        if event.phase.contains(.began) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else {
                gesture.reset()
                return event
            }
            startsOnRight = tabs?.isSplit == true && point.x > bounds.width * (tabs?.splitRatio ?? 0.5)
        }
        // Keep physical left/right consistent when natural scrolling is off.
        let deltaX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let result = gesture.consume(deltaX: deltaX, deltaY: event.scrollingDeltaY, phase: event.phase, momentumPhase: event.momentumPhase)
        if let direction = result.direction {
            onSwipe?(direction, startsOnRight)
        }
        return result.consumed ? nil : event
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        gesture.reset()
    }
}
