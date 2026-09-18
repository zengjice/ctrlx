import CtrlxNetworking

/// A curated command catalog, not runtime capability discovery. Keep commands
/// that delete/reset sessions, stop work, or require inline arguments out of it.
package enum AgentQuickCommand: String, CaseIterable, Identifiable, Sendable {
    case model
    case status
    case usage
    case effort
    case fast
    case personality
    case plan
    case goal
    case compact
    case autocompact
    case context
    case resume
    case fork
    case branch
    case rename
    case agent
    case diff
    case review
    case ps
    case tasks
    case permissions
    case skills
    case reloadSkills = "reload-skills"
    case mcp
    case plugins
    case plugin
    case reloadPlugins = "reload-plugins"
    case config
    case memory
    case hooks
    case theme
    case outputStyle = "output-style"
    case keymap
    case experimental
    case statusline
    case debugConfig = "debug-config"
    case help

    package var id: String { rawValue }
    package var text: String { "/\(rawValue)" }
    /// Keep Return outside the TUI's rapid-input/paste window. Like the reply
    /// composer, send the pause to the host so network batching cannot remove it.
    package var keys: [TmuxKey] { [.text(text), .delay(200), .enter] }

    /// The panel's display order is also the send allowlist. Do not give other
    /// agents the Codex catalog.
    package static func commands(for pluginID: String) -> [Self] {
        switch pluginID {
        case "codex": [
            .model, .status, .usage,
            .fast, .personality, .plan, .goal, .compact, .resume, .fork, .rename, .agent,
            .diff, .review, .ps,
            .permissions, .skills, .mcp, .plugins, .theme, .keymap, .statusline, .experimental, .debugConfig,
        ]
        // Checked against Claude 2.1.276: bare /rename auto-names the session;
        // /branch switches to a conversation copy, while /fork runs one in the
        // background. /agents is removed; /plugin remains singular.
        case "claude-code": [
            .model, .status, .usage,
            .effort, .plan, .goal, .compact, .autocompact, .context, .resume, .branch, .rename,
            .diff, .review,
            .permissions, .skills, .mcp, .plugin, .reloadSkills, .reloadPlugins,
            .config, .theme, .outputStyle, .memory, .hooks, .tasks, .help,
        ]
        default: []
        }
    }
}

package struct AgentCommandContext: Identifiable, Equatable, Sendable {
    package struct Target: Hashable, Sendable {
        package let hostID: String
        package let paneID: String
        package let pluginID: String
    }

    package let target: Target
    /// Reject stale panel actions if local input changed while the panel was open.
    /// This is NOT a remote draft model.
    package let inputRevision: UInt64
    package let unavailableReason: String?

    package var id: Target { target }
    package var commands: [AgentQuickCommand] { AgentQuickCommand.commands(for: target.pluginID) }
    package var canSend: Bool { unavailableReason == nil }

    /// Availability may change while browsing; only a different input target or
    /// local draft edit makes the captured panel stale.
    package func hasSameInput(as current: Self?) -> Bool {
        guard let current else { return false }
        return target == current.target && inputRevision == current.inputRevision
    }

    package init?(
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
package struct AgentCommandRequest: Equatable, Sendable {
    package let command: AgentQuickCommand
    package let context: AgentCommandContext

    package init?(_ command: AgentQuickCommand, in context: AgentCommandContext?) {
        guard let context, context.canSend, context.commands.contains(command) else { return nil }
        self.command = command
        self.context = context
    }

    package func isValid(in current: AgentCommandContext?) -> Bool {
        context.hasSameInput(as: current) && context.canSend
            && current?.canSend == true && current?.commands.contains(command) == true
    }
}
