import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct AgentWorkflowEditingTests {
    @Test
    func appendingStepsMakesAValidSequenceUsingTheSameAgent() throws {
        let agent = UUID()
        let first = AgentWorkflowNode(name: "Develop", agentInstanceID: agent, initialTask: .textAndAttachments, completion: .explicit, modelSelection: .init(model: "fast", effort: "low"))
        let second = AgentWorkflowNode(name: "Review", agentInstanceID: agent, initialTask: .omit, modelSelection: .init(model: "strong", effort: "high"))
        var definition = AgentWorkflowDefinition(name: "Sequence", hostID: UUID(), nodes: [], edges: [], entryNodeID: UUID())
        definition.appendStep(first)
        try AgentWorkflowWire.validate(definition)
        definition.appendStep(second)
        try AgentWorkflowWire.validate(definition)
        #expect(definition.entryNodeID == first.id)
        #expect(definition.nodes == [first, second])
        #expect(definition.edges == [.init(source: first.id, target: second.id)])
    }

    @Test
    func appendedStepsJoinAllBranchesWithoutChangingExistingInputs() throws {
        let start = AgentWorkflowNode(name: "Start", agentInstanceID: UUID())
        let left = AgentWorkflowNode(name: "Left", agentInstanceID: UUID())
        let right = AgentWorkflowNode(name: "Right", agentInstanceID: UUID())
        var definition = AgentWorkflowDefinition(name: "Branches", hostID: UUID(), nodes: [start, left, right], edges: [.init(source: start.id, target: left.id, includesResult: false), .init(source: start.id, target: right.id)], entryNodeID: start.id)
        let original = definition
        let joined = try AgentWorkflowNode(name: "Join", agentInstanceID: #require(left.agentInstanceID), initialTask: .omit)
        try AgentWorkflowWire.validate(definition)
        definition.appendStep(joined)
        try AgentWorkflowWire.validate(definition)
        #expect(Array(definition.nodes.dropLast()) == original.nodes)
        #expect(Array(definition.edges.prefix(original.edges.count)) == original.edges)
        #expect(Set(definition.edges.filter { $0.target == joined.id }.map(\.source)) == [left.id, right.id])
        #expect(definition.terminalSteps.map(\.id) == [joined.id])
    }

    @Test
    func appendingUsesActualTerminalsRatherThanTheLastDisplayedStep() throws {
        let start = AgentWorkflowNode(name: "Start", agentInstanceID: UUID())
        let end = AgentWorkflowNode(name: "End", agentInstanceID: UUID())
        let middle = AgentWorkflowNode(name: "Middle", content: .init(text: "Instructions"))
        var definition = AgentWorkflowDefinition(name: "Display order", hostID: UUID(), nodes: [start, end, middle], edges: [.init(source: start.id, target: middle.id), .init(source: middle.id, target: end.id)], entryNodeID: start.id)
        let next = AgentWorkflowNode(name: "Next", content: .init(text: "Continue"))
        definition.appendStep(next)
        try AgentWorkflowWire.validate(definition)
        #expect(definition.upstream(of: next.id).map(\.id) == [end.id])
    }

    @Test
    func appendingExtendsALoopAndPreservesItsOtherSettings() throws {
        let developer = UUID()
        var definition = AgentWorkflowDefinition(name: "Review loop", hostID: UUID(), nodes: [], edges: [], entryNodeID: UUID())
        AgentWorkflowReviewTemplate.apply(to: &definition, developerID: developer, reviewerID: UUID())
        let original = definition
        let next = AgentWorkflowNode(name: "Final check", agentInstanceID: developer, initialTask: .omit)
        definition.appendStep(next)
        try AgentWorkflowWire.validate(definition)
        #expect(definition.loop?.finalNodeID == next.id)
        #expect(definition.loop?.entryNodeID == original.loop?.entryNodeID)
        #expect(definition.loop?.maximumRounds == original.loop?.maximumRounds)
        #expect(definition.loop?.includesResult == original.loop?.includesResult)
        #expect(definition.entryNodeID == original.entryNodeID)
        #expect(Array(definition.nodes.dropLast()) == original.nodes)
        #expect(try definition.upstream(of: next.id).map(\.id) == [#require(original.loop?.finalNodeID)])
    }

    @Test
    func connectionModesUpdateOnlyTheSelectedConnection() throws {
        let a = AgentWorkflowNode(name: "A", content: .init(text: "A"))
        let b = AgentWorkflowNode(name: "B", content: .init(text: "B"))
        let c = AgentWorkflowNode(name: "C", content: .init(text: "C"))
        var definition = AgentWorkflowDefinition(name: "Connections", hostID: UUID(), nodes: [a, b, c], edges: [.init(source: a.id, target: b.id, includesResult: false), .init(source: a.id, target: c.id)], entryNodeID: a.id)
        let original = definition
        #expect(definition.connectionMode(from: a.id, to: b.id) == .completionOnly)
        #expect(definition.connectionMode(from: b.id, to: c.id) == .none)
        definition.setConnectionMode(.output, from: a.id, to: b.id)
        definition.setConnectionMode(.completionOnly, from: b.id, to: c.id)
        #expect(definition.connectionMode(from: a.id, to: b.id) == .output)
        #expect(definition.connectionMode(from: b.id, to: c.id) == .completionOnly)
        definition.setConnectionMode(.completionOnly, from: a.id, to: b.id)
        definition.setConnectionMode(.none, from: b.id, to: c.id)
        try AgentWorkflowWire.validate(definition)
        #expect(definition == original)
    }
}
