import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentRestartServiceTests {
    @Test("Only verified process tokens replace the session's last known owner")
    func publishesProcessIncarnation() async throws {
        let runtime = LockIsolated<String?>("first")
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[LoginItemService.self] = .previewValue
            $0[AgentSessionIdentityClient.self].runtimeID = { _ in runtime.value }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
            let manager = MirrorWindowManager(
                settings: AppSettings(),
                tmuxService: tmux,
                paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                editorSessionManager: EditorSessionManager()
            )
            manager.updatePaneStates(from: [.init(paneId: "%1", target: "work:0.0", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", paneIndex: 0, command: "codex", currentPath: "/repo", width: 80, height: 24, isActive: true)])
            manager.applyState(pluginID: "codex", sessionID: UUID().uuidString, state: .working, tmuxPane: "%1", projectPath: "/repo")
            let detected: [String: TmuxService.DetectedAgentPane] = ["%1": .init(path: "/repo", pluginID: "codex", processIDs: ["123"])]
            #expect(manager.reconcileDetectedAgentSessions(detected))
            #expect(manager.paneStates["%1"]?.agentSession?.processRuntimeID == "first")
            #expect(manager.paneStates["%1"]?.agentSession?.isWorking == true)
            runtime.setValue("replacement")
            #expect(manager.reconcileDetectedAgentSessions(detected))
            #expect(manager.paneStates["%1"]?.agentSession?.processRuntimeID == "replacement")
            runtime.setValue(nil)
            #expect(!manager.reconcileDetectedAgentSessions(detected))
            #expect(manager.paneStates["%1"]?.agentSession?.processRuntimeID == "replacement")
            // A verified successor keeps its identity through a scan miss,
            // but does not inherit the previous process's working state.
            #expect(manager.paneStates["%1"]?.agentSession?.isWorking == false)
        }
    }

    private func proof(plugin: String) throws -> AgentSessionIdentity {
        let source = try #require(AgentForkSource(pane: .init(
            paneId: "%1", sessionName: "work", tmuxWindowId: "@1", currentPath: "/project with spaces",
            agentSession: .init(paneId: "%1", pluginID: plugin), claudeSessionID: UUID().uuidString,
            workspaceIdentity: .init(serverID: "12:34", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        )))
        return .init(source: source, processID: "123", runtimeID: "original")
    }

    @Test("Restart refreshes a verified conversation switch and distinguishes an unavailable writer", arguments: [false, true], [false, true])
    func liveConversationVerification(switched: Bool, hookOwned: Bool) async throws {
        let old = try proof(plugin: "codex")
        let workspace = try #require(old.source.workspaceIdentity)
        let changedID = UUID().uuidString
        let writer = LockIsolated<String?>(switched ? changedID : nil)
        let stored = LockIsolated<AgentSessionIdentity?>(old)
        let signals = LockIsolated(0)
        let separator = String(PaneInfo.fieldSeparator)
        let paneRow = [
            "%1",
            "work",
            "0",
            "0",
            "codex",
            old.source.workingDirectory,
            "80",
            "24",
            "1",
            "",
            "",
            "",
            "1",
            "",
            "",
            "",
            "@1",
            workspace.serverID,
            workspace.sessionID.uuidString,
            workspace.windowID.uuidString,
            workspace.paneID.uuidString,
            "$1",
        ].joined(separator: separator)
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[LoginItemService.self] = .previewValue
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[AgentSessionIdentityClient.self].runtimeID = { $0 == old.processID ? old.runtimeID : nil }
            $0[AgentSessionIdentityClient.self].load = { _ in stored.value }
            $0[AgentSessionIdentityClient.self].save = { stored.setValue($0)
                return true
            }
            $0[AgentSessionIdentityClient.self].invalidate = { _ in stored.setValue(nil) }
            $0[AgentSessionIdentityClient.self].codexSessionID = { _, _ in writer.value }
            $0[AgentRestartProcessClient.self].terminate = { _, _ in signals.withValue { $0 += 1 } }
            $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                let output: String
                if executable == "/bin/ps" {
                    output = "100 1 zsh\n123 100 codex"
                } else if arguments.last?.contains("#{pane_pid}") == true {
                    output = ["%1", "100", old.source.workingDirectory].joined(separator: separator)
                } else if arguments.contains("list-panes") || arguments.contains("display-message") {
                    output = paneRow
                } else if arguments.contains("list-clients") {
                    output = ""
                } else {
                    throw AgentRestartError("Unexpected process request")
                }
                return .init(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
            }
        } operation: {
            let settings = AppSettings()
            settings.tmuxPath = "/bin/sh"
            let coordinator = AppCoordinator(settings: settings)
            coordinator.pluginRegistry = PluginRegistry()
            let manager = coordinator.windowManager
            manager.updatePaneStates(from: await coordinator.tmuxService.refreshPanes())
            await coordinator.refreshAgentCommandIdentity()
            if hookOwned {
                manager.applyState(pluginID: "codex", sessionID: old.source.sessionID, state: .working, tmuxPane: "%1", projectPath: old.source.workingDirectory)
            }
            var published: [String] = []
            manager.onAgentProcessReconciliationChanged = { [weak manager] in
                if let id = manager?.paneStates["%1"]?.claudeSessionID {
                    published.append(id)
                }
            }
            let error = await #expect(throws: AgentRestartError.self) {
                try await coordinator.restartAgentSession(.init(source: old.source, runtimeID: old.runtimeID))
            }
            #expect(error?.message.hasPrefix(switched ? "The active conversation changed." : "Could not verify the active conversation.") == true)
            let expected = switched ? changedID : old.source.sessionID
            let pane = try #require(manager.paneStates["%1"])
            #expect(pane.claudeSessionID == expected)
            #expect(pane.agentSession?.state == (hookOwned && !switched ? .working : .idle))
            #expect(stored.value?.source.sessionID == expected)
            #expect(published == (switched ? [changedID] : []))
            // A fresh request for the verified identity reaches command preparation.
            // The fixture has no enabled plugin, so it cannot start a restart.
            writer.setValue(expected)
            let source = try #require(AgentForkSource(pane: pane))
            let retry = await #expect(throws: AgentRestartError.self) {
                try await coordinator.restartAgentSession(.init(source: source, runtimeID: old.runtimeID))
            }
            #expect(retry?.message == "This Agent does not support Resume.")
            #expect(signals.value == 0)
        }
    }

    @Test("Both native plugins preserve conversation and config; a retry does not stop the replacement", arguments: ["codex", "claude-code"], [false, true])
    func sameConversation(plugin: String, logout: Bool) async throws {
        let proof = try proof(plugin: plugin)
        let core: any AgentSessionResuming = plugin == "codex" ? CodexPluginCore() : ClaudeCodePluginCore()
        var commands: [AgentForkLaunch] = []
        var captures = 0
        try await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
            $0[WorkspaceAgentProcessClient.self].invocation = { _, _ in
                .init(executable: "/original/agent", arguments: ["--model", "fixture-model"], configurationRoots: ["CODEX_HOME": "/private/config", "CLAUDE_CONFIG_DIR": "/private/config"])
            }
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in try #require(roots.first) }
            $0[AgentResumeExecutableClient.self].resolve = { recorded, _ in try #require(recorded) }
        } operation: {
            let service = AgentRestartService(capture: { request, _ in
                #expect(request.matches(proof.source, runtimeID: proof.runtimeID))
                captures += 1
                return proof
            }, core: { _ in core }, resume: { identity, command in
                #expect(identity == proof)
                commands.append(command)
            })
            let request = RestartAgentSession(source: proof.source, runtimeID: proof.runtimeID, logoutBeforeResume: logout)
            try await service.restart(request)
            try await service.restart(request)
            await #expect(throws: AgentRestartError.self) {
                try await service.restart(.init(requestID: request.requestID, source: proof.source, runtimeID: proof.runtimeID, logoutBeforeResume: !logout))
            }
            #expect(commands.count == 1 && captures == 2)
            let command = try #require(commands.first).command
            #expect(command.env[plugin == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] == "/private/config")
            if logout {
                #expect(command.command == "/bin/sh")
                let script = try #require(command.args.last)
                #expect(script.hasPrefix(plugin == "codex" ? "if '/original/agent' 'logout';" : "if '/original/agent' 'auth' 'logout';"))
                #expect(script.contains(plugin == "codex" ? "exec '/original/agent' 'resume' '\(proof.source.sessionID)'" : "exec '/original/agent' '--resume' '\(proof.source.sessionID)'"))
                #expect(script.contains("'--model' 'fixture-model'"))
                #expect(!script.contains("'login'"))
                return
            }
            #expect(command.command == "/original/agent" && command.args.contains(proof.source.sessionID))
            #expect(command.args.contains("fixture-model") && !command.args.contains("--last") && !command.args.contains("--fork-session"))
            if plugin == "codex" {
                #expect(command.args.prefix(4) == ["resume", proof.source.sessionID, "-C", proof.source.workingDirectory])
                #expect(command.args.contains("--no-daemon"))
            } else {
                #expect(command.args.prefix(2) == ["--resume", proof.source.sessionID])
            }
        }
    }

    @Test("History, invocation and process failures are rejected before exit", arguments: ["history", "invocation", "process", "identity", "stale-request"], [false, true])
    func preflightFailure(failure: String, logout: Bool) async throws {
        let proof = try proof(plugin: "codex")
        var captures = 0
        var stopped = false
        try await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
            $0[WorkspaceAgentProcessClient.self].invocation = { _, _ in
                if failure == "invocation" {
                    throw AgentRestartError("Unavailable startup config")
                }
                return .init(executable: "/original/agent", arguments: [])
            }
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in
                if failure == "history" {
                    throw AgentRestartError("Unavailable history")
                }
                return try #require(roots.first)
            }
            $0[AgentResumeExecutableClient.self].resolve = { _, _ in "/original/agent" }
        } operation: {
            let service = AgentRestartService(capture: { _, _ in
                captures += 1
                if failure == "identity" {
                    throw AgentRestartError("Unverified conversation")
                }
                return (captures == 2 && failure == "process") || failure == "stale-request" ? .init(source: proof.source, processID: "456", runtimeID: "replacement") : proof
            }, core: { _ in CodexPluginCore() }, resume: { _, _ in stopped = true })
            await #expect(throws: AgentRestartError.self) { try await service.restart(.init(source: proof.source, runtimeID: proof.runtimeID, logoutBeforeResume: logout)) }
            #expect(!stopped)
        }
    }

    @Test("Logging out an API Provider is rejected before stopping its Agent", arguments: ["codex", "claude-code"])
    func apiProvider(plugin: String) async throws {
        let proof = try proof(plugin: plugin)
        let core: any AgentSessionResuming = plugin == "codex" ? CodexPluginCore() : ClaudeCodePluginCore()
        var stopped = false
        try await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
            $0[WorkspaceAgentProcessClient.self].invocation = { _, _ in
                .init(executable: "/agent", arguments: [], providerID: "custom-api")
            }
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in try #require(roots.first) }
        } operation: {
            let service = AgentRestartService(capture: { _, _ in proof }, core: { _ in core }, resume: { _, _ in stopped = true })
            let error = await #expect(throws: AgentProviderError.self) {
                try await service.restart(.init(source: proof.source, runtimeID: proof.runtimeID, logoutBeforeResume: true))
            }
            #expect(error?.localizedDescription.contains("Do not log out.") == true)
            #expect(!stopped)
        }
    }

    @Test("Concurrent clients cannot independently restart the same Agent")
    func concurrentRequests() async throws {
        let proof = try proof(plugin: "codex")
        let entered = AsyncStream<Void>.makeStream(), released = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish()
            released.continuation.finish()
        }
        try await withDependencies {
            $0[SessionDirectoryClient.self].resolve = { $0 }
            $0[WorkspaceAgentProcessClient.self].invocation = { _, _ in .init(executable: "/agent", arguments: []) }
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in try #require(roots.first) }
            $0[AgentResumeExecutableClient.self].resolve = { _, _ in "/agent" }
        } operation: {
            var count = 0
            let service = AgentRestartService(capture: { _, _ in proof }, core: { _ in CodexPluginCore() }, resume: { _, _ in
                count += 1
                entered.continuation.yield(())
                var iterator = released.stream.makeAsyncIterator()
                _ = await iterator.next()
            })
            let request = RestartAgentSession(source: proof.source, runtimeID: proof.runtimeID)
            let first = Task { try await service.restart(request) }
            var iterator = entered.stream.makeAsyncIterator()
            _ = await iterator.next()
            await #expect(throws: AgentRestartError.self) { try await service.restart(.init(source: proof.source, runtimeID: proof.runtimeID)) }
            let duplicate = Task { try await service.restart(request) }
            released.continuation.yield(())
            try await first.value
            try await duplicate.value
            #expect(count == 1)
        }
    }
}
