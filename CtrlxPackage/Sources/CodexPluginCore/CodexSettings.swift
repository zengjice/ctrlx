import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Codex's reasoning-effort override for a custom Provider.
///
/// `nil` on a profile follows the user's Codex configuration. Keeping this on
/// the Provider makes the selected launch model and its thinking level a single
/// Host-owned choice for New Agent, Fork and recovery.
public enum CodexReasoningEffort: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }
}

public struct CodexProviderProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var environmentKey: String
    public var reasoningEffort: CodexReasoningEffort?

    public init(
        id: String,
        name: String,
        baseURL: String,
        model: String,
        environmentKey: String,
        reasoningEffort: CodexReasoningEffort? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.environmentKey = environmentKey
        self.reasoningEffort = reasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL = "base_url"
        case model
        case environmentKey = "environment_key"
        case reasoningEffort = "reasoning_effort"
    }
}

/// Typed, Codable settings for the Codex plugin core. Persisted to
/// `~/.ctrlx/state/plugins/codex/settings.json` with snake_case keys (spec §11).
public struct CodexSettings: Codable, Sendable, Equatable {
    /// Path to the `codex` command (full path or just `codex` if on PATH).
    public var commandPath: String
    /// Whether to auto-launch Codex when a project is opened.
    public var autoRun: Bool
    /// Verbosity of the plugin's log sink.
    public var logLevel: LogLevel
    /// When true (and the agent exited cleanly at the prompt), the pane closes
    /// on session end. Per-agent; the app honors the core's eligibility flag.
    public var closePaneOnSessionEnd: Bool
    /// Extra `CODEX_HOME` roots to scan/install beyond the default. Mirrors
    /// ClaudeCodeSettings.additionalConfigFolders.
    public var additionalConfigFolders: [String]

    /// When true (default), app-launched Codex panes get `-c otel.…` launch
    /// overrides pointing Codex's OTLP log export at the Mac-local receiver
    /// (issue #602), so the session's token/latency/model surface in the UI.
    /// One-way push; no prompt/tool content leaves the process
    /// (`log_user_prompt = false`). Opt-out for users who manage their own
    /// `[otel]` config or want zero telemetry from CtrlX-launched panes.
    public var exportTelemetry: Bool
    /// Custom API Providers. The official `openai` Provider is built in and
    /// follows the user's normal Codex login/configuration.
    public var providers: [CodexProviderProfile]
    /// Default for new sessions. `nil` follows Codex's current configuration.
    public var defaultProviderID: String?

    public static let builtInProviderID = "openai"
    public static let builtInProvider = AgentProviderOption(
        id: builtInProviderID,
        name: "OpenAI (official login)"
    )

    public init(
        commandPath: String = "codex",
        autoRun: Bool = true,
        logLevel: LogLevel = .info,
        closePaneOnSessionEnd: Bool = false,
        additionalConfigFolders: [String] = [],
        exportTelemetry: Bool = true,
        providers: [CodexProviderProfile] = [],
        defaultProviderID: String? = nil
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
        self.closePaneOnSessionEnd = closePaneOnSessionEnd
        self.additionalConfigFolders = additionalConfigFolders
        self.exportTelemetry = exportTelemetry
        self.providers = providers
        self.defaultProviderID = defaultProviderID
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
        case closePaneOnSessionEnd = "close_pane_on_session_end"
        case additionalConfigFolders = "additional_config_folders"
        case exportTelemetry = "export_telemetry"
        case providers
        case defaultProviderID = "default_provider_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "codex"
        self.autoRun = try container.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
        self.logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        self.closePaneOnSessionEnd = try container
            .decodeIfPresent(Bool.self, forKey: .closePaneOnSessionEnd) ?? false
        self.additionalConfigFolders = try container
            .decodeIfPresent([String].self, forKey: .additionalConfigFolders) ?? []
        self.exportTelemetry = try container.decodeIfPresent(Bool.self, forKey: .exportTelemetry) ?? true
        self.providers = try container.decodeIfPresent([CodexProviderProfile].self, forKey: .providers) ?? []
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
        !key.hasPrefix("CTRLX_") && key != "CODEX_HOME" && key != "PATH" && key != "HOME"
            && key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults when the
    /// data is empty or malformed (never traps on hostile on-disk data — §13).
    public static func decode(from data: Data) -> CodexSettings {
        guard !data.isEmpty else { return CodexSettings() }
        return (try? JSONDecoder().decode(CodexSettings.self, from: data)) ?? CodexSettings()
    }
}
