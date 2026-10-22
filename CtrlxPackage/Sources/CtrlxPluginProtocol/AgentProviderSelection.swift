import CtrlxNetworking
import Foundation

/// Optional native capability for agents with selectable API Providers.
/// Sidecars and older cores keep using `PluginCore.commandForLaunch`.
public protocol AgentProviderSelecting: PluginCore {
    func providerOptions() async -> [AgentProviderOption]

    /// `providerID == nil` means the Host's configured default. Implementations
    /// throw when an explicit/default Provider is unknown or cannot be launched.
    func commandForLaunch(projectPath: String, providerID: String?) async throws -> LaunchCommand?
}

/// Optional Fork capability that can switch Provider while preserving the
/// source conversation's configuration root. `nil` keeps the CLI's current
/// configuration instead of applying a Provider override.
public protocol AgentProviderForking: AgentSessionForking {
    func commandForFork(
        sessionID: String,
        projectPath: String,
        targetProviderID: String?
    ) async throws -> AgentForkLaunch
}

public struct AgentProviderError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// Stable Keychain account names shared by Host settings UI and plugin cores.
/// Secrets never enter settings.json, Agent command text, Viewer messages or
/// recovery snapshots.
public enum AgentProviderKeychainAccount {
    public static func account(pluginID: String, providerID: String) -> String {
        "agent-provider.\(pluginID).\(providerID)"
    }
}

public enum AgentProviderEnvironment {
    public static let markerKey = "CTRLX_AGENT_PROVIDER_ID"
}
