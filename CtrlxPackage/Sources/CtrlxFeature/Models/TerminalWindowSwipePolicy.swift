import Foundation

enum TerminalWindowSwipePolicy {
    enum Direction: Equatable, Sendable {
        case next
        case previous
    }

    static func direction(translation: CGPoint) -> Direction? {
        guard abs(translation.x) > abs(translation.y) * 1.5 else { return nil }
        return translation.x < 0 ? .next : .previous
    }

    static func shouldSwitch(translation: CGPoint, startedDirection: Direction) -> Bool {
        abs(translation.x) >= 64 && direction(translation: translation) == startedDirection
    }
}
