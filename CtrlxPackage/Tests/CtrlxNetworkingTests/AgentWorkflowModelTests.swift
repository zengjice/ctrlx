import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentWorkflowModelTests {
    private func graph() -> AgentWorkflowDefinition {
        let nodes = ["Developer", "Reviewer A", "Reviewer B", "Summary"].map {
            AgentWorkflowNode(name: $0, agentInstanceID: UUID())
        }
        return .init(name: "Review", hostID: UUID(), nodes: nodes, edges: [
            .init(source: nodes[0].id, target: nodes[1].id),
            .init(source: nodes[0].id, target: nodes[2].id),
            .init(source: nodes[1].id, target: nodes[3].id),
            .init(source: nodes[2].id, target: nodes[3].id),
        ], entryNodeID: nodes[0].id)
    }

    @Test
    func diamondSupportsFanOutAndOrderedFanIn() throws {
        let definition = graph()
        try definition.validate()
        #expect(definition.upstream(of: definition.nodes[3].id).map(\.name) == ["Reviewer A", "Reviewer B"])
        var reordered = definition
        reordered.edges.reverse()
        #expect(reordered.upstream(of: definition.nodes[3].id) == definition.upstream(of: definition.nodes[3].id))
    }

    @Test(arguments: ["cycle", "self", "unknown", "duplicate-edge", "disconnected", "duplicate-node", "duplicate-instance", "missing-entry", "empty-role", "zero-revision"])
    func rejectsInvalidGraphs(scenario: String) {
        var definition = graph()
        let nodes = definition.nodes
        switch scenario {
        case "cycle": definition.edges.append(.init(source: nodes[3].id, target: nodes[1].id))
        case "self": definition.edges.append(.init(source: nodes[1].id, target: nodes[1].id))
        case "unknown": definition.edges.append(.init(source: nodes[1].id, target: UUID()))
        case "duplicate-edge": definition.edges.append(definition.edges[0])
        case "disconnected": definition.edges.removeAll { $0.target == nodes[2].id }
        case "duplicate-node": definition.nodes.append(nodes[0])
        case "duplicate-instance": definition.nodes[1].agentInstanceID = nodes[0].agentInstanceID
        case "missing-entry": definition.entryNodeID = UUID()
        case "empty-role": definition.nodes[0].name = " \n"
        default: definition.revision = 0
        }
        #expect(throws: AgentWorkflowError.self) { try definition.validate() }
    }

    @Test
    func loopMustWaitForAllBranches() throws {
        var definition = graph()
        definition.loop = .init(finalNodeID: definition.nodes[3].id)
        try definition.validate()
        definition.loop?.finalNodeID = definition.nodes[1].id
        #expect(throws: AgentWorkflowError.self) { try definition.validate() }
        definition.loop?.finalNodeID = definition.nodes[3].id
        definition.edges.removeAll { $0.source == definition.nodes[2].id }
        #expect(throws: AgentWorkflowError.self) { try definition.validate() }
    }

    @Test
    func entryCannotHaveAnIncomingLoopEdge() {
        var definition = graph()
        definition.edges.append(.init(source: definition.nodes[3].id, target: definition.entryNodeID))
        #expect(throws: AgentWorkflowError.self) { try definition.validate() }
    }

    @Test
    func configuredSkillsMediaAndGraphSurviveWireRoundTrip() throws {
        var definition = graph()
        definition.nodes[1].input = .init(text: "$review-changes\n检查功能、边界和测试。", attachmentIDs: [UUID()])
        definition.nodes[3].allowsFinish = true
        definition.loop = .init(finalNodeID: definition.nodes[3].id)
        let data = try JSONEncoder().encode(definition)
        #expect(try JSONDecoder().decode(AgentWorkflowDefinition.self, from: data) == definition)
    }

    @Test
    func creationDestinationIsOptionalAndUsesStableSessionIdentity() throws {
        var definition = graph()
        let oldData = try JSONEncoder().encode(definition)
        #expect(try JSONDecoder().decode(AgentWorkflowDefinition.self, from: oldData).creationSession == nil)
        let identity = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        definition.creationSession = .init(identity)
        #expect(try JSONDecoder().decode(AgentWorkflowDefinition.self, from: JSONEncoder().encode(definition)) == definition)
        var moved = identity
        moved.windowID = UUID()
        moved.paneID = UUID()
        #expect(AgentWorkflowSessionReference(moved) == definition.creationSession)
        moved.serverID = "replacement-server"
        #expect(AgentWorkflowSessionReference(moved) != definition.creationSession)
    }

    @Test
    func legacyAgentNodesAndContentNodesRoundTrip() throws {
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: UUID())
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        legacy.removeValue(forKey: "kind")
        #expect(try JSONDecoder().decode(AgentWorkflowNode.self, from: JSONSerialization.data(withJSONObject: legacy)) == node)
        let content = AgentWorkflowNode(name: "Review instructions", content: .init(text: "$review-changes", attachmentIDs: [UUID()]))
        #expect(try JSONDecoder().decode(AgentWorkflowNode.self, from: JSONEncoder().encode(content)) == content)
        let definition = AgentWorkflowDefinition(name: "Content", hostID: UUID(), nodes: [content], edges: [], entryNodeID: content.id)
        try definition.validate()
        #expect(definition.agentInstanceIDs.isEmpty)
    }

    @Test(arguments: ["content-binding", "content-finish", "missing-agent"])
    func nodeKindsEnforceIdentityAndFinishPermissions(scenario: String) {
        var node = AgentWorkflowNode(name: "Content", content: .init())
        switch scenario {
        case "content-binding": node.agentInstanceID = UUID()
        case "content-finish": node.allowsFinish = true
        default:
            node = .init(name: "Agent", agentInstanceID: UUID())
            node.agentInstanceID = nil
        }
        let definition = AgentWorkflowDefinition(name: "Invalid", hostID: UUID(), nodes: [node], edges: [], entryNodeID: node.id)
        #expect(throws: AgentWorkflowError.self) { try definition.validate() }
    }
}
