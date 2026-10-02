import CtrlxNetworking

/// A curated command catalog, not runtime capability discovery. Entries have a
/// useful bare invocation; session/account actions appear in a separate section.
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
    case ide
    case vim
    case apps
    case memories
    case copy
    case `import`
    case feedback
    case initialize = "init"
    case app
    case side
    case raw
    case title
    case pets
    case advisor
    case artifacts
    case bug
    case chrome
    case color
    case desktop
    case export
    case focus
    case mobile
    case passes
    case powerup
    case privacySettings = "privacy-settings"
    case radio
    case rateLimitOptions = "rate-limit-options"
    case recap
    case releaseNotes = "release-notes"
    case remoteControl = "remote-control"
    case remoteEnv = "remote-env"
    case sandbox
    case scrollSpeed = "scroll-speed"
    case skillDoctor = "skill-doctor"
    case teleport
    case tui
    case upgrade
    case usageCredits = "usage-credits"
    case voice
    case webSetup = "web-setup"
    case workflows
    case doctor
    case debug
    case insights
    case securityReview = "security-review"
    case simplify
    case new
    case clear
    case archive
    case delete
    case approve
    case background
    case rewind
    case stop
    case login
    case logout
    case exit

    package var id: String { rawValue }
    package var text: String { "/\(rawValue)" }
    /// Keep Return outside the TUI's rapid-input/paste window. Like the reply
    /// composer, send the pause to the host so network batching cannot remove it.
    package var keys: [TmuxKey] { [.text(text), .delay(200), .enter] }

    package var isSessionAction: Bool {
        switch self {
        case .new, .clear, .archive, .delete, .approve, .background, .rewind, .stop, .login, .logout, .exit: true
        default: false
        }
    }

    /// The panel's display order is also the send allowlist. Do not give other
    /// agents the Codex catalog. Checked against Codex 0.160.0 / Claude 2.1.276;
    /// aliases, removed entries and required-inline-argument commands stay out.
    package static func commands(for pluginID: String) -> [Self] {
        switch pluginID {
        case "codex": [
            .model, .status, .usage,
            .fast, .personality, .plan, .goal, .compact, .resume, .fork, .rename, .agent,
            .diff, .review, .ps,
            .permissions, .skills, .mcp, .plugins, .theme, .keymap, .statusline, .experimental, .debugConfig,
            .ide, .vim, .apps, .hooks, .memories, .copy, .import, .feedback, .initialize,
            .app, .side, .raw, .title, .pets,
            .new, .clear, .archive, .delete, .approve, .stop, .logout, .exit,
        ]
        // Checked against Claude 2.1.276: bare /rename auto-names the session;
        // /branch switches to a conversation copy, while /fork runs one in the
        // background. /agents is removed; /plugin remains singular.
        case "claude-code": [
            .model, .status, .usage,
            .effort, .fast, .plan, .goal, .compact, .autocompact, .context, .resume, .branch, .fork, .rename,
            .diff, .review,
            .permissions, .skills, .mcp, .plugin, .reloadSkills, .reloadPlugins,
            .config, .theme, .outputStyle, .memory, .hooks, .tasks, .help,
            .advisor, .artifacts, .copy, .export, .import, .feedback, .bug, .ide, .chrome, .color,
            .desktop, .mobile, .passes, .powerup, .privacySettings, .radio, .rateLimitOptions, .recap,
            .releaseNotes, .remoteControl, .remoteEnv, .sandbox, .scrollSpeed, .skillDoctor, .teleport,
            .tui, .focus, .upgrade, .usageCredits, .voice, .webSetup, .workflows,
            .statusline, .doctor, .debug, .initialize, .insights, .securityReview, .simplify,
            .background, .rewind, .clear, .stop, .login, .logout, .exit,
        ]
        default: []
        }
    }
}

package struct AgentCommandSection: Identifiable, Equatable, Sendable {
    package enum ID: CaseIterable, Hashable, Sendable {
        case commands
        case sessionActions
    }

    package let id: ID
    package let commands: [AgentQuickCommand]

    package static func sections(for commands: [AgentQuickCommand]) -> [Self] {
        ID.allCases.compactMap { id in
            let entries = commands.filter { $0.isSessionAction == (id == .sessionActions) }
            return entries.isEmpty ? nil : Self(id: id, commands: entries)
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
