import Foundation

/// The state-root namespace and the current tmux incarnation. Pairing identity is
/// carried by the enclosing message; neither names nor runtime IDs are durable.
public struct WorkspaceIdentityScope: Codable, Equatable, Hashable, Sendable {
    public var hostID: UUID
    public var serverID: String?

    public init(hostID: UUID, serverID: String?) {
        self.hostID = hostID
        self.serverID = serverID
    }
}

/// Read in the same tmux list-panes record as the pane's ordinary metadata.
public struct WorkspacePaneIdentity: Codable, Equatable, Hashable, Sendable {
    public var serverID: String
    public var sessionID: UUID
    public var windowID: UUID
    public var paneID: UUID

    public init(serverID: String, sessionID: UUID, windowID: UUID, paneID: UUID) {
        self.serverID = serverID
        self.sessionID = sessionID
        self.windowID = windowID
        self.paneID = paneID
    }

    /// Moving a live pane or changing which linked session owns its display
    /// does not replace the process running inside it.
    public func isSamePane(as other: Self?) -> Bool {
        serverID == other?.serverID && paneID == other?.paneID
    }

    public func isSameWindow(as other: Self?) -> Bool {
        serverID == other?.serverID && windowID == other?.windowID
    }

    public func isSameSession(as other: Self?) -> Bool {
        serverID == other?.serverID && sessionID == other?.sessionID
    }
}

/// A Viewer-owned reference survives a Host reboot, but never crosses pairings
/// or a replacement Host state root. Runtime routes are resolved from fresh state.
public struct ViewerWorkspaceReference: Codable, Equatable, Hashable, Sendable {
    public var pairID: String
    public var hostID: UUID
    public var sessionID: UUID
    public var windowID: UUID?
    public var paneID: UUID?

    public var sessionReference: Self {
        .init(pairID: pairID, hostID: hostID, sessionID: sessionID)
    }

    public init(pairID: String, hostID: UUID, sessionID: UUID, windowID: UUID? = nil, paneID: UUID? = nil) {
        self.pairID = pairID
        self.hostID = hostID
        self.sessionID = sessionID
        self.windowID = windowID
        self.paneID = paneID
    }
}
