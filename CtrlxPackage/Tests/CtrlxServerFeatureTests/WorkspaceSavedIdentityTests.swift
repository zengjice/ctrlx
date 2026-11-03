import ClaudeCodePluginCore
import CodexPluginCore
import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct WorkspaceSavedIdentityTests {
    private func identity(_ workspace: WorkspacePaneIdentity?, runtime: String = "%old") throws -> AgentSessionIdentity {
        var pane = PaneState(paneId: runtime, sessionName: "old-name", tmuxWindowId: "@old", currentPath: "/old-project", agentSession: .init(paneId: runtime, pluginID: "codex"), claudeSessionID: UUID().uuidString)
        pane.workspaceIdentity = workspace
        return try AgentSessionIdentity(source: #require(AgentForkSource(pane: pane)), processID: "old-pid", runtimeID: "old-process")
    }

    @Test("Saved lookup matches persistent ownership across renames and tmux incarnations")
    func persistentLookup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-saved-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspacePaneIdentity(serverID: "old-server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let saved = try identity(workspace)
        #expect(await AgentSessionIdentityClient.diskBacked(stateRoot: directory).save(saved))
        let client = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
        #expect(await client.load("%new") == nil)
        #expect(try await client.recoverySource([workspace.sessionID], workspace.windowID, workspace.paneID) == saved.source)
        #expect(try await client.recoverySource([UUID()], workspace.windowID, workspace.paneID) == nil)
        #expect(try await client.recoverySource([workspace.sessionID], UUID(), workspace.paneID) == nil)
        #expect(try await client.recoverySource([workspace.sessionID], workspace.windowID, UUID()) == nil)
        // A linked session is eligible, but process-instance validation stays strict.
        #expect(try await client.recoverySource([UUID(), workspace.sessionID], workspace.windowID, workspace.paneID) == saved.source)
        let current = PaneState(paneId: "%old", sessionName: "old-name", tmuxWindowId: "@old")
        #expect(!saved.matches(pane: current, detected: .init(path: "/old-project", pluginID: "codex", processIDs: ["old-pid"]), runtimeID: "new-process"))
    }

    @Test("Legacy identities are ignored and multiple matching records never choose a conversation")
    func ambiguousLookup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-ambiguous-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspacePaneIdentity(serverID: "old-server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let client = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
        #expect(try await client.save(identity(nil)))
        #expect(try await client.recoverySource([workspace.sessionID], workspace.windowID, workspace.paneID) == nil)
        #expect(try await client.save(identity(workspace)))
        #expect(try await client.save(identity(workspace, runtime: "%another")))
        await #expect(throws: WorkspaceRecoveryError.self) {
            try await client.recoverySource([workspace.sessionID], workspace.windowID, workspace.paneID)
        }
    }

    @MainActor
    @Test("A revoked conversation cannot return from the independent cache after restart", arguments: ["plugin", "process", "shell"])
    func revokedIdentityAfterRestart(replacement: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-revoked-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        let session = snapshot.sessions[0], window = session.windows[0]
        var pane = window.panes[0]
        let workspace = WorkspacePaneIdentity(serverID: "old-server", sessionID: session.id, windowID: window.id, paneID: pane.id)
        let saved = try identity(workspace)
        let client = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
        #expect(await client.save(saved))
        let historyRoot = directory.appendingPathComponent("codex")
        let history = historyRoot.appendingPathComponent("sessions/rollout-date-\(saved.source.sessionID).jsonl")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: history)
        #expect(try await AgentForkHistoryClient.liveValue.root(saved.source.sessionID, [historyRoot.path], .codex) == historyRoot.resolvingSymlinksInPath().path)
        if replacement != "shell" {
            WorkspaceAgentCapture.record(
                .init(pluginID: "codex", sessionID: saved.source.sessionID, projectPath: pane.directory, configurationRoot: historyRoot.path, usesDefaultConfiguration: false),
                identity: saved, in: &pane
            )
        }
        let plugin = replacement == "process" ? "codex" : "claude-code"
        var state = PaneState(paneId: pane.runtimeID, sessionName: session.name, tmuxWindowId: window.runtimeID, currentPath: pane.directory, agentSession: .init(paneId: pane.runtimeID, pluginID: plugin))
        state.workspaceIdentity = workspace
        if replacement == "shell" {
            var shell = state
            shell.agentSession = nil
            #expect(WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: shell, detected: nil, scanAvailable: true, runtimeID: { _ in nil }))
        } else {
            let detected = TmuxService.DetectedAgentPane(path: pane.directory, pluginID: plugin, processIDs: ["new-pid"])
            #expect(WorkspaceAgentCapture.invalidateChangedAgent(&pane, state: state, detected: detected, scanAvailable: true, runtimeID: { _ in nil }))
        }
        #expect(AgentForkSource(pane: state) == nil)
        WorkspaceAgentCapture.recordFailure("The new conversation ID is not verified yet.", in: &pane)
        snapshot.sessions[0].windows[0].panes[0] = pane
        snapshot.recovery = .init(bootID: "new-boot", pendingAgentPaneIDs: [pane.id])
        let recoveryDirectory = directory.appendingPathComponent("Recovery")
        _ = try await WorkspaceRecoveryStore.diskBacked(directory: recoveryDirectory).save(snapshot)
        let store = WorkspaceRecoveryStore.diskBacked(directory: recoveryDirectory)
        let reloaded = try #require(try await store.load())
        let identities = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
        // The old cache and history deliberately remain readable. The snapshot veto is authoritative.
        #expect(try await identities.recoverySource([session.id], window.id, pane.id) == saved.source)
        var lookups = 0
        var shellLaunches = 0
        let recovery = WorkspaceAgentRecovery(
            core: { _ in Issue.record("A revoked identity must not reach the Agent plugin")
                return nil
            },
            mode: { .layoutAndAgents }, refresh: { }, version: { _ in nil }, directoryExists: { _ in true },
            inspect: { _ in .init(identity: workspace.paneID, isDead: true, isPlaceholder: true) },
            recoverySource: { sessions, window, pane in
                lookups += 1
                return try await identities.recoverySource(sessions, window, pane)
            },
            launch: { _, _, record, command in
                #expect(command == nil && record.kind == .shell)
                shellLaunches += 1
            }
        )
        let result = WorkspaceTmuxRestoreResult(state: .init(serverID: "new-server", sessions: reloaded.sessions), failures: [], createdPaneIDs: [])
        for intent in [WorkspaceAgentRecoveryIntent.automatic, .reconcile, .resume(pane.id)] {
            let (updated, failures) = try await recovery.recover(reloaded, result: result, intent: intent, save: store.save)
            let failure = try #require(failures.first)
            #expect(failure.reason.contains("no longer associated"))
            #expect(!failure.canResume && failure.canUseShell)
            #expect(updated == reloaded && lookups == 0 && shellLaunches == 0)
        }
        let (kept, failures) = try await recovery.recover(reloaded, result: result, intent: .useShell(pane.id), save: store.save)
        #expect(failures.isEmpty && shellLaunches == 1)
        #expect(kept.sessions[0].windows[0].panes[0].savedAgentIdentityInvalidated == true)
    }

    @MainActor
    @Test("Old snapshots use real native history verification before offering manual Resume", arguments: ["codex", "claude-code"], ["present", "missing", "ambiguous"])
    func nativeHistory(plugin: String, historyState: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-native-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var snapshot = WorkspaceRecoveryStoreTests.snapshot()
        let session = snapshot.sessions[0], window = session.windows[0], pane = window.panes[0]
        let conversation = UUID().uuidString.lowercased()
        var oldPane = PaneState(paneId: "%old", sessionName: "before-rename", tmuxWindowId: "@old", currentPath: pane.directory, agentSession: .init(paneId: "%old", pluginID: plugin), claudeSessionID: conversation)
        oldPane.workspaceIdentity = .init(serverID: "old-server", sessionID: session.id, windowID: window.id, paneID: pane.id)
        let saved = try AgentSessionIdentity(source: #require(AgentForkSource(pane: oldPane)), processID: "old-pid", runtimeID: "old-process")
        #expect(await AgentSessionIdentityClient.diskBacked(stateRoot: directory).save(saved))
        snapshot.sessions[0].windows[0].panes[0].unavailableAgentReason = "CLI was removed before capture"
        snapshot.recovery = .init(bootID: "new-boot", pendingAgentPaneIDs: [pane.id])
        let store = WorkspaceRecoveryStore.diskBacked(directory: directory.appendingPathComponent("Recovery"))
        snapshot = try await store.save(snapshot)
        let roots = [directory.appendingPathComponent("account-a"), directory.appendingPathComponent("account-b")]
        let relative = plugin == "codex" ? "sessions/2026/11/rollout-date-\(conversation).jsonl" : "projects/-tmp/\(conversation).jsonl"
        let count = historyState == "missing" ? 0 : (historyState == "ambiguous" ? 2 : 1)
        for root in roots.prefix(count) {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let history = AgentForkHistoryClient.liveValue
        try await withDependencies {
            // Keep all history/executable I/O inside the fixture.
            $0[AgentForkHistoryClient.self].root = { id, _, layout in try await history.root(id, roots.map(\.path), layout) }
            $0[AgentResumeExecutableClient.self].resolve = { _, _ in "/fixture/agent" }
        } operation: {
            let core: any AgentSessionResuming = plugin == "codex" ? CodexPluginCore() : ClaudeCodePluginCore()
            let identities = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
            var launches: [AgentForkLaunch] = []
            let recovery = WorkspaceAgentRecovery(
                core: { _ in core }, mode: { .layoutAndAgents }, refresh: { }, version: { _ in "verified" }, directoryExists: { _ in true },
                inspect: { _ in .init(identity: pane.id, isDead: true, isPlaceholder: true) }, recoverySource: identities.recoverySource,
                launch: { _, _, record, command in
                    let persisted = try #require(try await WorkspaceRecoveryStore.diskBacked(directory: directory.appendingPathComponent("Recovery")).load())
                    #expect(persisted.recovery?.agentLaunches[pane.id] == record)
                    #expect(persisted.sessions[0].windows[0].panes[0].agent?.sessionID == conversation)
                    try launches.append(#require(command))
                }
            )
            let result = WorkspaceTmuxRestoreResult(state: .init(serverID: "new-server", sessions: snapshot.sessions), failures: [], createdPaneIDs: [])
            let (updated, failures) = try await recovery.recover(snapshot, result: result, intent: .automatic, save: store.save)
            #expect(launches.isEmpty)
            let failure = try #require(failures.first)
            #expect(failure.canResume == (historyState == "present"))
            guard historyState == "present" else {
                #expect(updated.sessions[0].windows[0].panes[0].agent == nil)
                #expect(failure.reason.contains(historyState == "missing" ? "unavailable" : "multiple"))
                return
            }
            let descriptor = try #require(updated.sessions[0].windows[0].panes[0].agent)
            #expect(descriptor.configurationRoot == roots[0].resolvingSymlinksInPath().path)
            #expect(descriptor.executable == nil && descriptor.providerID == nil && descriptor.arguments.isEmpty)
            _ = try await recovery.recover(updated, result: result, intent: .resume(pane.id), save: store.save)
            let command = try #require(launches.first?.command)
            #expect(command.args.starts(with: [plugin == "codex" ? "resume" : "--resume", conversation]))
            #expect(command.env[plugin == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] == descriptor.configurationRoot)
        }
    }
}
