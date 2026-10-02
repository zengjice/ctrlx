import CtrlxNetworking
import Testing
@testable import CtrlxCommon

@Suite("Agent command panel")
struct AgentCommandMenuTests {
    private func context(
        hostID: String = "host-a", paneID: String = "%12", pluginID: String = "codex",
        state: AgentState = .idle, connected: Bool = true, ready: Bool = true,
        externalEditor: Bool = false, revision: UInt64 = 0
    ) -> AgentCommandContext? {
        AgentCommandContext(
            hostID: hostID, paneID: paneID,
            session: AgentSession(paneId: paneID, pluginID: pluginID, state: state),
            isConnected: connected, isInputAvailable: ready,
            hasExternalEditor: externalEditor, inputRevision: revision
        )
    }

    @Test("Codex includes common zero-argument commands in stable display order")
    func codexCatalog() {
        #expect(AgentQuickCommand.commands(for: "codex").map(\.text) == [
            "/model", "/status", "/usage",
            "/fast", "/personality", "/plan", "/goal", "/compact", "/resume", "/fork", "/rename", "/agent",
            "/diff", "/review", "/ps",
            "/permissions", "/skills", "/mcp", "/plugins", "/theme", "/keymap", "/statusline", "/experimental", "/debug-config",
            "/ide", "/vim", "/apps", "/hooks", "/memories", "/copy", "/import", "/feedback", "/init",
            "/app", "/side", "/raw", "/title", "/pets",
            "/new", "/clear", "/archive", "/delete", "/approve", "/stop", "/logout", "/exit",
        ])
        #expect(context()?.canSend == true)
    }

    @Test("Claude includes its own zero-argument commands in stable display order")
    func claudeCatalog() {
        let claude = context(pluginID: "claude-code")
        #expect(claude?.commands.map(\.text) == [
            "/model", "/status", "/usage",
            "/effort", "/fast", "/plan", "/goal", "/compact", "/autocompact", "/context", "/resume", "/branch", "/fork", "/rename",
            "/diff", "/review",
            "/permissions", "/skills", "/mcp", "/plugin", "/reload-skills", "/reload-plugins",
            "/config", "/theme", "/output-style", "/memory", "/hooks", "/tasks", "/help",
            "/advisor", "/artifacts", "/copy", "/export", "/import", "/feedback", "/bug", "/ide", "/chrome", "/color",
            "/desktop", "/mobile", "/passes", "/powerup", "/privacy-settings", "/radio", "/rate-limit-options", "/recap",
            "/release-notes", "/remote-control", "/remote-env", "/sandbox", "/scroll-speed", "/skill-doctor", "/teleport",
            "/tui", "/focus", "/upgrade", "/usage-credits", "/voice", "/web-setup", "/workflows",
            "/statusline", "/doctor", "/debug", "/init", "/insights", "/security-review", "/simplify",
            "/background", "/rewind", "/clear", "/stop", "/login", "/logout", "/exit",
        ])
        #expect(claude?.canSend == true)
    }

    @Test("Each agent accepts only its own catalog", arguments: ["codex", "claude-code"])
    func agentAllowlist(pluginID: String) throws {
        let current = try #require(context(pluginID: pluginID))
        for command in AgentQuickCommand.allCases {
            let request = AgentCommandRequest(command, in: current)
            #expect((request != nil) == current.commands.contains(command))
        }
    }

    @Test("Agent-specific names and bare-command semantics do not leak between catalogs")
    func distinctCommandSemantics() {
        for command in [AgentQuickCommand.agent, .plugins, .vim, .apps, .memories, .app, .side, .raw, .title, .pets,
                        .new, .archive, .delete, .approve] {
            #expect(AgentCommandRequest(command, in: context()) != nil)
            #expect(AgentCommandRequest(command, in: context(pluginID: "claude-code")) == nil)
        }
        for command in [AgentQuickCommand.plugin, .context, .memory, .tasks, .help,
                        .effort, .autocompact, .branch, .outputStyle, .reloadSkills, .reloadPlugins,
                        .advisor, .chrome, .export, .desktop, .login, .background, .rewind] {
            #expect(AgentCommandRequest(command, in: context(pluginID: "claude-code")) != nil)
            #expect(AgentCommandRequest(command, in: context()) == nil)
        }
    }

    @Test("Claude's expanded catalog submits bare commands without adding action-changing flags")
    func claudeExpandedCommands() throws {
        let claude = try #require(context(pluginID: "claude-code"))
        for text in ["/effort", "/diff", "/review", "/goal", "/autocompact", "/output-style",
                     "/branch", "/fork", "/fast", "/rename", "/reload-skills", "/reload-plugins",
                     "/advisor", "/copy", "/export", "/ide", "/chrome", "/statusline",
                     "/release-notes", "/login", "/logout", "/clear", "/exit"] {
            let command = try #require(claude.commands.first { $0.text == text })
            let request = try #require(AgentCommandRequest(command, in: claude))
            #expect(request.isValid(in: claude))
            #expect(request.command.keys == [.text(text), .delay(200), .enter])
        }
    }

    @Test("Claude excludes removed entries and duplicate aliases")
    func claudeExcludedCommands() {
        let commands = Set(AgentQuickCommand.commands(for: "claude-code").map(\.text))
        #expect(commands.isDisjoint(with: [
            "/agents", "/agent", "/plugins", "/cost", "/stats", "/code-review",
            "/vim", "/pr-comments", "/ultraplan", "/new", "/reset", "/settings", "/app", "/rc", "/tp", "/bg",
        ]))
        #expect(AgentQuickCommand(rawValue: "agents") == nil)
    }

    @Test("Panel buttons use the unique send allowlist in stable order", arguments: ["codex", "claude-code"])
    func panelCommands(pluginID: String) throws {
        let current = try #require(context(pluginID: pluginID))
        #expect(current.commands == AgentQuickCommand.commands(for: pluginID))
        #expect(Set(current.commands.map(\.id)).count == current.commands.count)
        #expect(current.commands.allSatisfy { $0.text == "/\($0.id)" })
        #expect(Array(current.commands.prefix(3)) == [.model, .status, .usage])
    }

    @Test("Both panels share a complete ordered partition with session actions last", arguments: ["codex", "claude-code"])
    func panelSections(pluginID: String) throws {
        let commands = AgentQuickCommand.commands(for: pluginID)
        let sections = AgentCommandSection.sections(for: commands)
        #expect(sections.map(\.id) == [.commands, .sessionActions])
        #expect(sections.flatMap(\.commands) == commands)
        let ordinary = try #require(sections.first)
        let actions = try #require(sections.last)
        #expect(ordinary.commands.allSatisfy { !$0.isSessionAction })
        #expect(actions.commands.allSatisfy { $0.isSessionAction })
        #expect(actions.commands.contains(.logout))
        #expect(actions.commands.contains(.clear))
        #expect(actions.commands.contains(.exit))
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test("Section building omits empty sections and preserves order within each group")
    func emptyAndPartialSections() {
        #expect(AgentCommandSection.sections(for: []).isEmpty)
        #expect(AgentCommandSection.sections(for: AgentQuickCommand.commands(for: "unknown")).isEmpty)
        #expect(AgentCommandSection.sections(for: [.status, .model]) == [
            AgentCommandSection(id: .commands, commands: [.status, .model]),
        ])
        #expect(AgentCommandSection.sections(for: [.logout, .exit]) == [
            AgentCommandSection(id: .sessionActions, commands: [.logout, .exit]),
        ])
        #expect(AgentCommandSection.sections(for: [.logout, .status, .exit, .model]) == [
            AgentCommandSection(id: .commands, commands: [.status, .model]),
            AgentCommandSection(id: .sessionActions, commands: [.logout, .exit]),
        ])
    }

    @Test("Shared new entries are available for both agents without confirmation", arguments: [
        AgentQuickCommand.fast, .fork, .hooks, .ide, .copy, .import, .feedback, .initialize,
        .statusline, .stop, .clear, .logout, .exit,
    ])
    func sharedExpandedCommands(command: AgentQuickCommand) throws {
        for pluginID in ["codex", "claude-code"] {
            let current = try #require(context(pluginID: pluginID))
            let request = try #require(AgentCommandRequest(command, in: current))
            #expect(request.isValid(in: current))
            #expect(request.command.keys == [.text(command.text), .delay(200), .enter])
        }
    }

    @Test("Panel identity belongs to the captured target; input changes still invalidate its snapshot")
    func panelIdentity() throws {
        let captured = try #require(context())
        #expect(captured.id == captured.target)
        for other in [context(hostID: "host-b"), context(paneID: "%13"), context(pluginID: "claude-code")] {
            #expect(other?.id != captured.id)
            #expect(!captured.hasSameInput(as: other))
        }
        for changed in [context(revision: 1), context(connected: false), context(ready: false)] {
            #expect(changed?.id == captured.id)
            #expect(changed != captured)
        }
        #expect(!captured.hasSameInput(as: context(revision: 1)))
        #expect(!captured.hasSameInput(as: nil))
        #expect(context(state: .working) == captured)
    }

    @Test("One-tap catalogs exclude argument-only, Windows-only and unsupported commands", arguments: ["codex", "claude-code"])
    func excludedCommands(pluginID: String) {
        let commands = Set(AgentQuickCommand.commands(for: pluginID).map(\.text))
        #expect(commands.isDisjoint(with: [
            "/quit", "/mention", "/sandbox-add-read-dir", "/setup-default-sandbox", "/add-dir", "/cd", "/batch",
            "/deep-research", "/subtask", "/heapdump",
        ]))
    }

    @Test("Every command belongs to at least one agent catalog")
    func catalogCoverage() {
        let commands = ["codex", "claude-code"].flatMap { AgentQuickCommand.commands(for: $0) }
        #expect(Set(AgentQuickCommand.allCases) == Set(commands))
    }

    @Test("Unknown agents do not inherit another agent's commands", arguments: ["zsh", "pi", "", "Codex"])
    func unknownAgent(pluginID: String) {
        #expect(AgentQuickCommand.commands(for: pluginID).isEmpty)
        #expect(context(pluginID: pluginID) == nil)
    }

    @Test("Missing or mismatched pane sessions cannot supply commands")
    func missingSession() {
        for paneID: String? in [nil, "%12"] {
            #expect(AgentCommandContext(
                hostID: "host-a", paneID: paneID, session: nil,
                isConnected: true, isInputAvailable: true, hasExternalEditor: false, inputRevision: 0
            ) == nil)
        }
        #expect(AgentCommandContext(
            hostID: "host-a", paneID: "%12", session: AgentSession(paneId: "%99", pluginID: "codex"),
            isConnected: true, isInputAvailable: true, hasExternalEditor: false, inputRevision: 0
        ) == nil)
    }

    @Test("Offline, background/unready and external editors allow browsing but block submission")
    func unavailable() throws {
        let captured = try #require(context())
        for unavailable in [context(connected: false), context(ready: false),
                            context(externalEditor: true)] {
            // A non-nil context is sufficient to open the command panel.
            let browsable = try #require(unavailable)
            #expect(browsable.commands == captured.commands)
            #expect(captured.hasSameInput(as: browsable))
            #expect(!browsable.canSend)
            #expect(browsable.unavailableReason != nil)
            #expect(AgentCommandRequest(.model, in: browsable) == nil)
        }
    }

    @Test("Working agents accept every catalog command without a second confirmation", arguments: ["codex", "claude-code"])
    func working(pluginID: String) throws {
        let working = try #require(context(pluginID: pluginID, state: .working))
        #expect(working.canSend)
        #expect(working.commands == context(pluginID: pluginID)?.commands)
        for command in working.commands {
            let request = try #require(AgentCommandRequest(command, in: working))
            #expect(request.isValid(in: working))
            #expect(request.isValid(in: context(pluginID: pluginID, state: .idle)))
            #expect(request.isValid(in: context(pluginID: pluginID, state: .doneWorking(summary: "Finished"))))
            #expect(request.command.keys == [.text(command.text), .delay(200), .enter])
            let idleRequest = try #require(AgentCommandRequest(command, in: context(pluginID: pluginID)))
            #expect(idleRequest.isValid(in: working))
        }
    }

    @Test("A panel opened while unavailable follows live recovery without losing its target")
    func availabilityRecovery() throws {
        let captured = try #require(context(connected: false))
        for current in [context(ready: false), context(), context(state: .working),
                        context(connected: false), context(externalEditor: true), context()] {
            let live = try #require(current)
            #expect(captured.hasSameInput(as: live))
            let request = AgentCommandRequest(.status, in: live)
            #expect((request != nil) == live.canSend)
            if let request {
                #expect(request.isValid(in: live))
                #expect(!request.isValid(in: context(connected: false)))
                #expect(!request.isValid(in: context(revision: 1)))
            }
        }
    }

    @Test("Finished and handled sessions both allow commands")
    func finished() {
        #expect(context(state: .doneWorking(summary: "Finished"))?.canSend == true)
        #expect(context(state: .idle)?.canSend == true)
    }

    @Test("All blocking agent forms reject slash commands", arguments: [
        AgentState.awaitingPermission(PermissionRequest(title: "Shell", description: "Run pwd"), requestID: "p"),
        AgentState.awaitingReplies(AskUserQuestionRequest(questions: []), requestID: "q"),
        AgentState.awaitingPlanApproval(ApprovePlanRequest(title: "Plan", plan: "Run tests"), requestID: "a"),
    ])
    func blockingForms(state: AgentState) throws {
        let blocked = try #require(context(state: state))
        #expect(!blocked.commands.isEmpty)
        #expect(blocked.hasSameInput(as: context()))
        #expect(!blocked.canSend)
        #expect(AgentCommandRequest(.model, in: blocked) == nil)
        let request = try #require(AgentCommandRequest(.model, in: context()))
        #expect(!request.isValid(in: blocked))
    }

    @Test("Selecting a command immediately supplies text, host-side pause and Return", arguments: ["codex", "claude-code"])
    func directSubmission(pluginID: String) throws {
        let current = try #require(context(pluginID: pluginID))
        for command in current.commands {
            let request = try #require(AgentCommandRequest(command, in: current))
            #expect(request.isValid(in: current))
            #expect(request.command.keys == [.text(command.text), .delay(200), .enter])
        }
    }

    @Test("Commands send one real Return without clearing, interrupting or inserting a literal newline")
    func submissionDoesNotAlterDraft() {
        for command in AgentQuickCommand.allCases {
            #expect(!command.text.contains("\n"))
            #expect(!command.text.contains("\r"))
            #expect(command.keys.count == 3)
            #expect(command.keys.filter { $0 == .enter }.count == 1)
            #expect(command.keys == [.text(command.text), .delay(200), .enter])
        }
    }

    @Test("A panel action is tied to host, pane, agent and local input revision")
    func changedTargetOrInput() throws {
        let request = try #require(AgentCommandRequest(.status, in: context()))
        for changed in [context(hostID: "host-b"), context(paneID: "%13"),
                        context(pluginID: "claude-code"), context(revision: 1),
                        context(connected: false),
                        context(externalEditor: true), context(ready: false), nil] {
            #expect(!request.isValid(in: changed))
        }
    }

    @Test("Advancing input revision after submission rejects duplicate stale actions")
    func invalidate() throws {
        let request = try #require(AgentCommandRequest(.model, in: context()))
        #expect(request.isValid(in: context()))
        #expect(!request.isValid(in: context(revision: 1)))
        #expect(AgentCommandRequest(.model, in: nil) == nil)
    }

    @Test("Expanded commands retain availability and target guards", arguments: ["codex", "claude-code"])
    func expandedCommandGuards(pluginID: String) throws {
        let current = try #require(context(pluginID: pluginID))
        for command in current.commands {
            let request = try #require(AgentCommandRequest(command, in: current))
            for changed in [context(pluginID: pluginID, connected: false), context(pluginID: pluginID, ready: false),
                            context(pluginID: pluginID, externalEditor: true),
                            context(pluginID: pluginID, state: .awaitingReplies(AskUserQuestionRequest(questions: []), requestID: "q")),
                            context(pluginID: pluginID, state: .awaitingPermission(PermissionRequest(title: "Shell", description: "Run pwd"), requestID: "p")),
                            context(pluginID: pluginID, state: .awaitingPlanApproval(ApprovePlanRequest(title: "Plan", plan: "Run tests"), requestID: "a")),
                            context(paneID: "%13", pluginID: pluginID), context(hostID: "host-b", pluginID: pluginID),
                            context(pluginID: pluginID, revision: 1), context(pluginID: pluginID == "codex" ? "claude-code" : "codex")] {
                #expect(!request.isValid(in: changed))
                if let changed, !changed.canSend {
                    #expect(AgentCommandRequest(command, in: changed) == nil)
                }
            }
        }
    }
}
