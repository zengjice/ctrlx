import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("iOS APNs notification delivery")
struct NotificationDeliveryTests {
    @Test("Question metadata survives the APNs content round trip")
    func foregroundQuestion() throws {
        let content = NotificationContent(
            title: "cm · dev", body: "Which directory?", eventType: "agent.question",
            pairId: "office", paneId: "%7"
        )
        let decoded = try JSONDecoder().decode(NotificationContent.self, from: JSONEncoder().encode(content))
        #expect(decoded.action == nil)
        #expect(try NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: userInfo(for: decoded)))
    }

    @Test("Older Host structured questions alert even with cli.notify event type")
    func legacyStructuredQuestion() throws {
        let action = NotificationActionContext(
            sessionId: "%7", pluginId: "codex", requestId: "request",
            form: .askUserQuestion(.init(questions: [.init(
                id: "directory", question: "Which directory?",
                options: [.init(id: "current", label: "Current")], allowsFreeText: true
            )]))
        )
        let content = NotificationContent(
            title: "cm · dev", body: "Which directory?", eventType: "cli.notify",
            pairId: "office", paneId: "%7", action: action
        )
        let decoded = try JSONDecoder().decode(NotificationContent.self, from: JSONEncoder().encode(content))
        #expect(decoded.eventType == "cli.notify")
        #expect(try NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: userInfo(for: decoded)))
    }

    @Test("Permission requests alert while malformed contexts remain quiet")
    func nonQuestionActions() throws {
        let content = NotificationContent(
            title: "Permission", body: "Allow tool?", eventType: "cli.notify", pairId: "office",
            action: .init(sessionId: "%7", pluginId: "codex", requestId: "request", form: .permission(.init(alwaysSuggestionID: nil)))
        )
        #expect(try NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: userInfo(for: content)))
        let malformedContextIsVisible = NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: [
            "eventType": "cli.notify", NotificationUserInfoKey.actionContext: "invalid JSON",
        ])
        #expect(!malformedContextIsVisible)
    }

    @Test("Ordinary remote activity stays quiet in foreground", arguments: ["cli.notify", "badge.update", ""])
    func foregroundActivity(event: String) {
        #expect(!NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: ["eventType": event]))
    }

    @Test("Workflow completion keeps its type through both Viewer transports")
    func workflowCompletionRouting() throws {
        let type = NotificationDelivery.workflowCompletionEventType
        let content = NotificationContent(title: "Workflow completed", body: "Review", eventType: type, pairId: "office")
        let push = try JSONDecoder().decode(NotificationContent.self, from: JSONEncoder().encode(content.forPeer(supportsStableAgentNotifications: false)))
        #expect(try NotificationDelivery.isWorkflowCompletion(userInfo: userInfo(for: push)))

        let live = AgentNotificationMessage(pairId: content.pairId, sessionId: nil, title: content.title, body: content.body, timestamp: content.timestamp, eventType: type)
        let remote = try JSONDecoder().decode(AgentNotificationMessage.self, from: JSONEncoder().encode(live)).withPairId("remote-office")
        #expect(remote.eventType == type && remote.pairId == "remote-office")

        let legacy = Data(#"{"pairId":"office","title":"Finished","body":"Agent reply","timestamp":0}"#.utf8)
        #expect(try JSONDecoder().decode(AgentNotificationMessage.self, from: legacy).eventType == nil)
        #expect(!NotificationDelivery.isWorkflowCompletion(userInfo: ["pairId": "office", "eventType": "cli.notify"]))
    }

    @Test(arguments: [NotificationDelivery.workflowCompletionEventType, NotificationDelivery.workflowAttentionEventType])
    func workflowRoutesSurviveOldPeerNegotiationAndAlertInForeground(type: String) throws {
        let target = AgentWorkflowNotificationTarget(hostID: UUID(), runID: UUID(), eventID: UUID())
        let content = NotificationContent(title: "Workflow", body: "Review", eventType: type, pairId: "office", workflow: target)
        let decoded = try JSONDecoder().decode(NotificationContent.self, from: JSONEncoder().encode(content.forPeer(supportsStableAgentNotifications: false)))
        #expect(decoded.workflow == target && decoded.agentID == nil)
        #expect(AgentWorkflowNotificationTarget(userInfo: target.userInfo) == target)
        #expect(NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: ["eventType": type]))
        let live = AgentNotificationMessage(pairId: "office", sessionId: nil, title: content.title, body: content.body, timestamp: content.timestamp, eventType: type, workflow: target)
        let remote = try JSONDecoder().decode(AgentNotificationMessage.self, from: JSONEncoder().encode(live)).withPairId("authenticated-route")
        #expect(remote.workflow == target && remote.pairId == "authenticated-route")
        #expect(AgentWorkflowNotificationTarget(userInfo: ["workflowRunID": UUID().uuidString]) == nil)
    }

    @Test("Local question follow-ups and delivery failures remain visible")
    func localNotifications() {
        #expect(NotificationDelivery.shouldPresentInForeground(isRemote: false, userInfo: [:]))
        #expect(!NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: [:]))
    }

    @Test("Dedupe follows stable targets across moves and never a reused raw ID")
    func notificationScope() {
        let agent = AgentID(hostID: UUID(), paneID: UUID())
        let other = AgentID(hostID: agent.hostID, paneID: UUID())
        func info(_ id: AgentID, _ pair: String, _ pane: String) -> [AnyHashable: Any] {
            var result: [AnyHashable: Any] = ["pairId": pair, "paneId": pane]
            for (key, value) in id.notificationUserInfo {
                result[key] = value
            }
            return result
        }
        let delivered = [info(agent, "home", "%0"), info(other, "home", "%0"), info(agent, "office", "%0"), info(agent, "home", "%9"), ["pairId": "home", "paneId": "%0"]]
        let replaced = delivered.indices.filter { NotificationDelivery.matchesAgent(userInfo: delivered[$0], pairId: "home", agentID: agent) }
        #expect(replaced == [0, 3])
    }

    /// Matches the NSE's decrypted metadata and JSON action-context representation.
    private func userInfo(for content: NotificationContent) throws -> [AnyHashable: Any] {
        var result: [AnyHashable: Any] = ["eventType": content.eventType]
        if let action = content.action {
            result[NotificationUserInfoKey.actionContext] = try String(decoding: JSONEncoder().encode(action), as: UTF8.self)
        }
        return result
    }
}
