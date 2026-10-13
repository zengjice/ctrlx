import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Question notification delivery")
struct QuestionNotificationDeliveryTests {
    @Test("Questions alert in foreground and background without action buttons")
    func questionDelivery() throws {
        let message = notification(isQuestion: true)
        #expect(message.shouldPresent(isAppActive: true))
        #expect(message.shouldPresent(isAppActive: false))
        #expect(message.action == nil)
        let decoded = try JSONDecoder().decode(AgentNotificationMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
        #expect(decoded.withPairId("another-host").isQuestionNotification)
        #expect(decoded.withPairId("another-host").sessionId == "%7")
    }

    @Test("Older notification payloads retain the existing foreground policy")
    func oldPayload() throws {
        let data = try JSONEncoder().encode(notification())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["isQuestion"] == nil)
        let decoded = try JSONDecoder().decode(AgentNotificationMessage.self, from: data)
        #expect(!decoded.shouldPresent(isAppActive: true))
        #expect(decoded.shouldPresent(isAppActive: false))
        let oldSpec = try JSONDecoder().decode(NotificationSpec.self, from: Data(#"{"title":"Old","body":"body"}"#.utf8))
        #expect(oldSpec.isQuestion == nil)
    }

    @Test("Structured questions from older Hosts also alert in the foreground")
    func structuredQuestion() throws {
        let request = AskUserQuestionRequest(questions: [.init(
            id: "q", question: "Continue?", header: "Choice",
            options: [.init(id: "yes", label: "Yes", description: "Proceed")],
            multiSelect: false, allowsFreeText: true
        )])
        let action = try #require(NotificationActionContext.make(
            state: .awaitingReplies(request, requestID: "request"), sessionId: "%7", pluginId: "codex"
        ))
        let message = notification(action: action)
        #expect(message.isQuestion == nil)
        #expect(message.isQuestionNotification)
        #expect(message.shouldPresent(isAppActive: true))
    }

    private func notification(isQuestion: Bool? = nil, action: NotificationActionContext? = nil) -> AgentNotificationMessage {
        .init(pairId: "office", sessionId: "%7", title: "Question", body: "Which directory?", timestamp: Date(), action: action, isQuestion: isQuestion)
    }
}
