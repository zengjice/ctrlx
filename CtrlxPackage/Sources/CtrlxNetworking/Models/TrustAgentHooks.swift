import Foundation

public enum AgentHookTrustResult: String, Codable, Sendable {
    case approved
    case alreadyTrusted = "already_trusted"
}

/// Explicit user approval of all pending hooks, including other plugins and config sources.
public struct TrustAgentHooks: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let workspacePane: WorkspacePaneIdentity
    /// Missing in older clients, which only requested approval.
    public let refreshIfTrusted: Bool?

    public init(workspacePane: WorkspacePaneIdentity, refreshIfTrusted: Bool = true) {
        self.workspacePane = workspacePane
        self.refreshIfTrusted = refreshIfTrusted
    }

    public var commandType: CommandType {
        .trustAgentHooks(self)
    }
}
