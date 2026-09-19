import CtrlxNetworking
import Foundation

/// A picker choice, not a persisted project. Custom directories use the same
/// launch pipeline as discovered projects, but must never silently open a shell.
public enum SessionLaunchRequest: Sendable, Equatable {
    case terminal
    case project(AgentProject)
    case directory(path: String, pluginID: String)

    public var project: AgentProject? {
        switch self {
        case .terminal:
            nil
        case let .project(project):
            project
        case let .directory(path, pluginID):
            AgentProject(
                name: Self.directoryName(path),
                path: path,
                pluginID: pluginID
            )
        }
    }

    public var requiresAgentLaunch: Bool {
        if case .directory = self { return true }
        return false
    }

    private static func directoryName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" || name == "~" ? "session" : name
    }
}

public struct SessionLaunchAgent: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
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
