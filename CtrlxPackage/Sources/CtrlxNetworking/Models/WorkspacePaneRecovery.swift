import Foundation

/// Presence advertises Host-owned recovery actions for this pane. No launch
/// command, history path or credentials are sent to the Viewer.
public struct WorkspacePaneRecovery: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let launchID: UUID?
    public let name: String
    public let reason: String
    public let canResume: Bool
    public let canUseShell: Bool
    public let keepCurrentTerminal: Bool
    public let canRetry: Bool
    public let blocksInput: Bool
    public let isReady: Bool

    public init(
        attemptID: UUID, launchID: UUID?, name: String, reason: String,
        canResume: Bool, canUseShell: Bool, keepCurrentTerminal: Bool,
        canRetry: Bool, blocksInput: Bool, isReady: Bool
    ) {
        self.attemptID = attemptID
        self.launchID = launchID
        self.name = name
        self.reason = reason
        self.canResume = canResume
        self.canUseShell = canUseShell
        self.keepCurrentTerminal = keepCurrentTerminal
        self.canRetry = canRetry
        self.blocksInput = blocksInput
        self.isReady = isReady
    }

    public func allows(_ action: RecoverWorkspacePane.Action) -> Bool {
        isReady && (action == .resume ? canResume : canUseShell || canRetry)
    }
}

public struct RecoverWorkspacePane: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public enum Action: String, Codable, Sendable {
        case resume
        case useShell
    }

    public let paneID: String
    public let attemptID: UUID
    public let launchID: UUID?
    public let action: Action

    public init(paneID: String, recovery: WorkspacePaneRecovery, action: Action) {
        self.paneID = paneID
        self.attemptID = recovery.attemptID
        self.launchID = recovery.launchID
        self.action = action
    }

    public var commandType: CommandType {
        .recoverWorkspacePane(self)
    }
}
