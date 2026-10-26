import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

public enum ClaudeProviderAuthKind: String, Codable, Sendable, CaseIterable {
    case apiKey = "api_key"
    case authToken = "auth_token"

    public var environmentKey: String {
        switch self {
        case .apiKey: "ANTHROPIC_API_KEY"
        case .authToken: "ANTHROPIC_AUTH_TOKEN"
        }
    }
}

public enum ClaudeReasoningEffort: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}

public struct ClaudeProviderProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var authKind: ClaudeProviderAuthKind
    public var environmentKey: String
    public var reasoningEffort: ClaudeReasoningEffort?
    public var contextWindowTokens: Int?

    public init(
        id: String,
        name: String,
        baseURL: String,
        model: String,
        authKind: ClaudeProviderAuthKind,
        environmentKey: String,
        reasoningEffort: ClaudeReasoningEffort? = nil,
        contextWindowTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.authKind = authKind
        self.environmentKey = environmentKey
        self.reasoningEffort = reasoningEffort
        self.contextWindowTokens = contextWindowTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL = "base_url"
        case model
        case authKind = "auth_kind"
        case environmentKey = "environment_key"
        case reasoningEffort = "reasoning_effort"
        case contextWindowTokens = "context_window_tokens"
    }
}

/// Typed, Codable settings for the Claude Code plugin core. Persisted to
/// `~/.ctrlx/state/plugins/claude-code/settings.json` with snake_case keys
/// (spec §11). The Mac renders these via a hand-written `PluginSettingsForm`
/// switching on plugin id; iOS stays read-only "Configured by Mac".
public struct ClaudeCodeSettings: Codable, Sendable, Equatable {
    /// Path to the `claude` command (full path or just `claude` if on PATH).
    public var commandPath: String
    /// Whether to auto-launch Claude when a project is opened (gates
    /// `commandForLaunch`).
    public var autoRun: Bool
    /// Verbosity of the plugin's log sink.
    public var logLevel: LogLevel
    /// Extra `.claude` config folders to scan beyond `~/.claude`.
    public var additionalConfigFolders: [String]
    /// When true (and the agent exited cleanly at the prompt), the pane closes
    /// on session end. Per-agent; the app honors the core's eligibility flag.
    public var closePaneOnSessionEnd: Bool
    /// When true, a `Stop` hook that arrives while background tasks or session
    /// crons are still pending is checked with the on-device Apple Intelligence
    /// model: if the last assistant message reads as still-waiting, the
    /// premature "Done" is suppressed (issue #644). The classifier fails open
    /// to honoring the Stop wherever Apple Intelligence is unavailable, so it
    /// is safe to leave on by default.
    public var detectFalseStops: Bool
    /// Custom Anthropic-compatible API Providers. The official `anthropic`
    /// Provider follows the CLI's normal login/configuration.
    public var providers: [ClaudeProviderProfile]
    /// Default for new sessions. `nil` follows Claude's current configuration.
    public var defaultProviderID: String?

    public static let builtInProviderID = "anthropic"
    public static let builtInProvider = AgentProviderOption(
        id: builtInProviderID,
        name: "Anthropic (official login)"
    )

    public init(
        commandPath: String = "claude",
        autoRun: Bool = true,
        logLevel: LogLevel = .info,
        additionalConfigFolders: [String] = [],
        closePaneOnSessionEnd: Bool = false,
        detectFalseStops: Bool = true,
        providers: [ClaudeProviderProfile] = [],
        defaultProviderID: String? = nil
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
        self.additionalConfigFolders = additionalConfigFolders
        self.closePaneOnSessionEnd = closePaneOnSessionEnd
        self.detectFalseStops = detectFalseStops
        self.providers = providers
        self.defaultProviderID = defaultProviderID
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
        case additionalConfigFolders = "additional_config_folders"
        case closePaneOnSessionEnd = "close_pane_on_session_end"
        case detectFalseStops = "detect_false_stops"
        case providers
        case defaultProviderID = "default_provider_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "claude"
        self.autoRun = try container.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
        self.logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        self.additionalConfigFolders = try container
            .decodeIfPresent([String].self, forKey: .additionalConfigFolders) ?? []
        self.closePaneOnSessionEnd = try container
            .decodeIfPresent(Bool.self, forKey: .closePaneOnSessionEnd) ?? false
        self.detectFalseStops = try container
            .decodeIfPresent(Bool.self, forKey: .detectFalseStops) ?? true
        self.providers = try container.decodeIfPresent([ClaudeProviderProfile].self, forKey: .providers) ?? []
        self.defaultProviderID = try container.decodeIfPresent(String.self, forKey: .defaultProviderID)
    }

    public var providerOptions: [AgentProviderOption] {
        var seen = Set<String>()
        return ([Self.builtInProvider] + providers.map { AgentProviderOption(id: $0.id, name: $0.name) })
            .filter { seen.insert($0.id).inserted }
    }

    public var resolvedDefaultProviderID: String? {
        guard let defaultProviderID, providerOptions.contains(where: { $0.id == defaultProviderID }) else { return nil }
        return defaultProviderID
    }

    public static func isValidProviderID(_ id: String) -> Bool {
        id != builtInProviderID
            && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    public static func isValidEnvironmentKey(_ key: String) -> Bool {
        !key.hasPrefix("CTRLX_") && key != "CLAUDE_CONFIG_DIR" && key != "PATH" && key != "HOME"
            && key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    public static func isValidContextWindowTokens(_ tokens: Int) -> Bool {
        (1...10_000_000).contains(tokens)
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults when the
    /// data is empty or malformed (never traps on hostile on-disk data — §13).
    public static func decode(from data: Data) -> ClaudeCodeSettings {
        guard !data.isEmpty else { return ClaudeCodeSettings() }
        return (try? JSONDecoder().decode(ClaudeCodeSettings.self, from: data)) ?? ClaudeCodeSettings()
    }
}
