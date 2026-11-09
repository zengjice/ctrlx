import Foundation

/// Retries reuse this ID so a delayed response cannot restart the replacement.
public struct RestartAgentSession: CommandSpec, Equatable, Identifiable {
    public typealias Response = CommandResponseMessage
    public let requestID: UUID
    public let source: AgentForkSource
    public let runtimeID: String
    public var id: String {
        source.paneID
    }

    public init(requestID: UUID = UUID(), source: AgentForkSource, runtimeID: String) {
        self.requestID = requestID
        self.source = source
        self.runtimeID = runtimeID
    }

    public var commandType: CommandType {
        .restartAgentSession(self)
    }

    /// Placement may change; the original conversation, pane and directory may not.
    public func matches(_ current: AgentForkSource, runtimeID: String) -> Bool {
        self.runtimeID == runtimeID && source.paneID == current.paneID && source.pluginID == current.pluginID
            && source.sessionID == current.sessionID && source.workingDirectory == current.workingDirectory
            && source.workspaceIdentity?.isSamePane(as: current.workspaceIdentity) == true
    }
}

public struct AgentRestartError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
