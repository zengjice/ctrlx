import Foundation

public enum AgentWorkflowRunStatus: String, Codable, Sendable {
    case running
    case paused
    case finishing
    case completed
    case ended

    public var isTerminal: Bool {
        self == .completed || self == .ended
    }
}

public enum AgentWorkflowInvocationStatus: String, Codable, Sendable {
    case pending
    case writing
    case awaitingAcceptance
    case running
    case succeeded
    case failed
    case uncertain
    case cancelled
}

public struct AgentWorkflowResult: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let invocationID: UUID
    public let nativeTurnID: String
    public let text: String
    public let attachmentIDs: [UUID]
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        invocationID: UUID,
        nativeTurnID: String,
        text: String,
        attachmentIDs: [UUID] = [],
        completedAt: Date
    ) {
        self.id = id
        self.invocationID = invocationID
        self.nativeTurnID = nativeTurnID
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.completedAt = completedAt
    }
}

public struct AgentWorkflowSource: Codable, Equatable, Sendable {
    public let nodeID: UUID
    public let agentInstanceID: UUID
    public let resultID: UUID

    public init(nodeID: UUID, agentInstanceID: UUID, resultID: UUID) {
        self.nodeID = nodeID
        self.agentInstanceID = agentInstanceID
        self.resultID = resultID
    }
}

public struct AgentWorkflowDelivery: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let round: Int
    public let invocationID: UUID
    public let toAgentID: UUID
    public let sources: [AgentWorkflowSource]
    public let input: AgentWorkflowInput

    public init(
        id: UUID = UUID(),
        runID: UUID,
        round: Int,
        invocationID: UUID,
        toAgentID: UUID,
        sources: [AgentWorkflowSource],
        input: AgentWorkflowInput
    ) {
        self.id = id
        self.runID = runID
        self.round = round
        self.invocationID = invocationID
        self.toAgentID = toAgentID
        self.sources = sources
        self.input = input
    }
}

public struct AgentWorkflowInvocation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let nodeID: UUID
    public let round: Int
    public let delivery: AgentWorkflowDelivery
    public let createdAt: Date
    public var status: AgentWorkflowInvocationStatus
    public var nativeTurnID: String?
    public var nativeTranscriptPath: String?
    /// Explicitly published snapshots, retained even before the final answer.
    /// Optional for ledgers written before artifact sharing was available.
    public var sharedAttachmentIDs: [UUID]?
    public var result: AgentWorkflowResult?
    public var issue: String?

    public init(id: UUID, nodeID: UUID, round: Int, delivery: AgentWorkflowDelivery, createdAt: Date) {
        self.id = id
        self.nodeID = nodeID
        self.round = round
        self.delivery = delivery
        self.createdAt = createdAt
        self.status = .pending
    }
}

public struct AgentWorkflowFinishRequest: Codable, Equatable, Sendable {
    public let invocationID: UUID
    public let reason: String
    public let requestedAt: Date

    public init(invocationID: UUID, reason: String, requestedAt: Date) {
        self.invocationID = invocationID
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

/// Authoritative Host snapshot shared with Mac and iOS. A paused run keeps its
/// instance reservations; ending releases them without terminating the Agents.
public struct AgentWorkflowRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let definition: AgentWorkflowDefinition
    public let instances: [AgentWorkflowInstance]
    public let createdAt: Date
    public let authorizationExpiresAt: Date
    public var revision: Int
    public var round: Int
    public var roundLimit: Int
    public var status: AgentWorkflowRunStatus
    public var issue: String?
    public var invocations: [AgentWorkflowInvocation]
    public var finishRequest: AgentWorkflowFinishRequest?

    public init(
        id: UUID = UUID(),
        definition: AgentWorkflowDefinition,
        instances: [AgentWorkflowInstance],
        createdAt: Date,
        authorizationExpiresAt: Date
    ) {
        self.id = id
        self.definition = definition
        self.instances = instances
        self.createdAt = createdAt
        self.authorizationExpiresAt = authorizationExpiresAt
        self.revision = 1
        self.round = 1
        self.roundLimit = definition.loop?.maximumRounds ?? 1
        self.status = .running
        self.invocations = []
    }
}
