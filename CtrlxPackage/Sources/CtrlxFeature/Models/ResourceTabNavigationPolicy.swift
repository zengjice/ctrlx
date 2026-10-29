import Foundation

enum ResourceTabNavigationPolicy {
    enum Action: Equatable, Sendable {
        case previous
        case next
        case source
        case tabs
    }

    static func start(translation: CGPoint, canSwitch: Bool) -> Action? {
        if canSwitch, let direction = TerminalWindowSwipePolicy.direction(translation: translation) {
            return direction == .next ? .next : .previous
        }
        return TerminalBarSwipePolicy.direction(translation: translation) == .up ? .tabs : nil
    }

    static func completes(translation: CGPoint, action: Action) -> Bool {
        switch action {
        case .previous: TerminalWindowSwipePolicy.shouldSwitch(translation: translation, startedDirection: .previous)
        case .next: TerminalWindowSwipePolicy.shouldSwitch(translation: translation, startedDirection: .next)
        case .tabs: TerminalBarSwipePolicy.completes(translation: translation, startedDirection: .up)
        case .source: false
        }
    }
}
