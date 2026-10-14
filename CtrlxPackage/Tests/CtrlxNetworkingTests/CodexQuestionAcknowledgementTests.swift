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
}
