import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentIDTests {
    @Test
    func legacyTargetPreservesWireAndExtractsIdentity() throws {
        let host = UUID(), pane = UUID()
        let first = AgentWorkflowTarget(hostID: host, windowID: UUID(), paneID: pane)
        let moved = AgentWorkflowTarget(hostID: host, windowID: UUID(), paneID: pane)
        #expect(first.agentID == moved.agentID)
        #expect(first != moved)
        let data = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(AgentWorkflowTarget.self, from: data)
        #expect(decoded == first)
        #expect(try JSONDecoder().decode(AgentID.self, from: data) == first.agentID)
        #expect(try JSONDecoder().decode(AgentID.self, from: JSONEncoder().encode(first.agentID)) == first.agentID)
    }

    @Test
    func missingAndAmbiguousAreDistinctAndNeverSelectFirst() {
        let id = AgentID(hostID: UUID(), paneID: UUID())
        let otherHost = AgentID(hostID: UUID(), paneID: id.paneID)
        let otherPane = AgentID(hostID: id.hostID, paneID: UUID())
        #expect(id.resolve(in: [otherHost, otherPane, id], identity: { $0 }).value == id)
        guard case .missing = id.resolve(in: [otherHost, otherPane], identity: { $0 }) else {
            Issue.record("Different Host/pane must not resolve")
            return
        }
        guard case .ambiguous = id.resolve(in: [id, otherHost, id], identity: { $0 }) else {
            Issue.record("Duplicate identity must be rejected")
            return
        }
    }
}
