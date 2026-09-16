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
            "/plan", "/compact", "/resume", "/fork", "/rename", "/agent",
            "/diff", "/review", "/ps",
            "/permissions", "/skills", "/mcp", "/plugins", "/theme", "/statusline", "/debug-config",
        ])
        #expect(context()?.canSend == true)
    }

    @Test("Claude retains its original catalog and rejects Codex-only actions")
    func claudeCatalog() {
        let claude = context(pluginID: "claude-code")
        #expect(claude?.commands == [.model, .status, .usage])
        #expect(claude?.canSend == true)
        for command in AgentQuickCommand.allCases where ![.model, .status, .usage].contains(command) {
            #expect(AgentCommandRequest(command, in: claude) == nil)
        }
    }

    @Test("Panel buttons use the unique send allowlist in stable order", arguments: ["codex", "claude-code"])
    func panelCommands(pluginID: String) throws {
        let current = try #require(context(pluginID: pluginID))
        #expect(current.commands == AgentQuickCommand.commands(for: pluginID))
        #expect(Set(current.commands.map(\.id)).count == current.commands.count)
        #expect(current.commands.allSatisfy { $0.text == "/\($0.id)" })
        #expect(Array(current.commands.prefix(3)) == [.model, .status, .usage])
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

    @Test("One-tap catalog excludes destructive, interruption and argument-only commands")
    func excludedCommands() {
        let commands = Set(AgentQuickCommand.commands(for: "codex").map(\.text))
        #expect(commands.isDisjoint(with: [
            "/new", "/clear", "/delete", "/archive", "/exit", "/quit", "/logout", "/stop", "/init",
            "/mention", "/sandbox-add-read-dir", "/approve",
        ]))
        #expect(Set(AgentQuickCommand.allCases.map(\.text)) == commands)
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

    @Test("Working agents accept every catalog command without a second confirmation", arguments: AgentQuickCommand.allCases)
    func working(command: AgentQuickCommand) throws {
        let working = try #require(context(state: .working))
        let request = try #require(AgentCommandRequest(command, in: working))
        #expect(working.canSend)
        #expect(request.isValid(in: context(state: .working)))
        #expect(request.isValid(in: context(state: .idle)))
        #expect(request.isValid(in: context(state: .doneWorking(summary: "Finished"))))
        #expect(request.command.keys == [.text(command.text), .delay(200), .enter])
        let idleRequest = try #require(AgentCommandRequest(command, in: context()))
        #expect(idleRequest.isValid(in: working))
    }

    @Test("Claude working state keeps the same three commands available")
    func claudeWorking() throws {
        let working = try #require(context(pluginID: "claude-code", state: .working))
        #expect(working.commands == [.model, .status, .usage])
        for command in working.commands {
            let request = try #require(AgentCommandRequest(command, in: working))
            #expect(request.isValid(in: working))
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

    @Test("Selecting a command immediately supplies text, host-side pause and Return", arguments: AgentQuickCommand.allCases)
    func directSubmission(command: AgentQuickCommand) throws {
        let current = context()
        let request = try #require(AgentCommandRequest(command, in: current))
        #expect(request.isValid(in: current))
        #expect(request.command.keys == [.text(command.text), .delay(200), .enter])
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

    @Test("Expanded commands retain availability and target guards", arguments: AgentQuickCommand.allCases)
    func expandedCommandGuards(command: AgentQuickCommand) throws {
        let request = try #require(AgentCommandRequest(command, in: context()))
        for changed in [context(connected: false), context(ready: false),
                        context(externalEditor: true)] {
            #expect(AgentCommandRequest(command, in: changed) == nil)
            #expect(!request.isValid(in: changed))
        }
        #expect(!request.isValid(in: context(paneID: "%13")))
        #expect(!request.isValid(in: context(hostID: "host-b")))
    }
}
