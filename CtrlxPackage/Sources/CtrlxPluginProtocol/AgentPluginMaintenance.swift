import Foundation

/// Optional, local capability for the Agent-side plugin bundled with CtrlX.
/// This does not change the sidecar RPC contract or update the Agent executable.
public protocol AgentPluginMaintenance: PluginCore {
    func bundledPluginVersion() async throws -> String
    func reinstall(configRoot: String?) async throws -> PluginInstallStatus
}

public struct AgentPluginInstallError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
