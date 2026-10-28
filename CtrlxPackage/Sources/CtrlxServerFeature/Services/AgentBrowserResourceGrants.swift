import CtrlxBrowserBridge
import CtrlxCommon
import CtrlxNetworking
import CtrlxSimulatorProtocol
import Foundation

extension AgentBrowserService {
    var supportsResourceGrants: Bool {
        runtime?.responds(to: #selector(CXBrowserRuntime.setAgentGrant(_:forTab:))) == true
    }

    func setResourceGrant(tabID: UUID, sessionID: UUID, agent: ResourceAgent, owner: SimulatorOwner) throws {
        guard
            let tab = tabs[tabID.uuidString], tab.resourceSessionID == sessionID, tab.owner.isEmpty, !tab.isClosed,
            let runtime, supportsResourceGrants else {
            throw RemoteBrowserError.message("Agent authorization requires the updated native browser runtime and an open human tab.")
        }
        guard remoteControls[tabID] == nil else {
            throw RemoteBrowserError.message("Release Viewer control before authorizing an Agent.")
        }
        let identity: [String: NSNumber] = ["pid": NSNumber(value: owner.pid), "startSeconds": NSNumber(value: owner.startSeconds), "startMicros": NSNumber(value: owner.startMicros)]
        guard runtime.setAgentGrant?(identity, forTab: tab.identifier) == true else {
            throw RemoteBrowserError.message("The page is busy or the Agent exited. No authorization was granted.")
        }
        tab.grant = .init(agent: agent, canWrite: true)
        publishBrowserTabs()
    }

    func revokeResourceGrant(tabID: UUID, sessionID: UUID) throws {
        guard
            let tab = tabs[tabID.uuidString], tab.resourceSessionID == sessionID,
            runtime?.setAgentGrant?(nil, forTab: tab.identifier) == true else {
            throw RemoteBrowserError.message("The human browser tab is no longer available.")
        }
        tab.grant = nil
        publishBrowserTabs()
    }
}
