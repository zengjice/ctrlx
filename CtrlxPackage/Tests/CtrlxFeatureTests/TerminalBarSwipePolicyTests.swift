import Foundation
import Testing
@testable import CtrlxFeature

@Suite("Terminal bar swipe policy")
struct TerminalBarSwipePolicyTests {
    @Test("Taps, horizontal scrolling and ambiguous diagonals stay with the controls", arguments: [
        CGPoint.zero, CGPoint(x: 80, y: 0), CGPoint(x: -80, y: 8),
        CGPoint(x: 20, y: 20), CGPoint(x: -20, y: -30),
    ])
    func leavesOtherInteractionsAlone(translation: CGPoint) {
        #expect(TerminalBarSwipePolicy.startDirection(translation: translation, elapsed: 0.05) == nil)
    }

    @Test("A held button cannot turn into navigation", arguments: [0.3, 0.5, 2.0])
    func preservesHolds(elapsed: TimeInterval) {
        #expect(TerminalBarSwipePolicy.startDirection(translation: CGPoint(x: 0, y: -15), elapsed: elapsed) == nil)
    }

    @Test("Up opens tabs and down hides the keyboard, with a deliberate distance", arguments: [-1.0, 1.0])
    func deliberateSwipe(sign: Double) {
        let direction: TerminalBarSwipePolicy.Direction = sign < 0 ? .up : .down
        #expect(TerminalBarSwipePolicy.startDirection(translation: CGPoint(x: 2, y: sign * 12), elapsed: 0.1) == direction)
        #expect(!TerminalBarSwipePolicy.completes(translation: CGPoint(x: 0, y: sign * 31), startedDirection: direction))
        #expect(TerminalBarSwipePolicy.completes(translation: CGPoint(x: 8, y: sign * 32), startedDirection: direction))
        #expect(!TerminalBarSwipePolicy.completes(translation: CGPoint(x: 0, y: sign * -50), startedDirection: direction))
        #expect(!TerminalBarSwipePolicy.completes(translation: CGPoint(x: 80, y: sign * 40), startedDirection: direction))
    }
}
