#if os(iOS)
    import CtrlxCommon
    import UIKit

    /// UI-only clock for app-owned scrolling. No terminal bytes are buffered,
    /// dropped, or predicted; each tick emits ordinary wheel input.
    @MainActor
    final class TerminalMouseScrollAnimator {
        private var motion = TerminalScrollDeceleration()
        private nonisolated(unsafe) var displayLink: CADisplayLink?
        private let emit: @MainActor (Double) -> Bool

        var isActive: Bool { motion.isActive }

        init(emit: @escaping @MainActor (Double) -> Bool) {
            self.emit = emit
        }

        deinit {
            displayLink?.invalidate()
        }

        func start(velocity: Double) {
            cancel()
            motion.start(velocity: velocity, timestamp: CACurrentMediaTime())
            guard motion.isActive else { return }
            let target = DisplayLinkTarget()
            target.owner = self
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func cancel() {
            motion.cancel()
            displayLink?.invalidate()
            displayLink = nil
        }

        private func tick(_: CADisplayLink) {
            guard UIApplication.shared.applicationState == .active else {
                cancel()
                return
            }
            let delta = motion.advance(to: CACurrentMediaTime())
            if (delta != 0 && !emit(delta)) || !motion.isActive { cancel() }
        }

        /// CADisplayLink retains its target. A weak hop prevents a detached
        /// terminal being kept alive by the run loop until the next tick.
        @MainActor
        private final class DisplayLinkTarget: NSObject {
            weak var owner: TerminalMouseScrollAnimator?
            @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
        }
    }

    /// Stop coasting at touch-down, before the pan/tap arbitration delay. This
    /// does not add another recognizer or change who wins selection/link taps.
    final class TerminalMousePanGestureRecognizer: UIPanGestureRecognizer {
        var onTouchDown: (@MainActor () -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouchDown?()
            super.touchesBegan(touches, with: event)
        }
    }
#endif
