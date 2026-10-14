import Foundation
import Testing
@testable import CtrlxNetworking

struct CodexQuestionAcknowledgementTests {
    @Test("Legacy snapshots and responses cannot imply question acknowledgement support")
    func compatibility() throws {
        let legacy = SessionStateMessage(pairId: "old", paneStates: [:])
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.supportsCodexQuestionAcknowledgement == nil)
        let modern = SessionStateMessage(pairId: "", paneStates: [:], supportsCodexQuestionAcknowledgement: true)
        let copy = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(modern.withPairId("new")))
        #expect(copy.pairId == "new")
        #expect(copy.supportsCodexQuestionAcknowledgement == true)
        let oldResponse = CommandResponseMessage.success(for: UUID())
        let response = try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(oldResponse))
        #expect(response.codexQuestionsHandled == nil)
    }

    @Test("Handled and deferred results retain command identity", arguments: [true, false])
    func response(handled: Bool) throws {
        let command = CommandMessage(paneId: "%7", command: ExpandCodexQuestions(expectedCount: 1).commandType)
        #expect(command.command.requiresResponse)
        let response = CommandResponseMessage(commandId: command.id, success: true, codexQuestionsHandled: handled)
        let copy = try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response))
        #expect(copy.commandId == command.id)
        #expect(copy.codexQuestionsHandled == handled)
    }

    @Test("Question identity is additive and survives pane snapshots and commands")
    func questionIdentityCompatibility() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let legacy = try decoder.decode(ExpandCodexQuestions.self, from: Data(#"{"expectedCount":1}"#.utf8))
        #expect(legacy.expectedQuestionID == nil)
        let intent = ExpandCodexQuestions(expectedCount: 1, expectedQuestionID: "session:call-b")
        #expect(try decoder.decode(ExpandCodexQuestions.self, from: encoder.encode(intent)) == intent)
        let pane = PaneState(paneId: "%7", codexQuestionID: "session:call-b")
        let snapshot = SessionStateMessage(pairId: "host", paneStates: ["%7": pane])
        let copy = try decoder.decode(SessionStateMessage.self, from: encoder.encode(snapshot.withPairId("viewer")))
        #expect(copy.paneStates["%7"]?.codexQuestionID == "session:call-b")
        let oldPane = try decoder.decode(PaneState.self, from: encoder.encode(PaneState(paneId: "%7")))
        #expect(oldPane.codexQuestionID == nil)
        let notification = try decoder.decode(NotificationSpec.self, from: Data(#"{"title":"Question","body":"body","isQuestion":true}"#.utf8))
        #expect(notification.questionID == nil)
    }
}
