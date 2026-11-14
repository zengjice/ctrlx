import Foundation
import Testing
@testable import CtrlxNetworking

struct StableNotificationTests {
    @Test
    func encryptedContentAndActionPreserveSeparateIdentities() throws {
        let id = AgentID(hostID: UUID(), paneID: UUID())
        var pane = PaneState(
            paneId: "%1",
            agentSession: .init(paneId: "%1", pluginID: "opencode"),
            claudeSessionID: "ses_native",
            workspaceIdentity: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: id.paneID)
        )
        pane.agentSession?.processRuntimeID = "runtime"
        let binding = try #require(AgentNotificationBinding(agentID: id, pane: pane))
        let action = NotificationActionContext(sessionId: "%1", pluginId: "opencode", requestId: "request", form: .permission(.init(alwaysSuggestionID: nil)), agent: binding)
        let content = NotificationContent(title: "Title", body: "Question", eventType: "agent.question", pairId: "pair", paneId: "%1", agentID: id, action: action)
        let decoded = try JSONDecoder().decode(NotificationContent.self, from: JSONEncoder().encode(content))
        #expect(decoded.agentID == id && decoded.action?.agent == binding)
        #expect(content.forPeer(supportsStableAgentNotifications: true) == content)
        let oldPeer = content.forPeer(supportsStableAgentNotifications: false)
        #expect(oldPeer.agentID == nil && oldPeer.paneId == nil && oldPeer.action == nil)
        #expect(oldPeer.pairId == content.pairId && oldPeer.body == content.body)
        let unproven = NotificationContent(title: "Title", body: "Question", eventType: "agent.question", pairId: "pair", paneId: "%1", action: action)
        #expect(unproven.forPeer(supportsStableAgentNotifications: true).action == nil)
        #expect(unproven.forPeer(supportsStableAgentNotifications: true).paneId == nil)
        pane.workspaceIdentity?.windowID = UUID()
        pane.workspaceIdentity?.sessionID = UUID()
        #expect(binding.matches(agentID: id, pane: pane))
        pane.agentSession?.processRuntimeID = "replacement"
        #expect(!binding.matches(agentID: id, pane: pane))
        pane.agentSession?.processRuntimeID = "runtime"
        pane.claudeSessionID = "ses_new"
        #expect(!binding.matches(agentID: id, pane: pane))
        let old = Data(#"{"title":"Title","body":"Old","eventType":"cli.notify","pairId":"pair","paneId":"%1","timestamp":0}"#.utf8)
        #expect(try JSONDecoder().decode(NotificationContent.self, from: old).agentID == nil)
    }

    @Test
    func oldHelloDoesNotAdvertiseStableNotifications() throws {
        let new = PeerHelloMessage(appVersion: "3.1.0", minRequiredPartnerVersion: "3.0.0")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(new)) as? [String: Any])
        json.removeValue(forKey: "supportsStableAgentNotifications")
        let old = try JSONDecoder().decode(PeerHelloMessage.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.supportsStableAgentNotifications == nil)
        #expect(new.supportsStableAgentNotifications == true)
    }
}
