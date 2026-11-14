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
    public enum Completion: String, Codable, CaseIterable, Sendable {
        case replyEnded
        case explicit

        public var title: String {
            switch self {
            case .replyEnded: "When the reply ends"
            case .explicit: "When the Agent completes the step"
            }
        }
    }

    public enum Kind: String, Codable, Sendable { case agent, content }
    public enum InitialTask: String, Codable, CaseIterable, Sendable {
        case omit
        case text
        case textAndAttachments

        public var title: String {
            switch self {
            case .omit: "None"
            case .text: "Text only"
            case .textAndAttachments: "Text and attachments"
            }
        }
    }

    public let id: UUID
    public let kind: Kind
    public var name: String
    public var agentInstanceID: UUID?
    public var input: AgentWorkflowInput
    public var allowsFinish: Bool
    public var completion: Completion
    public var modelSelection: AgentModelSelection?
    /// Nil preserves the input policy of configurations saved before steps.
    public var initialTask: InitialTask?

    public init(
        id: UUID = UUID(),
        name: String,
        agentInstanceID: UUID,
        input: AgentWorkflowInput = .init(),
        allowsFinish: Bool = false,
        initialTask: InitialTask? = nil,
        completion: Completion = .replyEnded,
        modelSelection: AgentModelSelection? = nil
    ) {
        self.id = id
        self.kind = .agent
        self.name = name
        self.agentInstanceID = agentInstanceID
        self.input = input
        self.allowsFinish = allowsFinish
        self.completion = completion
        self.initialTask = initialTask
        self.modelSelection = modelSelection
    }

    public init(id: UUID = UUID(), name: String, content: AgentWorkflowInput = .init(), initialTask: InitialTask? = nil) {
        self.id = id
        self.kind = .content
        self.name = name
        self.agentInstanceID = nil
        self.input = content
        self.allowsFinish = false
        self.completion = .replyEnded
        self.initialTask = initialTask
        self.modelSelection = nil
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, agentInstanceID, input, allowsFinish, initialTask, completion, modelSelection }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .agent
        self.name = try values.decode(String.self, forKey: .name)
        self.agentInstanceID = try values.decodeIfPresent(UUID.self, forKey: .agentInstanceID)
        self.input = try values.decode(AgentWorkflowInput.self, forKey: .input)
        self.allowsFinish = try values.decode(Bool.self, forKey: .allowsFinish)
        self.completion = try values.decodeIfPresent(Completion.self, forKey: .completion) ?? .replyEnded
        self.initialTask = try values.decodeIfPresent(InitialTask.self, forKey: .initialTask)
        self.modelSelection = try values.decodeIfPresent(AgentModelSelection.self, forKey: .modelSelection)
    }
}

public struct AgentWorkflowParticipant: Codable, Equatable, Identifiable, Sendable {
    public var agentInstanceID: UUID
    public var name: String
    public var id: UUID {
        agentInstanceID
    }

    public init(agentInstanceID: UUID, name: String) {
        self.agentInstanceID = agentInstanceID
        self.name = name
    }
}

public struct AgentWorkflowEdge: Codable, Equatable, Hashable, Sendable {
    public var source: UUID
    public var target: UUID
    public var includesResult: Bool

    public init(source: UUID, target: UUID, includesResult: Bool = true) {
        self.source = source
        self.target = target
        self.includesResult = includesResult
    }

    private enum CodingKeys: String, CodingKey { case source, target, includesResult }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try values.decode(UUID.self, forKey: .source)
        self.target = try values.decode(UUID.self, forKey: .target)
        self.includesResult = try values.decodeIfPresent(Bool.self, forKey: .includesResult) ?? true
    }
}

public struct AgentWorkflowLoop: Codable, Equatable, Sendable {
    public var finalNodeID: UUID
    public var maximumRounds: Int
    public var entryNodeID: UUID?
    public var includesResult: Bool

    public init(finalNodeID: UUID, maximumRounds: Int = 5, entryNodeID: UUID? = nil, includesResult: Bool = true) {
        self.finalNodeID = finalNodeID
        self.maximumRounds = maximumRounds
        self.entryNodeID = entryNodeID
        self.includesResult = includesResult
    }

