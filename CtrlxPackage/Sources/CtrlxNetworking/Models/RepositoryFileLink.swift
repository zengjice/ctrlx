import Foundation

/// Explicit, workspace-relative output. The repo marker also supports non-Git Agent directories.
public enum RepositoryFileLink {
    public static let prefix = "<repo:"
    public static let maximumLength = 3 * 4_096 + 7

    public static func marker(path: String) -> String? {
        guard
            isValid(path: path),
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .init(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) else { return nil }
        return "\(prefix)\(encoded)>"
    }

    public static func path(_ marker: String) -> String? {
        guard marker.hasPrefix(prefix), marker.hasSuffix(">"), marker.utf8.count <= maximumLength else { return nil }
        let encoded = marker.dropFirst(prefix.count).dropLast()
        guard
            !encoded.isEmpty, encoded.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
                    && (!$0.isASCII || "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/%".unicodeScalars.contains($0))
            }), var path = String(encoded).removingPercentEncoding else { return nil }
        // Accept directory spelling at the marker boundary; keep decoded Host paths canonical.
        if path.hasSuffix("/") {
            path.removeLast()
            guard path != "." else { return nil }
        }
        guard isValid(path: path) else { return nil }
        return path
    }

    /// Compatibility for explicit terminal hyperlink targets; never resolve these as system URLs.
    public static func path(linkTarget: String) -> String? {
        guard linkTarget.hasPrefix("repo:"), linkTarget.utf8.count <= maximumLength - 2 else { return nil }
        return path("<\(linkTarget)>")
    }

    /// Validates a decoded path once; percent signs here are literal filename characters.
    public static func isValid(path: String) -> Bool {
        guard
            !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("~"),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if path == "." {
            return true
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

/// Checked against the source pane both before and after Host resolution.
public struct RepositoryFileContext: Codable, Sendable, Equatable {
    public let pluginID: String
    public let sessionID: String?
    public let projectDirectory: String

    public init(pluginID: String, sessionID: String?, projectDirectory: String) {
        self.pluginID = pluginID
        self.sessionID = sessionID
        self.projectDirectory = projectDirectory
    }

    public init?(pane: PaneState) {
        guard
            let agent = pane.agentSession, let directory = agent.detectedProjectPath,
            directory.hasPrefix("/"), !directory.hasPrefix("//") else { return nil }
        self.init(pluginID: agent.pluginID, sessionID: pane.claudeSessionID, projectDirectory: directory)
    }
}
