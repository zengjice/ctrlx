#if os(iOS)
    import SwiftUI
    import UIKit

    /// Attached only to native chrome, never the terminal or keyboard accessory.
    struct TerminalBarSwipeGesture: UIGestureRecognizerRepresentable {
        var isEnabled: Bool
        var onSwipe: (TerminalBarSwipePolicy.Direction) -> Void

        func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
            Coordinator(onSwipe: onSwipe)
        }

        func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
            let recognizer = UIPanGestureRecognizer()
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delegate = context.coordinator
            recognizer.isEnabled = isEnabled
            return recognizer
        }

        func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
            context.coordinator.onSwipe = onSwipe
            recognizer.isEnabled = isEnabled
        }

        func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
            context.coordinator.handle(recognizer)
        }

        @MainActor
        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var onSwipe: (TerminalBarSwipePolicy.Direction) -> Void
            private var touchStartedAt: TimeInterval = 0
            private var pending: (direction: TerminalBarSwipePolicy.Direction, action: (TerminalBarSwipePolicy.Direction) -> Void)?

            init(onSwipe: @escaping (TerminalBarSwipePolicy.Direction) -> Void) {
                self.onSwipe = onSwipe
            }

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
                touchStartedAt = touch.timestamp
                pending = nil
                return true
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard
                    let pan = gestureRecognizer as? UIPanGestureRecognizer,
                    let direction = TerminalBarSwipePolicy.startDirection(
                        translation: pan.translation(in: pan.view?.window),
                        elapsed: ProcessInfo.processInfo.systemUptime - touchStartedAt
                    ) else { return false }
                pending = (direction, onSwipe)
                return true
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
            ) -> Bool {
                // Decide the axis before the first row's horizontal scroll view.
                guard let scroll = otherGestureRecognizer.view as? UIScrollView else { return false }
                return otherGestureRecognizer === scroll.panGestureRecognizer
            }

            func handle(_ recognizer: UIPanGestureRecognizer) {
                switch recognizer.state {
                case .ended:
                    defer { pending = nil }
                    guard
                        recognizer.isEnabled, let pending,
                        TerminalBarSwipePolicy.completes(
                            translation: recognizer.translation(in: recognizer.view?.window),
                            startedDirection: pending.direction
                        ) else { return }
                    pending.action(pending.direction)
                case .cancelled,
                     .failed:
                    pending = nil
                default:
                    break
                }
            }
        }
    }
#endif
