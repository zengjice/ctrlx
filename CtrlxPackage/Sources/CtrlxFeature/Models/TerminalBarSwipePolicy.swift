import Foundation

enum TerminalBarSwipePolicy {
    enum Direction: Equatable, Sendable {
        case up
        case down
    }

    static func direction(translation: CGPoint) -> Direction? {
        guard abs(translation.y) > abs(translation.x) * 1.5 else { return nil }
        return translation.y < 0 ? .up : .down
    }

    static func startDirection(translation: CGPoint, elapsed: TimeInterval) -> Direction? {
        // A held button belongs to its repeat/context-menu interaction.
        guard elapsed < 0.3 else { return nil }
        return direction(translation: translation)
    }

    static func completes(translation: CGPoint, startedDirection: Direction) -> Bool {
        abs(translation.y) >= 32 && direction(translation: translation) == startedDirection
    }
}
