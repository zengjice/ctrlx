import Foundation

public enum AgentHookTrustResult: String, Codable, Sendable {
    case approved
    case alreadyTrusted = "already_trusted"
}

/// Explicit user approval of all pending hooks, including other plugins and config sources.
public struct TrustAgentHooks: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let workspacePane: WorkspacePaneIdentity

    public init(workspacePane: WorkspacePaneIdentity) {
        self.workspacePane = workspacePane
    }

    public var commandType: CommandType {
        .trustAgentHooks(self)
    }
}
