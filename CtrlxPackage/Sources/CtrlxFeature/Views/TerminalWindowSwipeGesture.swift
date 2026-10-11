#if os(iOS)
import UIKit

/// Observe a right swipe without making terminal pans wait for another recognizer.
@MainActor
final class TerminalWindowSwipeGesture: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UISwipeGestureRecognizer()
    var onNextWindow: (@MainActor () -> Void)? {
        didSet {
            recognizer.isEnabled = onNextWindow != nil
            if onNextWindow == nil { pendingAction = nil }
        }
    }
    private weak var viewport: UIScrollView?
    private weak var terminal: InteractiveTerminalView?
    private var pendingAction: (@MainActor () -> Void)?

    init(viewport: UIScrollView, terminal: InteractiveTerminalView) {
        self.viewport = viewport
        self.terminal = terminal
        super.init()
        recognizer.direction = .right
        recognizer.numberOfTouchesRequired = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.isEnabled = false
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(swiped))
        viewport.addGestureRecognizer(recognizer)
    }

    func canStart(at locationInWindow: CGPoint) -> Bool {
        guard onNextWindow != nil, let viewport, let window = viewport.window,
              terminal?.selectionActive == false else { return false }
        // Keep the system back edge and panning back across wide content intact.
        return locationInWindow.x - window.bounds.minX > 32
            && viewport.contentOffset.x + viewport.adjustedContentInset.left <= 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        pendingAction = nil
        guard let window = viewport?.window, canStart(at: touch.location(in: window)) else { return false }
        // Bind the action to the window touched, not a later SwiftUI update.
        pendingAction = onNextWindow
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        onNextWindow != nil && terminal?.selectionActive == false
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

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let viewport, let otherView = otherGestureRecognizer.view else { return false }
        return otherGestureRecognizer is UIPanGestureRecognizer
            && (otherView === viewport || otherView.isDescendant(of: viewport))
    }

    @objc private func swiped() {
        defer { pendingAction = nil }
        guard recognizer.state == .ended, onNextWindow != nil, terminal?.selectionActive == false else { return }
        terminal?.cancelCursorNavigation()
        terminal?.cancelQuestionCheck()
        terminal?.cancelMouseScroll()
        pendingAction?()
    }
}
#endif
