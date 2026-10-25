import Foundation

public struct AgentWorkflowCapabilities: Codable, Equatable, Sendable {
    public var maximumInputBytes: Int
    public var mediaTypes: [String]

    public init(maximumInputBytes: Int, mediaTypes: [String] = []) {
        self.maximumInputBytes = maximumInputBytes
        self.mediaTypes = mediaTypes
    }
}

public enum AgentWorkflowReadiness: String, Codable, Sendable {
    case ready
    case busy
    case draft
    case awaitingHuman
    case unavailable
}

/// Assigned by the Host after inspecting the live main process. Neither the
/// display name nor a provider conversation ID authenticates an instance.
public struct AgentWorkflowInstance: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let hostID: UUID
    public let pluginID: String
    public let processID: Int32
    public let processRuntimeID: String
    public var workspacePane: WorkspacePaneIdentity
    public var paneID: String
    public var conversationID: String
    public var displayName: String
    public var workingDirectory: String
    public var capabilities: AgentWorkflowCapabilities?
    public var readiness: AgentWorkflowReadiness
    public var capabilityIssue: String?

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        pluginID: String,
        processID: Int32,
        processRuntimeID: String,
        workspacePane: WorkspacePaneIdentity,
        paneID: String,
        conversationID: String,
        displayName: String,
        workingDirectory: String,
        capabilities: AgentWorkflowCapabilities?,
        readiness: AgentWorkflowReadiness,
        capabilityIssue: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.pluginID = pluginID
        self.processID = processID
        self.processRuntimeID = processRuntimeID
        self.workspacePane = workspacePane
        self.paneID = paneID
        self.conversationID = conversationID
        self.displayName = displayName
        self.workingDirectory = workingDirectory
        self.capabilities = capabilities
        self.readiness = readiness
        self.capabilityIssue = capabilityIssue
    }

    /// Moving a live pane preserves identity; a reused PID, pane or new
    /// conversation must not inherit an existing invocation's authority.
    public func matchesBinding(_ other: Self) -> Bool {
        id == other.id && hostID == other.hostID && pluginID == other.pluginID
            && processID == other.processID && processRuntimeID == other.processRuntimeID
            && workspacePane.isSamePane(as: other.workspacePane)
            && conversationID == other.conversationID
    }
}

public struct AgentWorkflowAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let mediaType: String
    public let byteCount: Int64
    public let sha256: String
    public let conversion: AgentWorkflowAttachmentConversion?

    public init(id: UUID = UUID(), name: String, mediaType: String, byteCount: Int64, sha256: String, conversion: AgentWorkflowAttachmentConversion? = nil) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.conversion = conversion
    }
}

public struct AgentWorkflowAttachmentConversion: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let sourceName: String
    public let sourceSHA256: String
    public let description: String

    public init(sourceID: UUID, sourceName: String, sourceSHA256: String, description: String) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceSHA256 = sourceSHA256
        self.description = description
    }
}

public struct AgentWorkflowConversionOutput: Codable, Equatable, Sendable {
    public let attachmentID: UUID
    public let description: String

    public init(attachmentID: UUID, description: String) {
        self.attachmentID = attachmentID
        self.description = description
    }
}
