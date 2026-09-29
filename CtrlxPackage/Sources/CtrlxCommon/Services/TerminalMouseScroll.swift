import Foundation

/// SGR wheel packets express direction, not a fractional distance. Codex's
/// fullscreen transcript (0.158.0) moves THREE rows per packet. Compensate only
/// precise gestures in that mode; discrete mouse-wheel notches retain their
/// normal meaning, and other TUIs retain the existing sensitivity.
public enum TerminalMouseScroll {
    public static func rowsPerEvent(agentID: String?, alternateScreen: Bool) -> Double {
        agentID == "codex" && alternateScreen ? 3 : 1
    }
}

/// Conserves sub-event motion without letting an old gesture or direction
/// delay a new one. Positive counts mean scroll up (SGR button 64).
public struct TerminalMouseScrollAccumulator: Sendable {
    private var remainder: Double = 0
    private var previousThreshold: Double?

    public init() { }

    public mutating func reset() {
        remainder = 0
        previousThreshold = nil
    }

    public mutating func consume(delta: Double, pointsPerEvent: Double) -> Int {
        guard delta.isFinite, pointsPerEvent.isFinite, pointsPerEvent > 0 else {
            reset()
            return 0
        }
        if previousThreshold != pointsPerEvent || (delta != 0 && remainder * delta < 0) {
            remainder = 0
        }
        previousThreshold = pointsPerEvent
        remainder += delta
        let count = (remainder / pointsPerEvent).rounded(.towardZero)
        // A malformed native event must not overflow Int or allocate an
        // unbounded packet. Real gestures are far below this safety bound.
        guard count.isFinite, abs(count) <= 256 else {
            reset()
            return 0
        }
        remainder -= count * pointsPerEvent
        return Int(count)
    }
}

/// Short, bounded touch momentum in points/second. Uses the exponential decay
/// of UIScrollView's fast rate (0.99 per millisecond), integrated by elapsed
/// time rather than frame count, so 60 and 120 Hz produce the same distance.
/// A stalled display loop stops instead of replaying a large catch-up jump.
public struct TerminalScrollDeceleration: Sendable {
    public private(set) var isActive = false
    private var velocity: Double = 0
    private var lastTimestamp: TimeInterval = 0
    private var endTimestamp: TimeInterval = 0
    private static let decay = -log(0.99) * 1_000

    public init() { }

    public mutating func start(velocity: Double, timestamp: TimeInterval) {
        cancel()
        guard velocity.isFinite, timestamp.isFinite, abs(velocity) >= 80 else { return }
        self.velocity = min(max(velocity, -2_400), 2_400)
        lastTimestamp = timestamp
        endTimestamp = timestamp + 0.6
        isActive = true
    }

    public mutating func cancel() {
        isActive = false
        velocity = 0
    }

    public mutating func advance(to timestamp: TimeInterval) -> Double {
        guard isActive else { return 0 }
        let elapsed = timestamp - lastTimestamp
        guard timestamp.isFinite, elapsed >= 0, elapsed <= 0.1, timestamp <= endTimestamp else {
            cancel()
            return 0
        }
        lastTimestamp = timestamp
        let fraction = exp(-Self.decay * elapsed)
        let distance = velocity * (1 - fraction) / Self.decay
        velocity *= fraction
        if abs(velocity) < 20 { cancel() }
        return distance
    }
}