    private enum CodingKeys: String, CodingKey { case finalNodeID, maximumRounds, entryNodeID, includesResult }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.finalNodeID = try values.decode(UUID.self, forKey: .finalNodeID)
        self.maximumRounds = try values.decode(Int.self, forKey: .maximumRounds)
        self.entryNodeID = try values.decodeIfPresent(UUID.self, forKey: .entryNodeID)
        self.includesResult = try values.decodeIfPresent(Bool.self, forKey: .includesResult) ?? true
    }
}

/// A remembered creation destination; it is not an Agent binding.
public struct AgentWorkflowSessionReference: Codable, Equatable, Hashable, Sendable {
    public let serverID: String
    public let sessionID: UUID

    public init(_ identity: WorkspacePaneIdentity) {
        self.serverID = identity.serverID
        self.sessionID = identity.sessionID
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
    /// Launch preference only; it grants no execution or terminal access.
    public var creationSession: AgentWorkflowSessionReference?
    public var participants: [AgentWorkflowParticipant]?
    public var agentTargets: [UUID: AgentWorkflowTarget]?

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        hostID: UUID,
        nodes: [AgentWorkflowNode],
        edges: [AgentWorkflowEdge],
        entryNodeID: UUID,
        initialInput: AgentWorkflowInput = .init(),
        loop: AgentWorkflowLoop? = nil,
        creationSession: AgentWorkflowSessionReference? = nil,
        participants: [AgentWorkflowParticipant]? = nil
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
        self.creationSession = creationSession
        self.participants = participants
    }

    /// Node order, rather than arrival order, determines a join's prompt order.
    public func upstream(of nodeID: UUID) -> [AgentWorkflowNode] {
        let sources = Set(edges.filter { $0.target == nodeID }.map(\.source))
        return nodes.filter { sources.contains($0.id) }
    }

    public var agentInstanceIDs: Set<UUID> {
        Set(nodes.compactMap(\.agentInstanceID))
    }

    public func instance(for agentID: UUID?, in instances: [AgentWorkflowInstance]) -> AgentWorkflowInstance? {
        guard let agentID else { return nil }
        if let target = agentTargets?[agentID] {
            return target.agentID.resolve(in: instances, identity: { $0.agentID }).value
        }
        return instances.first { $0.id == agentID && $0.hostID == hostID }
    }

    public mutating func rememberTargets(from instances: [AgentWorkflowInstance]) {
        let ids = agentInstanceIDs.union(agents.map(\.id))
        var targets = (agentTargets ?? [:]).filter { ids.contains($0.key) }
        for id in ids where targets[id] == nil {
            targets[id] = instances.first { $0.id == id && $0.hostID == hostID }?.target
        }
        agentTargets = targets.isEmpty ? nil : targets
    }

    /// Retain participant IDs; only their durable destinations are extracted.
    public func resolvingAgents(in instances: [AgentWorkflowInstance]) -> Self {
        var resolved = self
        resolved.rememberTargets(from: instances)
        return resolved
    }

    public var agents: [AgentWorkflowParticipant] {
        if let participants {
            return participants
        }
        var seen: Set<UUID> = []
        return nodes.compactMap { node in
            guard let id = node.agentInstanceID, seen.insert(id).inserted else { return nil }
            return .init(agentInstanceID: id, name: node.name)
        }
    }

    /// The legacy participants field stores Agent names, not user-defined role aliases.
    public mutating func updateAgentNames(from instances: [AgentWorkflowInstance]) {
        guard let participants else { return }
        self.participants = participants.map { agent in
            .init(agentInstanceID: agent.id, name: AgentWorkflowWire.boundedName(instance(for: agent.id, in: instances)?.displayName ?? "Agent unavailable"))
        }
    }

    public var usesSteps: Bool {
        participants != nil || nodes.contains { $0.initialTask != nil }
            || edges.contains { !$0.includesResult } || loop?.entryNodeID != nil || loop?.includesResult == false
            || agentInstanceIDs.count != nodes.filter { $0.kind == .agent }.count
    }

