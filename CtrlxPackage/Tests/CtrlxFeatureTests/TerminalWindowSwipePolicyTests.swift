import Foundation
import Testing
@testable import CtrlxFeature

@Suite("Terminal Window swipe policy")
struct TerminalWindowSwipePolicyTests {
    @Test("Stationary, vertical and diagonal drags do not claim navigation", arguments: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0, y: 20), CGPoint(x: 0, y: -20),
        CGPoint(x: 12, y: 12), CGPoint(x: 12, y: -12),
        CGPoint(x: -12, y: 12), CGPoint(x: -12, y: -12),
    ])
    func leavesOtherDirectionsAlone(translation: CGPoint) {
        #expect(TerminalWindowSwipePolicy.direction(translation: translation) == nil)
        #expect(!TerminalWindowSwipePolicy.shouldSwitch(translation: translation, startedDirection: .next))
        #expect(!TerminalWindowSwipePolicy.shouldSwitch(translation: translation, startedDirection: .previous))
    }

    @Test("Finger left selects next; finger right selects previous", arguments: [-1.0, 1.0])
    func shortDrag(sign: Double) {
        let direction: TerminalWindowSwipePolicy.Direction = sign < 0 ? .next : .previous
        #expect(TerminalWindowSwipePolicy.direction(translation: CGPoint(x: sign * 12, y: 2)) == direction)
        #expect(!TerminalWindowSwipePolicy.shouldSwitch(translation: CGPoint(x: sign * 63, y: 0), startedDirection: direction))
    }

    @Test("A completed drag switches in either direction without depending on speed", arguments: [
        CGPoint(x: 64, y: 0), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: -20),
        CGPoint(x: -64, y: 0), CGPoint(x: -100, y: 20), CGPoint(x: -100, y: -20),
    ])
    func completedDrag(translation: CGPoint) {
        let direction: TerminalWindowSwipePolicy.Direction = translation.x < 0 ? .next : .previous
        #expect(TerminalWindowSwipePolicy.shouldSwitch(translation: translation, startedDirection: direction))
    }

    @Test("A drag that reverses or turns vertical does not switch on release", arguments: [-1.0, 1.0])
    func abandonedDrag(sign: Double) {
        let direction: TerminalWindowSwipePolicy.Direction = sign < 0 ? .next : .previous
        #expect(!TerminalWindowSwipePolicy.shouldSwitch(translation: CGPoint(x: sign * -80, y: 0), startedDirection: direction))
        #expect(!TerminalWindowSwipePolicy.shouldSwitch(translation: CGPoint(x: sign * 80, y: 100), startedDirection: direction))
    }

    @Test("Horizontal translations captured on iPhone are recognized as next", arguments: [-6.667, -16.333, -26.333])
    func deviceReportedDirection(x: Double) {
        #expect(TerminalWindowSwipePolicy.direction(translation: CGPoint(x: x, y: 0)) == .next)
    }
}
