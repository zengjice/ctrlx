import ClaudeCodePluginCore
import CodexPluginCore
import ConcurrencyExtras
import CtrlxCommon
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
            runtime.setValue("replacement")
            #expect(manager.reconcileDetectedAgentSessions(detected))
            #expect(manager.paneStates["%1"]?.agentSession?.processRuntimeID == "replacement")
            runtime.setValue(nil)
            #expect(!manager.reconcileDetectedAgentSessions(detected))
            #expect(manager.paneStates["%1"]?.agentSession?.processRuntimeID == "replacement")
            #expect(manager.paneStates["%1"]?.agentSession?.isWorking == true)
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

    @Test("Both native plugins preserve conversation and config; a retry does not stop the replacement", arguments: ["codex", "claude-code"])
    func sameConversation(plugin: String) async throws {
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
            let request = RestartAgentSession(source: proof.source, runtimeID: proof.runtimeID)
            try await service.restart(request)
            try await service.restart(request)
            #expect(commands.count == 1 && captures == 2)
            let command = try #require(commands.first).command
            #expect(command.command == "/original/agent" && command.args.contains(proof.source.sessionID))
            #expect(command.args.contains("fixture-model") && !command.args.contains("--last") && !command.args.contains("--fork-session"))
            #expect(command.env[plugin == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] == "/private/config")
            if plugin == "codex" {
                #expect(command.args.prefix(4) == ["resume", proof.source.sessionID, "-C", proof.source.workingDirectory])
                #expect(command.args.contains("--no-daemon"))
            } else {
                #expect(command.args.prefix(2) == ["--resume", proof.source.sessionID])
            }
        }
    }

    @Test("History, invocation and process failures are rejected before exit", arguments: ["history", "invocation", "process", "identity", "stale-request"])
    func preflightFailure(failure: String) async throws {
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
            await #expect(throws: AgentRestartError.self) { try await service.restart(.init(source: proof.source, runtimeID: proof.runtimeID)) }
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
