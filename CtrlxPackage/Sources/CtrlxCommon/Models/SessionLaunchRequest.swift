import CtrlxNetworking
import Foundation

/// A picker choice, not a persisted project. Custom directories use the same
/// launch pipeline as discovered projects, but must never silently open a shell.
public enum SessionLaunchRequest: Sendable, Equatable {
    case terminal
    case project(AgentProject)
    case directory(
        path: String,
        pluginID: String,
        worktree: ForkAgentSession.Worktree? = nil,
        providerID: String? = nil
    )

    public var project: AgentProject? {
        switch self {
        case .terminal:
            nil
        case let .project(project):
            project
        case let .directory(path, pluginID, worktree, _):
            AgentProject(
                name: worktree?.name ?? Self.directoryName(path),
                path: path,
                pluginID: pluginID
            )
        }
    }

    public var requiresAgentLaunch: Bool {
        if case .directory = self {
            return true
        }
        return false
    }

    public var worktree: ForkAgentSession.Worktree? {
        if case let .directory(_, _, worktree, _) = self {
            return worktree
        }
        return nil
    }

    public var providerID: String? {
        if case let .directory(_, _, _, providerID) = self {
            return providerID
        }
        return nil
    }

    private static func directoryName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" || name == "~" ? "session" : name
    }
}

public struct SessionLaunchAgent: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let providers: [AgentProviderOption]
    public let defaultProviderID: String?

    public init(
        id: String,
        name: String,
        providers: [AgentProviderOption] = [],
        defaultProviderID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.providers = providers
        self.defaultProviderID = defaultProviderID
    }

    public var defaultProviderLabel: String {
        guard let defaultProviderID else { return "Current CLI configuration" }
        let name = providers.first { $0.id == defaultProviderID }?.name ?? defaultProviderID
        return "Default: \(name)"
    }
}

/// Syntax only: viewers must never expand `~` using their own home directory.
public enum SessionDirectoryPath {
    public static func isValid(_ path: String) -> Bool {
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && (path.hasPrefix("/") || path == "~" || path.hasPrefix("~/"))
    }

    public static func expanded(_ path: String, hostHome: String) -> String? {
        guard isValid(path) else { return nil }
        let expanded = path == "~" ? hostHome
            : path.hasPrefix("~/") ? hostHome + String(path.dropFirst()) : path
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
