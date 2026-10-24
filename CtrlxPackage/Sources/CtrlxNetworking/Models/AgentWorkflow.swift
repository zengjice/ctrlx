import Foundation

public struct AgentWorkflowInput: Codable, Equatable, Sendable {
    public var text: String
    public var attachmentIDs: [UUID]

    public init(text: String = "", attachmentIDs: [UUID] = []) {
        self.text = text
        self.attachmentIDs = attachmentIDs
    }
}

public struct AgentWorkflowNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var agentInstanceID: UUID
    public var input: AgentWorkflowInput
    public var allowsFinish: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        agentInstanceID: UUID,
        input: AgentWorkflowInput = .init(),
        allowsFinish: Bool = false
    ) {
        self.id = id
        self.name = name
        self.agentInstanceID = agentInstanceID
        self.input = input
        self.allowsFinish = allowsFinish
    }
}

public struct AgentWorkflowEdge: Codable, Equatable, Hashable, Sendable {
    public var source: UUID
    public var target: UUID

    public init(source: UUID, target: UUID) {
        self.source = source
        self.target = target
    }
}

public struct AgentWorkflowLoop: Codable, Equatable, Sendable {
    public var finalNodeID: UUID
    public var maximumRounds: Int

    public init(finalNodeID: UUID, maximumRounds: Int = 5) {
        self.finalNodeID = finalNodeID
        self.maximumRounds = maximumRounds
    }
}

/// A run keeps a value copy; later template edits never change an in-flight task.
public struct AgentWorkflowDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var revision: Int
    public var name: String
    public var hostID: UUID
    public var nodes: [AgentWorkflowNode]
    public var edges: [AgentWorkflowEdge]
    public var entryNodeID: UUID
    public var initialInput: AgentWorkflowInput
    public var loop: AgentWorkflowLoop?

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        hostID: UUID,
        nodes: [AgentWorkflowNode],
        edges: [AgentWorkflowEdge],
        entryNodeID: UUID,
        initialInput: AgentWorkflowInput = .init(),
        loop: AgentWorkflowLoop? = nil
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.hostID = hostID
        self.nodes = nodes
        self.edges = edges
        self.entryNodeID = entryNodeID
        self.initialInput = initialInput
        self.loop = loop
    }

    /// Node order, rather than arrival order, determines a join's prompt order.
    public func upstream(of nodeID: UUID) -> [AgentWorkflowNode] {
        let sources = Set(edges.filter { $0.target == nodeID }.map(\.source))
        return nodes.filter { sources.contains($0.id) }
    }

    public func validate() throws {
        guard revision > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentWorkflowError("A workflow needs a name and a positive revision.")
        }
        let nodeIDs = Set(nodes.map(\.id))
        guard !nodes.isEmpty, nodeIDs.count == nodes.count, nodeIDs.contains(entryNodeID) else {
            throw AgentWorkflowError("Choose an entry and distinct workflow nodes.")
        }
        guard Set(nodes.map(\.agentInstanceID)).count == nodes.count else {
            throw AgentWorkflowError("An Agent instance can participate only once in a workflow.")
        }
        guard nodes.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AgentWorkflowError("Each node needs a role name.")
        }
        guard
            Set(edges).count == edges.count,
            edges.allSatisfy({ nodeIDs.contains($0.source) && nodeIDs.contains($0.target) && $0.source != $0.target }) else {
            throw AgentWorkflowError("Connections must join distinct, existing nodes without duplicates.")
        }
        guard upstream(of: entryNodeID).isEmpty else {
            throw AgentWorkflowError("The entry cannot have an upstream connection. Configure loops separately.")
        }

        var visited: Set<UUID> = []
        var remaining = nodes.map(\.id)
        while !remaining.isEmpty {
            let ready = remaining.filter { nodeID in
                upstream(of: nodeID).allSatisfy { visited.contains($0.id) }
            }
            guard !ready.isEmpty else { throw AgentWorkflowError("Connections inside a round cannot form a cycle.") }
            for nodeID in ready {
                guard nodeID == entryNodeID || !upstream(of: nodeID).isEmpty else {
                    throw AgentWorkflowError("Every node must be reachable from the entry.")
                }
                visited.insert(nodeID)
            }
            remaining.removeAll { visited.contains($0) }
        }

        if let loop {
            let sources = Set(edges.map(\.source))
            let exits = nodeIDs.subtracting(sources)
            guard loop.maximumRounds > 0, exits == [loop.finalNodeID] else {
                throw AgentWorkflowError("A loop needs a positive round limit and one final node reached by every branch.")
            }
        }
    }
}

public struct AgentWorkflowError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? {
        message
    }

    public init(_ message: String) {
        self.message = message
    }
}
