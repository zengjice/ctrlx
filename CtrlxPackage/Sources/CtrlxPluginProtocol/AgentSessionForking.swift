import Foundation

/// Optional native capability. Sidecars keep the existing PluginCore wire contract.
public protocol AgentSessionForking: PluginCore {
    func commandForFork(sessionID: String, projectPath: String) async throws -> AgentForkLaunch
}

/// Native Fork also needs to preserve an unset default configuration root.
/// This capability does not change LaunchCommand's sidecar wire format.
public struct AgentForkLaunch: Sendable {
    public let command: LaunchCommand
    public let unsetEnvironment: [String]

    public init(command: LaunchCommand, unsetEnvironment: [String] = []) {
        self.command = command
        self.unsetEnvironment = unsetEnvironment
    }
}