    public func initialTask(for node: AgentWorkflowNode) -> AgentWorkflowNode.InitialTask {
        node.initialTask ?? (node.id == entryNodeID ? .textAndAttachments : (node.kind == .agent ? .text : .omit))
    }

    public func entryNodeID(round: Int) -> UUID {
        round > 1 ? (loop?.entryNodeID ?? entryNodeID) : entryNodeID
    }

    public func descendants(of id: UUID) -> Set<UUID> {
        var reached: Set<UUID> = [id]
        var previousCount = 0
        while reached.count != previousCount {
            previousCount = reached.count
            for edge in edges where reached.contains(edge.source) {
                reached.insert(edge.target)
            }
        }
        return reached
    }

    public func activeNodeIDs(round: Int) -> Set<UUID> {
        round > 1 && loop != nil ? descendants(of: entryNodeID(round: round)) : Set(nodes.map(\.id))
    }

    public func validate() throws {
        let targets = (agentTargets ?? [:]).filter { agentInstanceIDs.contains($0.key) }
        guard
            targets.values.allSatisfy({ $0.hostID == hostID }),
            Set(targets.values.map(\.agentID)).count == targets.count else {
            throw AgentWorkflowError("Choose distinct Agent tabs on this Host.")
        }
        guard revision > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentWorkflowError("A workflow needs a name and a positive revision.")
        }
        let nodeIDs = Set(nodes.map(\.id))
        guard !nodes.isEmpty, nodeIDs.count == nodes.count, nodeIDs.contains(entryNodeID) else {
            throw AgentWorkflowError("Choose an entry and distinct workflow nodes.")
        }
        guard nodes.allSatisfy({ $0.kind == .agent ? $0.agentInstanceID != nil : $0.agentInstanceID == nil && !$0.allowsFinish && $0.completion == .replyEnded }) else {
            throw AgentWorkflowError("Agent nodes need an instance. Content nodes cannot bind an Agent or request completion.")
        }
        guard
            Set(agents.map(\.id)).count == agents.count,
            agents.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            agentInstanceIDs.isSubset(of: Set(agents.map(\.id))) else {
            throw AgentWorkflowError("Choose distinct Agents and bind every Agent step to one of them.")
        }
        guard nodes.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AgentWorkflowError("Each step needs a name.")
        }
        for node in nodes {
            if let selection = node.modelSelection {
                let values = [selection.model] + (selection.effort.map { [$0] } ?? [])
                guard
                    node.kind == .agent, values.allSatisfy({
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
                            && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    }) else { throw AgentWorkflowError("Only Agent steps can select a model and effort, with nonempty identifiers up to 256 bytes.") }
            }
        }
        guard
            Set(edges.map { AgentWorkflowEdge(source: $0.source, target: $0.target) }).count == edges.count,
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

        for id in agentInstanceIDs {
            let steps = nodes.filter { $0.agentInstanceID == id }
            for (index, step) in steps.enumerated() {
                for other in steps.dropFirst(index + 1) {
                    guard descendants(of: step.id).contains(other.id) || descendants(of: other.id).contains(step.id) else {
                        throw AgentWorkflowError("Steps using the same Agent must be connected in sequence, so their terminal inputs cannot overlap.")
                    }
                }
            }
        }

        if let loop {
            let sources = Set(edges.map(\.source))
            let exits = nodeIDs.subtracting(sources)
            let loopEntry = loop.entryNodeID ?? entryNodeID
            guard loop.maximumRounds > 0, nodeIDs.contains(loopEntry), exits == [loop.finalNodeID] else {
                throw AgentWorkflowError("A loop needs a positive round limit and one final node reached by every branch.")
            }
            let repeated = descendants(of: loopEntry)
            guard edges.allSatisfy({ !repeated.contains($0.target) || repeated.contains($0.source) || $0.target == loopEntry }) else {
                throw AgentWorkflowError("Repeated steps can depend on first-round steps only at the loop entry.")
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
