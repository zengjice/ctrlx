import CtrlxNetworking

/// A curated command catalog, not runtime capability discovery. Keep commands
/// that delete/reset sessions, stop work, or require inline arguments out of it.
enum AgentQuickCommand: String, CaseIterable, Identifiable, Sendable {
    case model
    case status
    case usage
    case plan
    case compact
    case resume
    case fork
    case rename
    case agent
    case diff
    case review
    case ps
    case permissions
    case skills
    case mcp
    case plugins
    case theme
    case statusline
    case debugConfig = "debug-config"

    var id: String { rawValue }
    var text: String { "/\(rawValue)" }
    /// Keep Return outside the TUI's rapid-input/paste window. Like the reply
    /// composer, send the pause to the host so network batching cannot remove it.
    var keys: [TmuxKey] { [.text(text), .delay(200), .enter] }

    /// The panel's display order is also the send allowlist. Do not give other
    /// agents the Codex catalog.
    static func commands(for pluginID: String) -> [Self] {
        switch pluginID {
        case "codex": [
            .model, .status, .usage,
            .plan, .compact, .resume, .fork, .rename, .agent,
            .diff, .review, .ps,
            .permissions, .skills, .mcp, .plugins, .theme, .statusline, .debugConfig,
        ]
        case "claude-code": [.model, .status, .usage]
        default: []
        }
    }
}

struct AgentCommandContext: Identifiable, Equatable, Sendable {
    struct Target: Hashable, Sendable {
        let hostID: String
        let paneID: String
        let pluginID: String
    }

    let target: Target
    /// Reject stale panel actions if local input changed while the panel was open.
    /// This is NOT a remote draft model.
    let inputRevision: UInt64
    let unavailableReason: String?

    var id: Target { target }
    var commands: [AgentQuickCommand] { AgentQuickCommand.commands(for: target.pluginID) }
    var canSend: Bool { unavailableReason == nil }

    /// Availability may change while browsing; only a different input target or
    /// local draft edit makes the captured panel stale.
    func hasSameInput(as current: Self?) -> Bool {
        guard let current else { return false }
        return target == current.target && inputRevision == current.inputRevision
    }

    init?(
        hostID: String,
        paneID: String?,
        session: AgentSession?,
        isConnected: Bool,
        isInputAvailable: Bool,
        hasExternalEditor: Bool,
        inputRevision: UInt64
    ) {
        guard let paneID, let session, session.paneId == paneID,
              !AgentQuickCommand.commands(for: session.pluginID).isEmpty
        else { return nil }
        self.target = Target(hostID: hostID, paneID: paneID, pluginID: session.pluginID)
        self.inputRevision = inputRevision
        if !isConnected {
            unavailableReason = "Reconnect to the host to send commands."
        } else if !isInputAvailable {
            unavailableReason = "Wait until the terminal is ready."
        } else if hasExternalEditor {
            unavailableReason = "Close the external editor before sending an agent command."
        } else {
            switch session.state {
            case .awaitingPlanApproval, .awaitingPermission, .awaitingReplies:
                unavailableReason = "Answer the agent's pending question or approval first."
            case .idle, .working, .doneWorking:
                // The agent decides which slash commands it accepts mid-turn.
                unavailableReason = nil
            }
        }
    }
}

/// Selecting an item submits immediately. Capture its target so a stale panel
/// action cannot silently type into a different pane or agent.
struct AgentCommandRequest: Equatable, Sendable {
    let command: AgentQuickCommand
    let context: AgentCommandContext

    init?(_ command: AgentQuickCommand, in context: AgentCommandContext?) {
        guard let context, context.canSend, context.commands.contains(command) else { return nil }
        self.command = command
        self.context = context
    }

    func isValid(in current: AgentCommandContext?) -> Bool {
        context.hasSameInput(as: current) && context.canSend
            && current?.canSend == true && current?.commands.contains(command) == true
    }
}
