import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentSessionIdentityTests {
    private func manager(windowID: String = "@7") -> MirrorWindowManager {
        let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
        let manager = MirrorWindowManager(
            settings: AppSettings(), tmuxService: tmux,
            paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
            editorSessionManager: EditorSessionManager()
        )
        manager.updatePaneStates(from: [.init(
            paneId: "%5", target: "work:0.0", sessionName: "work", windowIndex: 0, tmuxWindowId: windowID,
            paneIndex: 0, command: "zsh", currentPath: "/repo", width: 80, height: 24, isActive: true
        )])
        return manager
    }

    private func runner(_ rows: LockIsolated<String>) -> ProcessRunner {
        var runner = ProcessRunner.previewValue
        runner.run = { executable, arguments, _, _ in
            let output: String
            if executable == "/bin/ps" { output = rows.value }
            else if arguments.contains("list-panes") { output = "%5\(PaneInfo.fieldSeparator)100\(PaneInfo.fieldSeparator)/repo\n" }
            else { throw AgentForkError("Unexpected process request") }
            return .init(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        }
        return runner
    }

    private func defaults(_ values: inout DependencyValues, rows: LockIsolated<String>, client: AgentSessionIdentityClient) {
        values[PreferencesService.self] = .inMemory()
        values[LoginItemService.self] = .previewValue
        values[ProcessRunner.self] = runner(rows)
        values[AgentSessionIdentityClient.self] = client
    }

    @Test("Restart restores the native UUID of the same Codex/Claude process without replaying status or notifications", arguments: ["codex", "claude-code"])
    func restart(pluginID: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-native-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = pluginID == "codex" ? "codex" : "claude"
        let names = [pluginID: [command]]
        let rows = LockIsolated("100 1 zsh\n101 100 \(command)\n")
        let sessionID = UUID().uuidString
        let runtime = LockIsolated("101:start-1")
        var client = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
        client.runtimeID = { $0 == "101" ? runtime.value : nil }
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let original = manager()
            original.applyState(pluginID: pluginID, sessionID: sessionID, state: .working, tmuxPane: "%5", projectPath: "/repo")
            await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: names)
        }
        // A new disk reader rules out restoration from the old manager/store's memory.
        var reloaded = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
        reloaded.runtimeID = client.runtimeID
        try await withDependencies {
            defaults(&$0, rows: rows, client: reloaded)
        } operation: {
            let restarted = manager()
            var pushes = 0
            restarted.onAgentProcessReconciliationChanged = { pushes += 1 }
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
            let pane = try #require(restarted.paneStates["%5"])
            #expect(AgentForkSource(pane: pane)?.sessionID == sessionID)
            #expect(pane.agentSession?.state == .idle)
            #expect(pane.agentSession?.needsAttention == false)
            #expect(pane.telemetry == nil && pane.recap == nil)
            #expect(pushes == 1)
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
            #expect(pushes == 1)
            runtime.setValue("101:start-2")
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
            #expect(restarted.paneStates["%5"]?.claudeSessionID == nil)
            rows.setValue("100 1 zsh\n202 100 \(command)\n")
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
            #expect(restarted.paneStates["%5"]?.claudeSessionID == nil)
        }
    }

    @Test("A cached UUID cannot be reused for a different runtime, Agent, window, or ambiguous pane",
          arguments: ["reused-pid", "missing-process", "new-pid", "multiple", "other-agent", "other-window", "invalid-id"])
    func rejectsStaleIdentity(scenario: String) async throws {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        let pane = PaneState(paneId: "%5", sessionName: "work", tmuxWindowId: "@7", currentPath: "/repo",
                             agentSession: .init(paneId: "%5", pluginID: "codex"), claudeSessionID: UUID().uuidString)
        let valid = AgentSessionIdentity(source: try #require(AgentForkSource(pane: pane)), processID: "101", runtimeID: "101:start-1")
        let data = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        let identity = try JSONDecoder().decode(AgentSessionIdentity.self, from: Data((scenario == "invalid-id"
            ? data.replacingOccurrences(of: valid.source.sessionID, with: "--last") : data).utf8))
        let client = AgentSessionIdentityClient(load: { _ in identity }, save: { _ in false }, runtimeID: {
            if scenario == "missing-process" { return nil }
            return $0 == "101" ? (scenario == "reused-pid" ? "101:start-2" : "101:start-1") : "202:start-1"
        })
        if scenario == "new-pid" { rows.setValue("100 1 zsh\n202 100 codex\n") }
        if scenario == "multiple" { rows.setValue("100 1 zsh\n101 100 codex\n202 101 codex\n") }
        if scenario == "other-agent" { rows.setValue("100 1 zsh\n101 100 claude\n") }
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let restarted = manager(windowID: scenario == "other-window" ? "@9" : "@7")
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["codex"], "claude-code": ["claude"]], refreshSnapshot: true)
            #expect(restarted.paneStates["%5"]?.claudeSessionID == nil)
            #expect(restarted.paneStates["%5"].flatMap(AgentForkSource.init(pane:)) == nil)
        }
    }

    @Test("Missing or corrupt identity caches fail closed and can be replaced by fresh native events", arguments: [false, true])
    func unavailableCache(corrupt: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-native-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        if corrupt {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{incomplete".utf8).write(to: directory.appendingPathComponent("agent-session-identities.json"))
        }
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        var client = AgentSessionIdentityClient.diskBacked(stateRoot: directory)
        client.runtimeID = { _ in "101:start-1" }
        let sessionID = UUID().uuidString
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let restarted = manager()
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["codex"]], refreshSnapshot: true)
            #expect(restarted.paneStates["%5"]?.claudeSessionID == nil)
            restarted.applyState(pluginID: "codex", sessionID: sessionID, state: .working, tmuxPane: "%5", projectPath: "/repo")
            await restarted.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: ["codex": ["codex"]])
            #expect(await client.load("%5")?.source.sessionID == sessionID)
        }
    }

    @Test("A native event arriving during cache loading takes precedence over recovered identity")
    func hookDuringRecovery() async throws {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        let pane = PaneState(paneId: "%5", sessionName: "work", tmuxWindowId: "@7", currentPath: "/repo",
                             agentSession: .init(paneId: "%5", pluginID: "codex"), claudeSessionID: UUID().uuidString)
        let identity = AgentSessionIdentity(source: try #require(AgentForkSource(pane: pane)), processID: "101", runtimeID: "101:start-1")
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        let client = AgentSessionIdentityClient(load: { _ in
            start.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
            return identity
        }, save: { _ in false }, runtimeID: { _ in "101:start-1" })
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let restarted = manager()
            let refresh = Task { await restarted.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["codex"]], refreshSnapshot: true) }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            let newID = UUID().uuidString
            restarted.applyState(pluginID: "codex", sessionID: newID, state: .working, tmuxPane: "%5", projectPath: "/repo")
            resume.yield(())
            await refresh.value
            #expect(restarted.paneStates["%5"]?.claudeSessionID == newID)
            #expect(restarted.paneStates["%5"]?.agentSession?.state == .working)
        }
        start.finish()
        resume.finish()
    }

    @Test("A failed identity write can be retried; successful repeated hooks do not rescan the process tree")
    func writeRetry() async {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        let writes = LockIsolated(0)
        let client = AgentSessionIdentityClient(load: { _ in nil }, save: { _ in
            writes.withValue { $0 += 1 }
            return writes.value > 1
        }, runtimeID: { _ in "101:start-1" })
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let original = manager()
            original.applyState(pluginID: "codex", sessionID: UUID().uuidString, state: .idle, tmuxPane: "%5", projectPath: "/repo")
            for _ in 0..<3 {
                await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: ["codex": ["codex"]])
            }
            #expect(writes.value == 2)
        }
    }

    @Test("Conversation-switch writes are serialized so a delayed old UUID cannot replace the new one")
    func switchDuringWrite() async throws {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        let stored = LockIsolated<AgentSessionIdentity?>(nil)
        let (started, start) = AsyncStream<String>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        let oldID = UUID().uuidString
        let newID = UUID().uuidString
        let client = AgentSessionIdentityClient(load: { _ in nil }, save: { identity in
            if identity.source.sessionID == oldID {
                start.yield(oldID)
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
            }
            stored.setValue(identity)
            return true
        }, runtimeID: { _ in "101:start-1" })
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let original = manager()
            original.applyState(pluginID: "codex", sessionID: oldID, state: .idle, tmuxPane: "%5", projectPath: "/repo")
            let first = Task { await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: ["codex": ["codex"]]) }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            original.applyState(pluginID: "codex", sessionID: newID, state: .working, tmuxPane: "%5", projectPath: "/repo")
            let second = Task { await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: ["codex": ["codex"]]) }
            resume.yield(())
            await first.value
            await second.value
            #expect(stored.value?.source.sessionID == newID)
        }
        start.finish()
        resume.finish()
    }
}
