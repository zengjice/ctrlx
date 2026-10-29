import Foundation
import Testing
@testable import CtrlxFeature

struct ResourceTabNavigationPolicyTests {
    @Test(arguments: [-1.0, 1.0])
    func horizontalNavigationUsesExistingDirectionAndThreshold(sign: Double) {
        let action: ResourceTabNavigationPolicy.Action = sign < 0 ? .next : .previous
        #expect(ResourceTabNavigationPolicy.start(translation: CGPoint(x: sign * 20, y: 1), canSwitch: true) == action)
        #expect(!ResourceTabNavigationPolicy.completes(translation: CGPoint(x: sign * 63, y: 0), action: action))
        #expect(ResourceTabNavigationPolicy.completes(translation: CGPoint(x: sign * 64, y: 0), action: action))
        #expect(!ResourceTabNavigationPolicy.completes(translation: CGPoint(x: sign * -80, y: 0), action: action))
        #expect(!ResourceTabNavigationPolicy.completes(translation: CGPoint(x: 0, y: -80), action: action))
    }

    @Test
    func independentTabsOnlyOfferUpwardNavigation() {
        #expect(ResourceTabNavigationPolicy.start(translation: CGPoint(x: 80, y: 0), canSwitch: false) == nil)
        #expect(ResourceTabNavigationPolicy.start(translation: CGPoint(x: -80, y: 0), canSwitch: false) == nil)
        #expect(ResourceTabNavigationPolicy.start(translation: CGPoint(x: 1, y: -20), canSwitch: false) == .tabs)
        #expect(!ResourceTabNavigationPolicy.completes(translation: CGPoint(x: 1, y: -31), action: .tabs))
        #expect(ResourceTabNavigationPolicy.completes(translation: CGPoint(x: 1, y: -32), action: .tabs))
        #expect(!ResourceTabNavigationPolicy.completes(translation: CGPoint(x: 1, y: 80), action: .tabs))
    }

    @Test(arguments: [CGPoint.zero, CGPoint(x: 20, y: 20), CGPoint(x: 1, y: 80)])
    func ambiguousAndDownwardGesturesDoNothing(translation: CGPoint) {
        #expect(ResourceTabNavigationPolicy.start(translation: translation, canSwitch: true) == nil)
    }
}
