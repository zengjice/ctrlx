#if os(iOS)
    import UIKit
    import UIKit.UIGestureRecognizerSubclass

    /// Reserves a selection drag against navigation without claiming local scrolling.
    @MainActor
    final class TerminalSelectionNavigationGuard: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
        private weak var terminal: InteractiveTerminalView?
        private var startedWithSelection = false

        init(terminal: InteractiveTerminalView) {
            self.terminal = terminal
            super.init(target: nil, action: nil)
            maximumNumberOfTouches = 1
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            startedWithSelection = terminal?.selectionActive == true
            return startedWithSelection
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            startedWithSelection
        }

        override func reset() {
            super.reset()
            startedWithSelection = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            isNavigationGesture(preventedGestureRecognizer)
        }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            isNavigationGesture(otherGestureRecognizer)
        }

        private func isNavigationGesture(_ gesture: UIGestureRecognizer) -> Bool {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController, let navigation = controller.navigationController {
                    if gesture === navigation.interactivePopGestureRecognizer {
                        return true
                    }
                    if #available(iOS 26.0, *) {
                        return gesture === navigation.interactiveContentPopGestureRecognizer
                    }
                    return false
                }
                responder = current.next
            }
            return false
        }
    }
#endif
