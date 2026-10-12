#if os(iOS)
import UIKit

/// Decide the axis before the terminal's scroll gestures claim a drag.
@MainActor
final class TerminalWindowSwipeGesture: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UIPanGestureRecognizer()
    var onSwitchWindow: (@MainActor (TerminalWindowSwipePolicy.Direction) -> Void)? {
        didSet {
            if recognizer.isEnabled != (onSwitchWindow != nil) {
                recognizer.isEnabled = onSwitchWindow != nil
            }
            if onSwitchWindow == nil { pendingSwitch = nil }
        }
    }
    private weak var viewport: UIScrollView?
    private weak var terminal: InteractiveTerminalView?
    private var pendingSwitch: (
        direction: TerminalWindowSwipePolicy.Direction,
        action: @MainActor (TerminalWindowSwipePolicy.Direction) -> Void
    )?

    init(viewport: UIScrollView, terminal: InteractiveTerminalView) {
        self.viewport = viewport
        self.terminal = terminal
        super.init()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.isEnabled = false
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(handlePan(_:)))
        viewport.addGestureRecognizer(recognizer)
        viewport.panGestureRecognizer.require(toFail: recognizer)
        terminal.prioritizeWindowSwipe(recognizer)
    }

    func canStart(at locationInWindow: CGPoint) -> Bool {
        guard onSwitchWindow != nil, let viewport, let window = viewport.window,
              terminal?.selectionActive == false else { return false }
        // Keep the system's leading-edge Back gesture intact.
        return locationInWindow.x - window.bounds.minX > 32
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        pendingSwitch = nil
        guard let window = viewport?.window else { return false }
        return canStart(at: touch.location(in: window))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        pendingSwitch = nil
        guard let action = onSwitchWindow, let viewport, terminal?.selectionActive == false,
              let direction = TerminalWindowSwipePolicy.direction(
                  translation: recognizer.translation(in: viewport.window)
              ) else { return false }
        // Wide content scrolls first; only an outward drag at its edge navigates.
        let leftEdge = -viewport.adjustedContentInset.left
        let rightEdge = max(leftEdge, viewport.contentSize.width - viewport.bounds.width + viewport.adjustedContentInset.right)
        switch direction {
        case .previous:
            guard viewport.contentOffset.x <= leftEdge + 1 else { return false }
        case .next:
            guard viewport.contentOffset.x >= rightEdge - 1 else { return false }
        }
        // Bind the action to the window dragged, not a later SwiftUI update.
        pendingSwitch = (direction, action)
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // iOS 26 also pops from the content area. Only that gesture waits for
        // this swipe; the leading-edge Back gesture keeps its normal priority.
        guard #available(iOS 26.0, *) else { return false }
        var responder: UIResponder? = viewport
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                return otherGestureRecognizer === navigation.interactiveContentPopGestureRecognizer
            }
            responder = current.next
        }
        return false
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            terminal?.cancelCursorNavigation()
            terminal?.cancelQuestionCheck()
            terminal?.cancelMouseScroll()
        case .ended:
            defer { pendingSwitch = nil }
            guard onSwitchWindow != nil, terminal?.selectionActive == false, let pendingSwitch,
                  TerminalWindowSwipePolicy.shouldSwitch(
                      translation: gesture.translation(in: viewport?.window), startedDirection: pendingSwitch.direction
                  ) else { return }
            pendingSwitch.action(pendingSwitch.direction)
        case .cancelled, .failed:
            pendingSwitch = nil
        default:
            break
        }
    }
}
#endif
