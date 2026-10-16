import Foundation
import Testing
@testable import CtrlxNetworking

struct WorkspaceIdentityWireTests {
    @Test("Creation replies preserve their original incarnation and remain compatible with old peers")
    func creationResponseCompatibility() throws {
        let scope = WorkspaceIdentityScope(hostID: UUID(), serverID: "123:456")
        let message = CommandResponseMessage(commandId: UUID(), success: true, paneId: "%1", createdPaneScope: scope)
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: data).createdPaneScope == scope)
        struct Legacy: Codable {
            let commandId: UUID
            let success: Bool
            let paneId: String?
        }
        let legacy = try JSONDecoder().decode(Legacy.self, from: data)
        #expect(legacy.paneId == "%1")
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(legacy)).createdPaneScope == nil)
    }

    @Test("Agent response identities are optional and preserved when routed to a pairing")
    func responseCompatibility() throws {
        let identity = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let message = AgentResponseSubmissionMessage(pairId: "", sessionId: "%7", pluginId: "echo", requestId: "request", response: .prompt(text: "hello"), expectedWorkspacePane: identity).withPairId("pair")
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(AgentResponseSubmissionMessage.self, from: data) == message)
        #expect(message.pairId == "pair" && message.expectedWorkspacePane == identity)
        struct Legacy: Codable {
            let pairId: String
            let sessionId: String
            let pluginId: String
            let requestId: String
            let response: AgentResponse
        }
        let legacy = try JSONDecoder().decode(Legacy.self, from: data)
        #expect(legacy.requestId == message.requestId && legacy.response == message.response)
        #expect(try JSONDecoder().decode(AgentResponseSubmissionMessage.self, from: JSONEncoder().encode(legacy)).expectedWorkspacePane == nil)
    }

    @Test("Editor request identity is optional on the wire and requires an actual Host response")
    func editorCompatibility() throws {
        let id = UUID()
        let submit = SubmitEditorContent(content: "unsent", expectedSessionID: id)
        let cancel = CancelEditorSession(expectedSessionID: id)
        #expect(try JSONDecoder().decode(SubmitEditorContent.self, from: JSONEncoder().encode(submit)) == submit)
        #expect(try JSONDecoder().decode(CancelEditorSession.self, from: JSONEncoder().encode(cancel)) == cancel)
        #expect(submit.commandType.requiresResponse && cancel.commandType.requiresResponse)
        struct LegacySubmit: Codable { let content: String }
        struct LegacyCancel: Codable { }
        #expect(try JSONDecoder().decode(SubmitEditorContent.self, from: JSONEncoder().encode(LegacySubmit(content: "old"))).expectedSessionID == nil)
        #expect(try JSONDecoder().decode(CancelEditorSession.self, from: JSONEncoder().encode(LegacyCancel())).expectedSessionID == nil)
        #expect(try JSONDecoder().decode(LegacySubmit.self, from: JSONEncoder().encode(submit)).content == submit.content)
        _ = try JSONDecoder().decode(LegacyCancel.self, from: JSONEncoder().encode(cancel))
    }

    @Test("Workspace identity fields are optional and survive pair-specific snapshot forwarding")
    func compatibility() throws {
        let identity = WorkspacePaneIdentity(serverID: "pid:boot", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let scope = WorkspaceIdentityScope(hostID: UUID(), serverID: identity.serverID)
        let pane = PaneState(paneId: "%1", workspaceIdentity: identity)
        let message = SessionStateMessage(pairId: "", paneStates: ["%1": pane], workspaceIdentity: scope, supportsWorkspaceInputIdentity: true).withPairId("paired")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: data)
        #expect(decoded.workspaceIdentity == scope && decoded.paneStates["%1"]?.workspaceIdentity == identity)
        #expect(decoded.pairId == "paired")
        #expect(decoded.supportsWorkspaceInputIdentity == true)
        struct Legacy: Decodable {
            struct Pane: Decodable { let paneId: String }
            let pairId: String
            let paneStates: [String: Pane]
        }
        #expect(try JSONDecoder().decode(Legacy.self, from: data).paneStates["%1"]?.paneId == "%1")
        let legacyData = try JSONEncoder().encode(SessionStateMessage(pairId: "old", paneStates: ["%1": .init(paneId: "%1")]))
        let legacy = try JSONDecoder().decode(SessionStateMessage.self, from: legacyData)
        #expect(legacy.workspaceIdentity == nil && legacy.paneStates["%1"]?.workspaceIdentity == nil)
        #expect(legacy.supportsWorkspaceInputIdentity == nil)
        let command = CommandMessage(paneId: "%1", command: SendKeystroke([.enter]).commandType, expectedWorkspacePane: identity)
        let guarded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
        #expect(guarded.expectedWorkspacePane == identity)
        let oldCommand = CommandMessage(paneId: "%1", command: SendKeystroke([.enter]).commandType)
        #expect(try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(oldCommand)).expectedWorkspacePane == nil)
        #expect(!oldCommand.command.requiresResponse)
        let acknowledged = SendKeystroke([.text("draft"), .enter], acknowledgeCompletion: true)
        let roundTrip = try JSONDecoder().decode(SendKeystroke.self, from: JSONEncoder().encode(acknowledged))
        #expect(roundTrip.commandType.requiresResponse)
        struct LegacyKeys: Decodable { let keystrokes: [TmuxKey] }
        #expect(try JSONDecoder().decode(LegacyKeys.self, from: JSONEncoder().encode(acknowledged)).keystrokes == acknowledged.keystrokes)
    }
}
