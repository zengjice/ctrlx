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

/// Model IDs shared by a custom endpoint; `model` remains the launch default.
public enum AgentProviderModels {
    public static func ids(defaultModel: String, models: [String]?) -> [String] {
        var seen = Set<String>()
        return ([defaultModel] + (models ?? [])).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func isValidID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 200
            && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
    }

    public static func isValid(defaultModel: String, models: [String]?) -> Bool {
        let ids = ids(defaultModel: defaultModel, models: models)
        return isValidID(defaultModel) && ids.count <= 100 && ids.allSatisfy(isValidID)
    }
}
