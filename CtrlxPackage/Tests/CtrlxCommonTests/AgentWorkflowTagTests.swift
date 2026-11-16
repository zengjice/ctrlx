import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct AgentWorkflowTagTests {
    @Test
    func oldDefinitionsDecodeAndCopiesRetainOptionalTags() throws {
        let node = AgentWorkflowNode(name: "Reply", agentInstanceID: UUID())
        var definition = AgentWorkflowDefinition(name: "Review", hostID: UUID(), nodes: [node], edges: [], entryNodeID: node.id)
        let old = try JSONDecoder().decode(AgentWorkflowDefinition.self, from: JSONEncoder().encode(definition))
        #expect(old.tags == nil)
        definition.tags = ["review", "research"]
        try AgentWorkflowWire.validate(definition)
        #expect(definition.duplicated().tags == definition.tags)
        #expect(definition.duplicated().agents.isEmpty)
        definition.tags = ["review", "REVIEW"]
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowWire.validate(definition) }
        definition.tags = [String(repeating: "a", count: 33)]
        #expect(throws: AgentWorkflowError.self) { try AgentWorkflowWire.validate(definition) }
    }
}
