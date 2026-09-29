import CtrlxNetworking
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentWindowCapabilityTests {
    @Test("Mac and iOS share a per-Host gate; offline and old Hosts cannot launch agents")
    func launchAvailability() {
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:], supportsAgentWindowLaunch: true))
        #expect(store.agentWindowLaunchUnavailableReason(hostID: "office", isConnected: true) == nil)
        #expect(store.agentWindowLaunchUnavailableReason(hostID: "office", isConnected: false)?.contains("offline") == true)
        #expect(store.agentWindowLaunchUnavailableReason(hostID: "home", isConnected: true)?.contains("Update") == true)
        // Rechecked when Start is tapped, not just when the sheet/popover opens.
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:]))
        #expect(store.agentWindowLaunchUnavailableReason(hostID: "office", isConnected: true)?.contains("Update") == true)
    }

    @Test("Support belongs to one Host and clears on downgrade or disconnect")
    func capabilities() {
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:], supportsAgentWindowLaunch: true))
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:]))
        #expect(store.hostsSupportingAgentWindowLaunch == ["office"])
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:], supportsAgentWindowLaunch: true))
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:]))
        #expect(store.hostsSupportingAgentWindowLaunch == ["home"])
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:], supportsAgentWindowLaunch: false))
        #expect(store.hostsSupportingAgentWindowLaunch.isEmpty)
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:], supportsAgentWindowLaunch: true))
        store.clearSessions(for: "office")
        #expect(store.hostsSupportingAgentWindowLaunch.isEmpty)
    }
}
