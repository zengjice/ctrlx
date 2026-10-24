import Foundation

public enum AgentWorkflowWire {
    public static let version = 1
    public static let maximumEncodedBytes = 256 * 1_024
    public static let maximumDefinitionBytes = 128 * 1_024
    public static let maximumNodes = 32
    public static let maximumPageItems = 40
    public static let textPageBytes = 32 * 1_024
    // Base64 plus JSON slash escaping still fits maximumEncodedBytes.
    public static let attachmentChunkBytes = 64 * 1_024
    public static let maximumAttachments = 32

    public static func validate(_ definition: AgentWorkflowDefinition) throws {
        try definition.validate()
        guard
            definition.nodes.count <= maximumNodes,
            definition.name.utf8.count <= 256,
            definition.nodes.allSatisfy({ $0.name.utf8.count <= 256 }),
            try JSONEncoder().encode(definition).count <= maximumDefinitionBytes else {
            throw AgentWorkflowError("Use at most 32 Agents, names up to 256 UTF-8 bytes, and a configuration up to 128 KiB. Import large content as attachments.")
        }
    }
}

public struct ManageAgentWorkflows: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public enum TextPart: String, Codable, Sendable { case input, result }

    public enum Operation: Codable, Equatable, Sendable {
        case catalog(offset: Int)
        case definitions(offset: Int)
        case definition(UUID)
        case save(AgentWorkflowDefinition, expectedRevision: Int?)
        case deleteDefinition(UUID, expectedRevision: Int)
        case start(definitionID: UUID, expectedRevision: Int, requestID: UUID, authorizationExpiresAt: Date)
        case runs(offset: Int)
        case run(UUID)
        case runDefinition(UUID)
        case invocations(runID: UUID, offset: Int)
        case text(runID: UUID, invocationID: UUID, part: TextPart, offset: Int)
        case pause(UUID, expectedRevision: Int)
        case resume(UUID, expectedRevision: Int, roundLimit: Int?)
        case end(UUID, expectedRevision: Int)
        case deleteRun(UUID, expectedRevision: Int)
        case attachments([UUID])
        case uploadAttachment(AgentWorkflowAttachmentUpload)
        case discardAttachments([UUID])
        case linkConversion(sourceID: UUID, outputs: [AgentWorkflowConversionOutput])

        public var isMutation: Bool {
            switch self {
            case .save,
                 .deleteDefinition,
                 .start,
                 .pause,
                 .resume,
                 .end,
                 .deleteRun,
                 .uploadAttachment,
                 .discardAttachments,
                 .linkConversion: true
            default: false
            }
        }
    }

    public let version: Int
    public let expectedHostID: UUID?
    public let operation: Operation

    public init(_ operation: Operation, expectedHostID: UUID? = nil, version: Int = AgentWorkflowWire.version) {
        self.version = version
        self.expectedHostID = expectedHostID
        self.operation = operation
    }

    public var commandType: CommandType {
        .manageAgentWorkflows(self)
    }
}

public struct AgentWorkflowPage<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let items: [Item]
    public let nextOffset: Int?

    public init(items: [Item], nextOffset: Int?) {
        self.items = items
        self.nextOffset = nextOffset
    }
}

public struct AgentWorkflowDefinitionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let revision: Int
    public let nodeCount: Int

    public init(_ definition: AgentWorkflowDefinition) {
        self.id = definition.id
        self.name = definition.name
        self.revision = definition.revision
        self.nodeCount = definition.nodes.count
    }
}

public struct AgentWorkflowRunSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let definitionID: UUID
    public let name: String
    public let revision: Int
    public let round: Int
    public let roundLimit: Int
    public let isLooping: Bool
    public let status: AgentWorkflowRunStatus
    public let issue: String?
    public let createdAt: Date
    public let authorizationExpiresAt: Date

    public init(_ run: AgentWorkflowRun) {
        self.id = run.id
        self.definitionID = run.definition.id
        self.name = run.definition.name
        self.revision = run.revision
        self.round = run.round
        self.roundLimit = run.roundLimit
        self.isLooping = run.definition.loop != nil
        self.status = run.status
        self.issue = run.issue
        self.createdAt = run.createdAt
        self.authorizationExpiresAt = run.authorizationExpiresAt
    }
}

public struct AgentWorkflowInvocationSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let nodeID: UUID
    public let round: Int
    public let status: AgentWorkflowInvocationStatus
    public let createdAt: Date
    public let completedAt: Date?
    public let issue: String?
    public let inputAttachmentIDs: [UUID]
    public let resultAttachmentIDs: [UUID]

    public init(_ invocation: AgentWorkflowInvocation) {
        self.id = invocation.id
        self.nodeID = invocation.nodeID
        self.round = invocation.round
        self.status = invocation.status
        self.createdAt = invocation.createdAt
        self.completedAt = invocation.result?.completedAt
        self.issue = invocation.issue
        self.inputAttachmentIDs = invocation.delivery.input.attachmentIDs
        self.resultAttachmentIDs = invocation.result?.attachmentIDs ?? []
    }
}

public struct AgentWorkflowRunState: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let instance: AgentWorkflowInstance?
        public let upstreamIDs: [UUID]
        public let invocation: AgentWorkflowInvocationSummary?
    }

    public let summary: AgentWorkflowRunSummary
    public let nodes: [Node]
    public let finishRequest: AgentWorkflowFinishRequest?

    public init(_ run: AgentWorkflowRun, currentInstances: [AgentWorkflowInstance]) {
        self.summary = .init(run)
        self.finishRequest = run.finishRequest
        self.nodes = run.definition.nodes.map { node in
            let bound = run.instances.first { $0.id == node.agentInstanceID }
            let current = bound.flatMap { binding in currentInstances.first { binding.matchesBinding($0) } }
            return Node(
                id: node.id, name: node.name, instance: current ?? bound,
                upstreamIDs: run.definition.upstream(of: node.id).map(\.id),
                invocation: run.invocations.first { $0.nodeID == node.id && $0.round == run.round }.map(AgentWorkflowInvocationSummary.init)
            )
        }
    }
}

public struct AgentWorkflowTextPage: Codable, Equatable, Sendable {
    public let text: String
    public let nextOffset: Int?
    public let totalBytes: Int

    public init(text: String, nextOffset: Int?, totalBytes: Int) {
        self.text = text
        self.nextOffset = nextOffset
        self.totalBytes = totalBytes
    }
}

public struct AgentWorkflowResponse: Codable, Equatable, Sendable {
    public var version = AgentWorkflowWire.version
    public let hostID: UUID
    public var instances: AgentWorkflowPage<AgentWorkflowInstance>?
    public var definitions: AgentWorkflowPage<AgentWorkflowDefinitionSummary>?
    public var definition: AgentWorkflowDefinition?
    public var runs: AgentWorkflowPage<AgentWorkflowRunSummary>?
    public var run: AgentWorkflowRunState?
    public var invocations: AgentWorkflowPage<AgentWorkflowInvocationSummary>?
    public var text: AgentWorkflowTextPage?
    public var attachments: [AgentWorkflowAttachment]?
    public var uploadedOffset: Int?

    public init(hostID: UUID) {
        self.hostID = hostID
    }
}
