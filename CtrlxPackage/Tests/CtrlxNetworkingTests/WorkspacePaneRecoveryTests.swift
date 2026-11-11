import Foundation
import Testing
@testable import CtrlxNetworking

struct WorkspacePaneRecoveryTests {
    private let recovery = WorkspacePaneRecovery(
        attemptID: UUID(), launchID: UUID(), name: "project / review", reason: "Conversation is saved.",
        canResume: true, canUseShell: true, keepCurrentTerminal: false,
        canRetry: false, blocksInput: true, isReady: true
    )

    @Test("Recovery state is optional for old Hosts and survives per-Viewer routing")
    func stateWire() throws {
        let legacy = PaneState(paneId: "%8")
        let data = try JSONEncoder().encode(legacy)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["workspaceRecovery"] == nil)
        #expect(try JSONDecoder().decode(PaneState.self, from: data).workspaceRecovery == nil)
        var pane = legacy
        pane.workspaceRecovery = recovery
        let message = SessionStateMessage(pairId: "host", paneStates: [pane.paneId: pane]).withPairId("viewer")
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.pairId == "viewer")
        #expect(decoded.paneStates["%8"]?.workspaceRecovery == recovery)
    }

    @Test("Both recovery actions retain the exact attempt, previous launch and workspace identity", arguments: [RecoverWorkspacePane.Action.resume, .useShell])
    func actionWire(action: RecoverWorkspacePane.Action) throws {
        let identity = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let request = RecoverWorkspacePane(paneID: "%8", recovery: recovery, action: action)
        let message = CommandMessage(paneId: "%8", command: request.commandType, expectedWorkspacePane: identity)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.command == request.commandType)
        #expect(decoded.expectedWorkspacePane == identity)
        #expect(decoded.command.requiresResponse)
        #expect(recovery.allows(action))
    }
}
