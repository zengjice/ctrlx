import Foundation

/// Native recovery is optional and does not change the sidecar wire contract.
public protocol AgentSessionResuming: PluginCore {
    func recoveryDescriptor(sessionID: String, projectPath: String, invocation: AgentResumeInvocation?) async throws -> AgentResumeDescriptor
    func commandForResume(_ descriptor: AgentResumeDescriptor) async throws -> AgentForkLaunch
}

/// Transient process evidence. Raw argv may contain a prompt; never persist this value.
public struct AgentResumeInvocation: Sendable {
    public let executable: String
    public let arguments: [String]
    public let configurationRoots: [String: String]
    public let providerID: String?
    public let version: String?

    public init(
        executable: String,
        arguments: [String],
        configurationRoots: [String: String] = [:],
        providerID: String? = nil,
        version: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.configurationRoots = configurationRoots
        self.providerID = providerID
        self.version = version
    }
}

/// Only verified identity, configuration location and whitelisted invocation options.
public struct AgentResumeDescriptor: Codable, Equatable, Sendable {
    public let pluginID: String
    public let sessionID: String
    public let projectPath: String
    public let configurationRoot: String
    public let usesDefaultConfiguration: Bool
    public let executable: String?
    public let cliVersion: String?
    public let arguments: [String]
    public let automaticResumeUnavailableReason: String?
    /// Non-sensitive Provider identity recorded by the launch environment.
    public let providerID: String?

    public init(
        pluginID: String, sessionID: String, projectPath: String, configurationRoot: String, usesDefaultConfiguration: Bool,
        executable: String? = nil, cliVersion: String? = nil, arguments: [String] = [],
        automaticResumeUnavailableReason: String? = "The original process invocation was not recorded.",
        providerID: String? = nil
    ) {
        self.pluginID = pluginID
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.configurationRoot = configurationRoot
        self.usesDefaultConfiguration = usesDefaultConfiguration
        self.cliVersion = cliVersion
        self.executable = executable
        self.arguments = arguments
        self.automaticResumeUnavailableReason = automaticResumeUnavailableReason
        self.providerID = providerID
    }
}

/// Options are owned by each native plugin. Positional prompts, source resume IDs,
/// images and telemetry overrides are deliberately excluded from the saved argv.
public enum AgentResumeArguments {
    public static func capture(
        _ arguments: [String], values: Set<String>, flags: Set<String>,
        ignoredValues: Set<String>, ignoredFlags: Set<String>, aliases: [String: String] = [:],
        configKeys: Set<String> = [], ignoredConfigPrefixes: Set<String> = []
    ) throws -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let raw = arguments[index]
            index += 1
            if raw == "--" {
                break
            }
            guard raw.hasPrefix("-") else { continue }
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = aliases[String(parts[0])] ?? String(parts[0])
            let inline = parts.count == 2 ? String(parts[1]) : nil
            func value() throws -> String {
                if let inline {
                    return inline
                }
                guard index < arguments.count else { throw AgentResumeConfigurationError("A startup option has no value: \(key)") }
                defer { index += 1 }
                return arguments[index]
            }
            if ignoredFlags.contains(key) {
                continue
            }
            if ignoredValues.contains(key) {
                _ = try value()
                continue
            }
            if key == "--config" {
                let override = try value()
                let name = override.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                if name.hasPrefix("otel.") || ignoredConfigPrefixes.contains(where: name.hasPrefix) {
                    continue
                }
                guard configKeys.contains(name), override.contains("=") else {
                    throw AgentResumeConfigurationError("A custom startup configuration cannot be restored automatically: \(name)")
                }
                result += [key, override]
            } else if values.contains(key) {
                try result += [key, value()]
            } else if flags.contains(key), inline == nil {
                result.append(key)
            } else {
                throw AgentResumeConfigurationError("An unsupported startup option must be restored manually: \(key)")
            }
        }
        return result
    }
}

public struct AgentResumeConfigurationError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
