import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentWorkflowModelSelectionTests {
    @Test
    func stepSelectionsRoundTripAndOlderNodesInheritCurrentSettings() throws {
        let agent = UUID()
        let first = AgentWorkflowNode(name: "Develop", agentInstanceID: agent, modelSelection: .init(model: "fast", effort: "low"))
        let second = AgentWorkflowNode(name: "Review", agentInstanceID: agent, modelSelection: .init(model: "strong", effort: "high"))
        let definition = AgentWorkflowDefinition(name: "One Agent", hostID: UUID(), nodes: [first, second], edges: [.init(source: first.id, target: second.id)], entryNodeID: first.id)
        try AgentWorkflowWire.validate(definition)
        #expect(try JSONDecoder().decode(AgentWorkflowDefinition.self, from: JSONEncoder().encode(definition)) == definition)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        legacy.removeValue(forKey: "modelSelection")
        #expect(try JSONDecoder().decode(AgentWorkflowNode.self, from: JSONSerialization.data(withJSONObject: legacy)).modelSelection == nil)
        let request = ManageAgentWorkflows(.models(instanceID: agent, refresh: true))
        #expect(!request.operation.isMutation)
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType)) == request.commandType)
        var response = AgentWorkflowResponse(hostID: definition.hostID)
        response.modelSnapshot = .init(runtimeID: "runtime", models: [], selection: first.modelSelection, unavailableReason: nil)
        #expect(try JSONDecoder().decode(AgentWorkflowResponse.self, from: JSONEncoder().encode(response)) == response)
    }

    @Test(arguments: ["content", "empty-model", "empty-effort", "control", "large"])
    func invalidStepSettingsAreRejected(mode: String) throws {
        var node = mode == "content" ? AgentWorkflowNode(name: "Text", content: .init()) : AgentWorkflowNode(name: "Agent", agentInstanceID: UUID())
        node.modelSelection = .init(model: mode == "empty-model" ? " " : mode == "control" ? "model\n/model" : mode == "large" ? String(repeating: "x", count: 257) : "model", effort: mode == "empty-effort" ? "" : "high")
        let definition = AgentWorkflowDefinition(name: "Invalid", hostID: UUID(), nodes: [node], edges: [], entryNodeID: node.id)
        #expect(throws: AgentWorkflowError.self) { try definition.validate() }
    }
}
