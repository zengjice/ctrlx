import Foundation

/// Captured before editing an image, and checked again on the Host before pasting.
/// Browser ownership is deliberately separate from this human-selected recipient.
public struct AgentImageTarget: Codable, Sendable, Equatable, Identifiable {
    public let paneID: String
    public let sessionID: String
    public let pluginID: String
    public let sessionName: String
    public let windowID: String
    public let label: String
    public var id: String { paneID }

    public init?(pane: PaneState) {
        guard let agent = pane.agentSession,
              ["codex", "claude-code"].contains(agent.pluginID),
              let sessionID = pane.claudeSessionID, !sessionID.isEmpty else { return nil }
        paneID = pane.paneId
        self.sessionID = sessionID
        pluginID = agent.pluginID
        sessionName = pane.sessionName
        windowID = pane.stableWindowId
        label = "\(pane.windowName) · \(agent.pluginID == "codex" ? "Codex" : "Claude Code") · \(pane.paneId)"
    }

    public func matches(_ pane: PaneState) -> Bool {
        pane.paneId == paneID && pane.claudeSessionID == sessionID
            && pane.agentSession?.pluginID == pluginID
            && pane.sessionName == sessionName && pane.stableWindowId == windowID
    }

    public func validate(_ pane: PaneState?) throws {
        guard let pane, matches(pane) else {
            throw AgentImageError.message("The Agent changed or exited. Choose the recipient again.")
        }
        guard pane.editorSession == nil else {
            throw AgentImageError.message("Close the Agent's prompt editor before adding the image.")
        }
        switch pane.agentSession?.state {
        case .awaitingPermission, .awaitingReplies, .awaitingPlanApproval:
            throw AgentImageError.message("Answer the Agent's open question or approval before adding the image.")
        default: break
        }
    }

    public static func defaultTarget(in targets: [Self], preferred: Self?) -> Self? {
        if let preferred {
            return targets.first { $0.paneID == preferred.paneID && $0.sessionID == preferred.sessionID
                && $0.pluginID == preferred.pluginID && $0.sessionName == preferred.sessionName && $0.windowID == preferred.windowID }
        }
        return targets.count == 1 ? targets.first : nil
    }
}

public enum AgentImageError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}
