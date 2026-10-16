import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceAgentRecoveryTests {
    @Test("Visible split and detached panes resume before hidden tabs; focused pane goes first")
    func visibleLaunchOrder() async throws {
        let fixture = Fixture()
        var source = fixture.snapshot
        func window(_ index: Int, panes: Int) -> WorkspaceRecoveryWindow {
            var window = source.sessions[0].windows[0]
            window.id = UUID()
            window.index = index
            window.runtimeID = "@\(index)"
            window.panes = (0..<panes).map { offset in
                var pane = fixture.pane
                pane.id = UUID()
                pane.runtimeID = "%\(index * 10 + offset)"
                return pane
            }
            window.selectedPaneID = window.panes.last?.id
            let leaves = window.panes.map { WorkspaceRecoveryLayout.pane($0.id, width: 50, height: 30) }
            window.layout = leaves.count == 1 ? leaves[0] : .horizontal(leaves, width: 101, height: 30)
            return window
        }
        let hidden = window(0, panes: 1)
        let left = window(1, panes: 2)
        let right = window(2, panes: 1)
        let detached = window(3, panes: 1)
        var background = source.sessions[0]
        background.id = UUID()
        background.name = "background"
        background.runtimeID = "$2"
        background.windows = [detached]
        background.selectedWindowID = detached.id
        var selected = source.sessions[0]
        selected.windows = [hidden, left, right]
        selected.selectedWindowID = left.id
        source.sessions = [background, selected]
        source.scenes = [
            .init(id: UUID(), isMain: true, sessions: [
                .init(
                    sessionID: selected.id,
                    sessionName: selected.name,
                    layout: .init(rightSide: [.window(index: 2)], selectedLeft: .window(index: 1), selectedRight: .window(index: 2)),
                    windowIDs: [0: hidden.id, 1: left.id, 2: right.id],
                    ownedWindowIDs: [hidden.id, left.id, right.id],
                    focusedRight: true
                ),
            ], selectedSessionID: selected.id),
            .init(id: UUID(), isMain: false, sessions: [
                .init(
                    sessionID: background.id,
                    sessionName: background.name,
                    layout: .init(selectedLeft: .window(index: 3)),
                    windowIDs: [3: detached.id],
                    ownedWindowIDs: [detached.id],
                    focusedRight: false
                ),
            ], selectedSessionID: background.id),
        ]
        let panes = source.sessions.flatMap(\.windows).flatMap(\.panes)
        source.recovery?.pendingAgentPaneIDs = Set(panes.map(\.id))
        try source.validate()
        let result = WorkspaceTmuxRestoreResult(state: .init(serverID: "new", sessions: source.sessions), failures: [], createdPaneIDs: [])
        var launched: [UUID] = []
        let recovery = WorkspaceAgentRecovery(
            core: { _ in fixture.core }, mode: { .layoutAndAgents }, refresh: { }, version: { _ in "verified-fixture" },
            directoryExists: { _ in true },
            inspect: { runtime in
                let pane = try #require(panes.first { $0.runtimeID == runtime })
                return .init(identity: pane.id, isDead: true, isPlaceholder: true)
            },
            launch: { _, pane, _, _ in launched.append(pane.id) }
        )
        _ = try await recovery.recover(source, result: result, intent: .automatic, save: { $0 })
        #expect(launched == [right.panes[0].id, left.panes[1].id, left.panes[0].id, detached.panes[0].id, hidden.panes[0].id])

        // A Viewer scene cannot prioritize a coincidentally equal local identity.
        source.scenes = [source.scenes[0]]
        source.scenes[0].selectedHostID = "remote-host"
        #expect(WorkspaceAgentRecovery.orderedTargets(in: source).map { $0.2.id } == panes.map(\.id))
    }

    private actor Core: AgentSessionResuming {
        func recoveryDescriptor(sessionID: String, projectPath: String, invocation: AgentResumeInvocation?) throws -> AgentResumeDescriptor {
            throw WorkspaceRecoveryError("Not used")
        }

        func commandForResume(_ descriptor: AgentResumeDescriptor) -> AgentForkLaunch {
            AgentForkLaunch(command: LaunchCommand(command: "/fixture/agent", args: ["resume", descriptor.sessionID]))
        }

        func initialize(_ env: PluginEnv, host: any PluginHost) { }
        func handleIngress(_ frame: IngressFrame) -> PluginEvent? {
            nil
        }

        func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) { }
        func refreshProjects() { }
        func commandForLaunch(projectPath: String) -> LaunchCommand? {
            nil
        }

        func install(configRoot: String?) throws -> InstallResult {
            throw WorkspaceRecoveryError("Not used")
        }

        func uninstall(configRoot: String?) { }
        func installStatus(configRoot: String?) -> PluginInstallStatus {
            .notInstalled
        }

        func applySettings(_ raw: Data) -> SettingsResult {
            .applied
        }

        func shutdown() { }
    }

    @MainActor
    final private class Fixture {
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        var mode = WorkspaceRecoveryMode.layoutAndAgents
        var enabled = true
        var failSave = false
        var uncertainLaunch = false
        var directoryAvailable = true
        var version: String? = "verified-fixture"
        var launches: [WorkspaceRecoveryAgentLaunch] = []
        var commands: [AgentForkLaunch?] = []
        var state: WorkspaceRecoveryAgentPane
        var durable: WorkspaceRecoverySnapshot
        let core = Core()

        init(verified: Bool = true) {
            let paneID = snapshot.sessions[0].windows[0].panes[0].id
            snapshot.sessions[0].windows[0].panes[0].agent = AgentResumeDescriptor(
                pluginID: "codex", sessionID: UUID().uuidString, projectPath: "/tmp", configurationRoot: "/fixture/config", usesDefaultConfiguration: false,
                executable: "/fixture/agent", cliVersion: "verified-fixture",
                automaticResumeUnavailableReason: verified ? nil : "Unverified CLI version"
            )
            snapshot.recovery = .init(bootID: "new-boot", pendingAgentPaneIDs: [paneID])
            self.state = .init(identity: paneID, isDead: true, isPlaceholder: true)
            self.durable = snapshot
        }

        var pane: WorkspaceRecoveryPane {
            snapshot.sessions[0].windows[0].panes[0]
        }

        var result: WorkspaceTmuxRestoreResult {
            .init(state: .init(serverID: "new-server", sessions: snapshot.sessions), failures: [], createdPaneIDs: [])
        }

        var recovery: WorkspaceAgentRecovery {
            WorkspaceAgentRecovery(core: { _ in self.enabled ? self.core : nil }, mode: { self.mode }, refresh: { }, version: { _ in self.version }, directoryExists: { _ in self.directoryAvailable }, inspect: { _ in self.state }, launch: { runtime, pane, record, command in
                #expect(self.durable.recovery?.agentLaunches[pane.id] == record, "A launch must already be durable")
                #expect(record.runtimePaneID == runtime)
                self.launches.append(record)
                self.commands.append(command)
                self.state.isDead = false
                self.state.launchID = record.id
                if self.uncertainLaunch {
                    throw WorkspaceRecoveryError("Connection lost after launch")
                }
            })
        }

        func run(_ intent: WorkspaceAgentRecoveryIntent) async throws -> [WorkspaceRecoveryFailure] {
            let (updated, failures) = try await recovery.recover(snapshot, result: result, intent: intent) { proposed in
                if self.failSave {
                    throw WorkspaceRecoveryError("Disk full")
                }
                self.durable = proposed
                return proposed
            }
            snapshot = updated
            return failures
        }

        func identify() throws {
            let agent = try #require(pane.agent)
            state.source = try #require(AgentForkSource(pane: PaneState(paneId: pane.runtimeID, sessionName: "project", tmuxWindowId: "@1", currentPath: agent.projectPath, agentSession: .init(paneId: pane.runtimeID, pluginID: agent.pluginID), claudeSessionID: agent.sessionID)))
        }
    }

    @Test("Accepted or uncertain launch is reconciled without ever starting a second process", arguments: [false, true])
    func uncertainLaunch(uncertain: Bool) async throws {
        let fixture = Fixture()
        fixture.uncertainLaunch = uncertain
        #expect(try await fixture.run(.automatic).count == 1)
        #expect(fixture.launches.count == 1)
        #expect(fixture.snapshot.recovery?.pendingAgentPaneIDs == [fixture.pane.id])
        #expect(try await fixture.run(.automatic).count == 1)
        #expect(fixture.launches.count == 1)
        try fixture.identify()
        #expect(try await fixture.run(.reconcile).isEmpty)
        #expect(fixture.snapshot.recovery?.pendingAgentPaneIDs.isEmpty == true)
        #expect(fixture.launches.count == 1)
    }

    @Test("Missing directories retain their path and retry action during reconciliation", arguments: [false, true])
    func missingDirectory(asShell: Bool) async throws {
        let fixture = Fixture()
        if asShell {
            fixture.snapshot.sessions[0].windows[0].panes[0].agent = nil
        }
        fixture.directoryAvailable = false
        let source = fixture.snapshot
        for intent in [WorkspaceAgentRecoveryIntent.automatic, .reconcile, .automatic] {
            let failure = try #require(try await fixture.run(intent).first)
            #expect(failure.reason == "The original working directory is unavailable: \(fixture.pane.directory)")
            #expect(failure.blocksInput)
            #expect(failure.canRetry == asShell)
            #expect(failure.canResume == !asShell)
            #expect(fixture.launches.isEmpty)
            #expect(fixture.snapshot == source)
        }
        fixture.directoryAvailable = true
        _ = try await fixture.run(.automatic)
        #expect(fixture.launches.count == 1)
        #expect(fixture.launches.first?.kind == (asShell ? .shell : .resume))
    }

    @Test("Ordinary shell retry works without an Agent plugin and does not duplicate an uncertain launch", arguments: [false, true])
    func plainShell(uncertain: Bool) async throws {
        let fixture = Fixture()
        fixture.snapshot.sessions[0].windows[0].panes[0].agent = nil
        fixture.mode = .layoutOnly
        fixture.enabled = false
        fixture.uncertainLaunch = uncertain
        let waiting = try #require(try await fixture.run(.reconcile).first)
        #expect(waiting.canRetry && waiting.blocksInput)
        #expect(!waiting.canResume && !waiting.canUseShell)
        #expect(fixture.launches.isEmpty)
        let failures = try await fixture.run(.automatic)
        #expect(failures.isEmpty == !uncertain)
        #expect(fixture.commands.count == 1 && fixture.commands[0] == nil)
        #expect(fixture.launches.first?.kind == .shell)
        #expect(try await fixture.run(.reconcile).isEmpty)
        #expect(try await fixture.run(.automatic).isEmpty)
        #expect(fixture.snapshot.recovery?.pendingAgentPaneIDs.isEmpty == true)
        #expect(fixture.launches.count == 1)
    }

    @Test("A manually started process in a pending shell is preserved, even while its old directory is missing")
    func keepManualShell() async throws {
        let fixture = Fixture()
        fixture.snapshot.sessions[0].windows[0].panes[0].agent = nil
        fixture.state.isDead = false
        fixture.directoryAvailable = false
        let failure = try #require(try await fixture.run(.automatic).first)
        #expect(failure.keepCurrentTerminal && failure.canUseShell)
        #expect(!failure.blocksInput && !failure.canRetry)
        #expect(fixture.launches.isEmpty)
        #expect(try await fixture.run(.useShell(fixture.pane.id)).isEmpty)
        #expect(fixture.snapshot.recovery?.pendingAgentPaneIDs.isEmpty == true)
        #expect(try await fixture.run(.automatic).isEmpty)
        #expect(fixture.launches.isEmpty)
    }

    @Test("Linked sessions share one Agent recovery target and one pending result")
    func linkedAgent() async throws {
        let fixture = Fixture()
        var linked = fixture.snapshot.sessions[0]
        linked.id = UUID()
        linked.runtimeID = "$2"
        linked.name = "linked"
        linked.windows[0].index = 7
        fixture.snapshot.sessions.append(linked)
        try fixture.snapshot.validate()
        #expect(WorkspaceAgentRecovery.orderedTargets(in: fixture.snapshot).count == 1)
        #expect(try await fixture.run(.automatic).count == 1)
        #expect(fixture.launches.count == 1)
        try fixture.identify()
        #expect(try await fixture.run(.reconcile).isEmpty)
        #expect(fixture.snapshot.recovery?.pendingAgentPaneIDs.isEmpty == true)
        #expect(fixture.launches.count == 1)
        try fixture.snapshot.validate()
    }

    @Test("Disk failure prevents launch and retains the original pending conversation")
    func journalFailure() async throws {
        let fixture = Fixture()
        fixture.failSave = true
        #expect(try await fixture.run(.automatic).first?.reason == "Disk full")
        #expect(fixture.launches.isEmpty)
        #expect(fixture.durable.recovery?.agentLaunches.isEmpty == true)
        #expect(fixture.durable.recovery?.pendingAgentPaneIDs == [fixture.pane.id])
    }

    @Test("Unknown CLI versions and layout-only mode require an explicit Resume", arguments: [false, true])
    func manualOnly(layoutOnly: Bool) async throws {
        let fixture = Fixture(verified: layoutOnly)
        if layoutOnly {
            fixture.mode = .layoutOnly
        }
        let failures = try await fixture.run(.automatic)
        #expect(failures.first?.canResume == true && failures.first?.blocksInput == true)
        #expect(fixture.launches.isEmpty)
        _ = try await fixture.run(.resume(fixture.pane.id))
        #expect(fixture.launches.count == 1)
    }

    @Test("A disabled plugin is not enabled by explicit resume; shell remains available")
    func disabledPlugin() async throws {
        let fixture = Fixture()
        fixture.enabled = false
        #expect(try await fixture.run(.resume(fixture.pane.id)).first?.reason.contains("disabled") == true)
        #expect(fixture.launches.isEmpty)
        #expect(try await fixture.run(.useShell(fixture.pane.id)).isEmpty)
        #expect(fixture.launches.count == 1 && fixture.launches[0].kind == .shell)
        #expect(fixture.commands.count == 1 && fixture.commands[0] == nil)
        #expect(fixture.pane.agent == nil && fixture.snapshot.recovery?.pendingAgentPaneIDs.isEmpty == true)
    }

    @Test("A dead previously launched process requires explicit retry")
    func deadPreviousLaunch() async throws {
        let fixture = Fixture()
        _ = try await fixture.run(.automatic)
        fixture.state.isDead = true
        #expect(try await fixture.run(.automatic).first?.reason.contains("previous resume ended") == true)
        #expect(fixture.launches.count == 1)
        _ = try await fixture.run(.resume(fixture.pane.id))
        #expect(fixture.launches.count == 2)
        #expect(fixture.launches[0].id != fixture.launches[1].id)
    }

    @Test("Keeping an unverified live terminal clears recovery without killing or restarting it")
    func keepLiveTerminal() async throws {
        let fixture = Fixture()
        fixture.state.isDead = false
        let failure = try #require(try await fixture.run(.automatic).first)
        #expect(failure.keepCurrentTerminal && !failure.blocksInput && !failure.canResume)
        #expect(try await fixture.run(.useShell(fixture.pane.id)).isEmpty)
        #expect(fixture.launches.isEmpty)
        #expect(fixture.snapshot.recovery?.pendingAgentPaneIDs.isEmpty == true)
    }

    @Test("Changed or unowned pane identities are never launched", arguments: [false, true])
    func changedPane(identityChanged: Bool) async throws {
        let fixture = Fixture()
        if identityChanged {
            fixture.state.identity = UUID()
        } else {
            fixture.state.isPlaceholder = false
        }
        #expect(try await fixture.run(.resume(fixture.pane.id)).count == 1)
        #expect(try await fixture.run(.useShell(fixture.pane.id)).count == 1)
        #expect(fixture.launches.isEmpty)
    }

    @Test("An upgraded or unavailable executable requires explicit Resume", arguments: [nil, "upgraded"] as [String?])
    func changedVersion(version: String?) async throws {
        let fixture = Fixture()
        fixture.version = version
        #expect(try await fixture.run(.automatic).first?.reason.contains("CLI changed") == true)
        #expect(fixture.launches.isEmpty)
        _ = try await fixture.run(.resume(fixture.pane.id))
        #expect(fixture.launches.count == 1)
    }
}
