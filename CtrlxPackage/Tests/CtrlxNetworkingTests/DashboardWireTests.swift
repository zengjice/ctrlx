import Foundation
import Testing
@testable import CtrlxNetworking

struct DashboardWireTests {
    @Test
    func optionalCapabilitySurvivesRebindingAndOldPeersHaveNone() throws {
        let old = SessionStateMessage(pairId: "a", paneStates: [:])
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(old))
        #expect(decoded.supportsDashboard == nil)
        let modern = SessionStateMessage(pairId: "a", paneStates: [:], supportsDashboard: true)
        let rebound = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(modern.withPairId("b")))
        #expect(rebound.supportsDashboard == true)
        #expect(rebound.pairId == "b")
    }

    @Test
    func lightweightCommandReturnsSnapshotWithoutPaneState() throws {
        let command = CommandMessage(paneId: "", command: ReadDashboard().commandType)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
        #expect(decoded.command == .readDashboard(ReadDashboard()))
        #expect(decoded.command.requiresResponse)
        let snapshot = DashboardSnapshot(hostID: UUID(), generatedAt: Date(), timeZoneIdentifier: "Asia/Shanghai")
        let response = CommandResponseMessage(commandId: command.id, success: true, dashboard: snapshot)
        let copy = try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response))
        #expect(copy.dashboard == snapshot)
        let oldResponse = try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(CommandResponseMessage.success(for: command.id)))
        #expect(oldResponse.dashboard == nil)
    }
}
