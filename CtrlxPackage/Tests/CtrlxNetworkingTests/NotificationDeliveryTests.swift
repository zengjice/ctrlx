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
        #expect(try NotificationDelivery.matchesPane(
            userInfo: ["pairId": decoded.pairId, "paneId": #require(decoded.paneId)],
            pairId: "office", paneId: "%7"
        ))
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

    @Test("Permission actions and malformed contexts do not turn activity into questions")
    func nonQuestionActions() throws {
        let content = NotificationContent(
            title: "Permission", body: "Allow tool?", eventType: "cli.notify", pairId: "office",
            action: .init(sessionId: "%7", pluginId: "codex", requestId: "request", form: .permission(.init(alwaysSuggestionID: nil)))
        )
        #expect(try !NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: userInfo(for: content)))
        let malformedContextIsVisible = NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: [
            "eventType": "cli.notify", NotificationUserInfoKey.actionContext: "invalid JSON",
        ])
        #expect(!malformedContextIsVisible)
    }

    @Test("Ordinary remote activity stays quiet in foreground", arguments: ["cli.notify", "badge.update", ""])
    func foregroundActivity(event: String) {
        #expect(!NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: ["eventType": event]))
    }

    @Test("Local question follow-ups and delivery failures remain visible")
    func localNotifications() {
        #expect(NotificationDelivery.shouldPresentInForeground(isRemote: false, userInfo: [:]))
        #expect(!NotificationDelivery.shouldPresentInForeground(isRemote: true, userInfo: [:]))
    }

    @Test("Replacing a pane alert retains notifications from other Hosts and panes")
    func notificationScope() {
        let delivered: [[AnyHashable: Any]] = [
            ["pairId": "home", "paneId": "%0"],
            ["pairId": "office", "paneId": "%0"],
            ["pairId": "home", "paneId": "%1"],
            ["paneId": "%0"],
            ["pairId": "home"],
        ]
        let replaced = delivered.indices.filter {
            NotificationDelivery.matchesPane(userInfo: delivered[$0], pairId: "home", paneId: "%0")
        }
        #expect(replaced == [0])
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
