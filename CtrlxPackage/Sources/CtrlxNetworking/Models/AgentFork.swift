import Foundation

/// Captured when the menu opens; the Host must still match this identity before launch.
public struct AgentForkSource: Codable, Sendable, Equatable, Identifiable {
    public let paneID: String
    public let sessionID: String
    public let pluginID: String
    public let sessionName: String
    public let windowID: String
    public let workingDirectory: String
    public var id: String { paneID }

    public static func unavailableReason(panes: [PaneState]) -> String? {
        if panes.contains(where: { AgentForkSource(pane: $0) != nil }) { return nil }
        let supported = panes.filter { ["codex", "claude-code"].contains($0.agentSession?.pluginID ?? "") }
        guard !supported.isEmpty else { return "Fork requires a recognized Codex or Claude Code conversation." }
        if supported.allSatisfy({ $0.claudeSessionID.flatMap(UUID.init(uuidString:)) == nil }) {
            return "The conversation ID is not verified yet. Wait for Agent activity to restore it."
        }
        return "The source Agent's working directory is unavailable."
    }

    public init?(pane: PaneState) {
        guard let agent = pane.agentSession,
              agent.pluginID == "codex" || agent.pluginID == "claude-code",
              let sessionID = pane.claudeSessionID, UUID(uuidString: sessionID) != nil,
              let directory = pane.currentPath, directory.hasPrefix("/"),
              !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        self.paneID = pane.paneId
        self.sessionID = sessionID
        self.pluginID = agent.pluginID
        self.sessionName = pane.sessionName
        self.windowID = pane.stableWindowId
        self.workingDirectory = directory
    }
}

public struct AgentForkWorktree: Codable, Sendable, Equatable {
    public let repositoryRoot: String
    public let primaryRoot: String
    public let head: String
    public let relativeDirectory: String
    public let hasUncommittedChanges: Bool

    public init(repositoryRoot: String, primaryRoot: String, head: String, relativeDirectory: String, hasUncommittedChanges: Bool) {
        self.repositoryRoot = repositoryRoot
        self.primaryRoot = primaryRoot
        self.head = head
        self.relativeDirectory = relativeDirectory
        self.hasUncommittedChanges = hasUncommittedChanges
    }

    public func directory(name: String) -> String {
        (primaryRoot as NSString).appendingPathComponent(".worktrees/\(name)")
    }

    public static func isValidName(_ name: String) -> Bool {
        name.utf8.count <= 80 && name != "HEAD" && !name.contains("..") && !name.hasSuffix(".") && !name.hasSuffix(".lock")
            && name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

public struct AgentForkPreparation: Codable, Sendable, Equatable {
    public let source: AgentForkSource
    public let worktree: AgentForkWorktree?
    public let worktreeUnavailableReason: String?

    public init(source: AgentForkSource, worktree: AgentForkWorktree?, worktreeUnavailableReason: String? = nil) {
        self.source = source
        self.worktree = worktree
        self.worktreeUnavailableReason = worktreeUnavailableReason
    }
}

public struct PrepareAgentFork: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let source: AgentForkSource
    public init(source: AgentForkSource) { self.source = source }
    public var commandType: CommandType { .prepareAgentFork(self) }
}

public struct ForkAgentSession: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public struct Worktree: Codable, Sendable, Equatable {
        public let name: String
        public let expectedHead: String
        public let allowUncommittedChanges: Bool
        public init(name: String, expectedHead: String, allowUncommittedChanges: Bool = false) {
            self.name = name
            self.expectedHead = expectedHead
            self.allowUncommittedChanges = allowUncommittedChanges
        }
    }

    /// Kept across a transport retry so a delayed reply cannot create a second fork.
    public let requestID: UUID
    public let source: AgentForkSource
    /// Optional so requests from clients without the naming panel still decode.
    public let windowName: String?
    public let worktree: Worktree?
    public init(requestID: UUID = UUID(), source: AgentForkSource, windowName: String? = nil, worktree: Worktree? = nil) {
        self.requestID = requestID
        self.source = source
        self.windowName = windowName
        self.worktree = worktree
    }

    public func validateName() throws {
        if let windowName {
            guard !windowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !windowName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw AgentForkError("Enter a window name without line breaks or control characters.") }
        }
        if let worktree {
            guard AgentForkWorktree.isValidName(worktree.name) else {
                throw AgentForkError("Use a worktree name starting with a letter or number, followed by letters, numbers, ., _ or -. Do not use HEAD, .., or end with . or .lock.")
            }
            guard windowName == nil || windowName == worktree.name else {
                throw AgentForkError("The window, branch and worktree directory must use the same name.")
            }
        }
    }
    public var commandType: CommandType { .forkAgentSession(self) }
}

public struct AgentForkError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
