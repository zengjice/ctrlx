import CtrlxNetworking
import Foundation

enum AgentWorkflowConnectionMode: String, CaseIterable, Sendable {
    case none = "No connection"
    case completionOnly = "Completion only"
    case output = "Output and attachments"
}

extension AgentWorkflowDefinition {
    func participantID(for instance: AgentWorkflowInstance, in instances: [AgentWorkflowInstance]) -> UUID? {
        agents.first(where: { self.instance(for: $0.id, in: instances)?.agentID == instance.agentID })?.id
    }

    @discardableResult
    mutating func addAgent(_ instance: AgentWorkflowInstance, in instances: [AgentWorkflowInstance]) -> UUID {
        if let id = participantID(for: instance, in: instances) {
            return id
        }
        let id = UUID()
        participants = agents + [.init(agentInstanceID: id, name: AgentWorkflowWire.boundedName(instance.displayName))]
        agentTargets = agentTargets ?? [:]
        agentTargets?[id] = instance.target
        return id
    }

    func duplicated() -> Self {
        let steps = nodes.map { node in
            var step = node
            step.agentInstanceID = nil
            step.modelSelection = nil
            step.input.attachmentIDs = []
            return step
        }
        return Self(
            name: AgentWorkflowWire.boundedName("Copy of \(name)"), hostID: hostID,
            nodes: steps, edges: edges, entryNodeID: entryNodeID,
            loop: loop, participants: []
        )
    }

    var terminalSteps: [AgentWorkflowNode] {
        let sources = Set(edges.map(\.source))
        return nodes.filter { !sources.contains($0.id) }
    }

    /// Appending continues after every current branch, independent of display order.
    mutating func appendStep(_ node: AgentWorkflowNode) {
        let previous = terminalSteps
        if nodes.isEmpty {
            entryNodeID = node.id
        }
        nodes.append(node)
        edges += previous.map { .init(source: $0.id, target: node.id) }
        if loop != nil {
            loop?.finalNodeID = node.id
        }
    }

    func connectionMode(from source: UUID, to target: UUID) -> AgentWorkflowConnectionMode {
        guard let edge = edges.first(where: { $0.source == source && $0.target == target }) else { return .none }
        return edge.includesResult ? .output : .completionOnly
    }

    mutating func setConnectionMode(_ mode: AgentWorkflowConnectionMode, from source: UUID, to target: UUID) {
        if mode == .none {
            edges.removeAll { $0.source == source && $0.target == target }
        } else if let index = edges.firstIndex(where: { $0.source == source && $0.target == target }) {
            edges[index].includesResult = mode == .output
        } else {
            edges.append(.init(source: source, target: target, includesResult: mode == .output))
        }
    }
}
