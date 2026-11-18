import CtrlxCommon
import CtrlxPluginProtocol
import Foundation

/// Codex-family CLIs share rollout and hook formats, but own separate homes and identities.
public enum CodexDistribution: Sendable, Equatable {
    case codex
    case traex

    public var pluginID: String {
        switch self {
        case .codex: "codex"
        case .traex: "traex"
        }
    }

    public var command: String {
        pluginID
    }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .traex: "Traex"
        }
    }

    var homeVariable: String {
        switch self {
        case .codex: "CODEX_HOME"
        case .traex: "TRAE_HOME"
        }
    }

    var sessionsDirectory: String {
        switch self {
        case .codex: "sessions"
        case .traex: "cli/sessions"
        }
    }

    var historyLayout: AgentForkHistoryLayout {
        switch self {
        case .codex: .codex
        case .traex: .traex
        }
    }

    var versionPrefix: String {
        switch self {
        case .codex: "codex-cli "
        case .traex: "traecli "
        }
    }

    var resumeValueOptions: Set<String> {
        Set(["--model", "--profile", "--sandbox", "--ask-for-approval", "--add-dir", "--local-provider"]
            + (self == .traex ? ["--permission-mode", "--shell-tool-timeout", "--allowed-tool", "--disallowed-tool"] : []))
    }

    var automationVersionPolicy: AgentCLIVersionPolicy {
        switch self {
        case .codex: .codex
        case .traex: .traex
        }
    }

    func defaultHome(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[homeVariable], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return home.appendingPathComponent(self == .codex ? ".codex" : ".trae").standardizedFileURL
    }

    public func settings(from data: Data) -> CodexSettings {
        var settings = CodexSettings.decode(from: data)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if object?["command_path"] == nil {
            settings.commandPath = command
        }
        return settings
    }
}
