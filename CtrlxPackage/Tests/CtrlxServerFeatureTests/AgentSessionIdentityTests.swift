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

    @Test("An idle fork's verified writer ID enables Fork, persists once and avoids further FD probes")
    func recoverIdleCodexFork() async throws {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n201 101 codex\n")
        let stored = LockIsolated<AgentSessionIdentity?>(nil)
        let probes = LockIsolated(0)
        let writes = LockIsolated(0)
        let id = UUID().uuidString
        let client = AgentSessionIdentityClient(load: { _ in stored.value }, save: {
            stored.setValue($0)
            writes.withValue { $0 += 1 }
            return true
        }, runtimeID: { "\($0):start-1" }, codexSessionID: { pid, runtime in
            #expect(pid == "101" && runtime == "101:start-1")
            probes.withValue { $0 += 1 }
            return id
        })
        try await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let recovered = manager()
            var pushes = 0
            recovered.onAgentProcessReconciliationChanged = { pushes += 1 }
            for _ in 0..<3 {
                await recovered.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["codex"]], refreshSnapshot: true)
            }
            let pane = try #require(recovered.paneStates["%5"])
            #expect(AgentForkSource(pane: pane)?.sessionID == id)
            #expect(pane.agentSession?.state == .idle && pane.agentSession?.needsAttention == false)
            #expect(pane.telemetry == nil && pane.recap == nil)
            #expect(stored.value?.source.sessionID == id && stored.value?.processID == "101")
            #expect(probes.value == 1 && writes.value == 1 && pushes == 1)
        }
    }

    @Test("Writer discovery is limited to one verified Codex runtime", arguments: ["claude", "multiple", "missing-runtime", "invalid-id", "no-writer"])
    func writerRecoveryScope(scenario: String) async {
        let command = scenario == "claude" ? "claude" : "codex"
        let plugin = scenario == "claude" ? "claude-code" : "codex"
        let rows = LockIsolated("100 1 zsh\n101 100 \(command)\n" + (scenario == "multiple" ? "102 100 codex\n" : ""))
        let probes = LockIsolated(0)
        let writes = LockIsolated(0)
        let client = AgentSessionIdentityClient(load: { _ in nil }, save: { _ in
            writes.withValue { $0 += 1 }
            return true
        }, runtimeID: { scenario == "missing-runtime" ? nil : "\($0):start-1" }, codexSessionID: { _, _ in
            probes.withValue { $0 += 1 }
            return scenario == "invalid-id" ? "--last" : nil
        })
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let recovered = manager()
            await recovered.refreshDetectedAgentSessions(processNamesByPlugin: [plugin: [command]], refreshSnapshot: true)
            #expect(recovered.paneStates["%5"]?.claudeSessionID == nil)
            #expect(writes.value == 0)
            #expect(probes.value == (["invalid-id", "no-writer"].contains(scenario) ? 1 : 0))
        }
    }

    @Test("Native events, process replacement and cancellation invalidate an in-flight writer lookup",
          arguments: ["hook", "runtime", "process", "cancel"])
    func writerRecoveryRace(scenario: String) async {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        let runtime = LockIsolated("101:start-1")
        let writes = LockIsolated(0)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { start.finish(); resume.finish() }
        let client = AgentSessionIdentityClient(load: { _ in nil }, save: { _ in
            writes.withValue { $0 += 1 }
            return true
        }, runtimeID: { _ in runtime.value }, codexSessionID: { _, _ in
            start.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
            return UUID().uuidString
        })
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let recovered = manager()
            let refresh = Task { await recovered.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["codex"]], refreshSnapshot: true) }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            let freshID = UUID().uuidString
            switch scenario {
            case "hook": recovered.applyState(pluginID: "codex", sessionID: freshID, state: .working, tmuxPane: "%5", projectPath: "/repo")
            case "runtime": runtime.setValue("101:start-2")
            case "process": recovered.reconcileDetectedAgentSessions([:])
            default: refresh.cancel()
            }
            resume.yield(())
            await refresh.value
            #expect(recovered.paneStates["%5"]?.claudeSessionID == (scenario == "hook" ? freshID : nil))
            #expect(writes.value == 0)
        }
    }

    @Test("A native hook's write wins over an already-saving recovered fork identity")
    func hookDuringWriterSave() async {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        let stored = LockIsolated<AgentSessionIdentity?>(nil)
        let oldID = UUID().uuidString
        let newID = UUID().uuidString
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { start.finish(); resume.finish() }
        let client = AgentSessionIdentityClient(load: { _ in stored.value }, save: { identity in
            if identity.source.sessionID == oldID {
                start.yield(())
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
            }
            stored.setValue(identity)
            return true
        }, runtimeID: { "\($0):start-1" }, codexSessionID: { _, _ in oldID })
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let recovered = manager()
            let refresh = Task { await recovered.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["codex"]], refreshSnapshot: true) }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            recovered.applyState(pluginID: "codex", sessionID: newID, state: .working, tmuxPane: "%5", projectPath: "/repo")
            let hookWrite = Task { await recovered.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: ["codex": ["codex"]]) }
            resume.yield(())
            await refresh.value
            await hookWrite.value
            #expect(recovered.paneStates["%5"]?.claudeSessionID == newID)
            #expect(stored.value?.source.sessionID == newID)
        }
    }

    @Test("Restart restores the main Codex/Claude UUID despite helper churn, without replaying status or notifications", arguments: ["codex", "claude-code"])
    func restart(pluginID: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-native-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = pluginID == "codex" ? "codex" : "claude"
        let names = [pluginID: [command]]
        let mainRows = "100 1 zsh\n101 100 \(command)\n"
        let rows = LockIsolated(mainRows + "201 101 node_repl\n202 201 \(command)\n")
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
            #expect(await client.load("%5")?.processID == "101")
        }
        rows.setValue(mainRows + "301 101 node_repl\n302 301 \(command)\n")
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
            rows.setValue(mainRows)
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
            #expect(restarted.paneStates["%5"]?.claudeSessionID == sessionID)
            #expect(pushes == 1)
            rows.setValue(mainRows + "401 101 zsh\n402 401 \(command)\n")
            await restarted.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
            #expect(restarted.paneStates["%5"]?.claudeSessionID == sessionID)
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
          arguments: ["reused-pid", "missing-process", "new-pid", "multiple", "helper-id", "other-agent", "other-window", "invalid-id"])
    func rejectsStaleIdentity(scenario: String) async throws {
        let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
        let pane = PaneState(paneId: "%5", sessionName: "work", tmuxWindowId: "@7", currentPath: "/repo",
                             agentSession: .init(paneId: "%5", pluginID: "codex"), claudeSessionID: UUID().uuidString)
        let pid = scenario == "helper-id" ? "202" : "101"
        let valid = AgentSessionIdentity(source: try #require(AgentForkSource(pane: pane)), processID: pid, runtimeID: "\(pid):start-1")
        let data = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        let identity = try JSONDecoder().decode(AgentSessionIdentity.self, from: Data((scenario == "invalid-id"
            ? data.replacingOccurrences(of: valid.source.sessionID, with: "--last") : data).utf8))
        let client = AgentSessionIdentityClient(load: { _ in identity }, save: { _ in false }, runtimeID: {
            if scenario == "missing-process" { return nil }
            return $0 == "101" ? (scenario == "reused-pid" ? "101:start-2" : "101:start-1") : "202:start-1"
        }, codexSessionID: { _, _ in nil })
        if scenario == "new-pid" { rows.setValue("100 1 zsh\n202 100 codex\n") }
        if scenario == "multiple" { rows.setValue("100 1 zsh\n101 100 codex\n202 100 codex\n") }
        if scenario == "helper-id" { rows.setValue("100 1 zsh\n101 100 codex\n201 101 node_repl\n202 201 codex\n") }
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

    @Test("Independent Agent processes cannot establish a cached Fork identity", arguments: ["codex", "claude-code"])
    func ambiguousWrite(pluginID: String) async {
        let command = pluginID == "codex" ? "codex" : "claude"
        let rows = LockIsolated("100 1 zsh\n101 100 \(command)\n202 100 \(command)\n")
        let writes = LockIsolated(0)
        let client = AgentSessionIdentityClient(load: { _ in nil }, save: { _ in
            writes.withValue { $0 += 1 }
            return true
        }, runtimeID: { "\($0):start-1" }, codexSessionID: { _, _ in nil })
        await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let original = manager()
            original.applyState(pluginID: pluginID, sessionID: UUID().uuidString, state: .idle, tmuxPane: "%5", projectPath: "/repo")
            await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: [pluginID: [command]])
            #expect(writes.value == 0)
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
        }, save: { _ in false }, runtimeID: { _ in "101:start-1" }, codexSessionID: { _, _ in nil })
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
        }, runtimeID: { _ in "101:start-1" }, codexSessionID: { _, _ in nil })
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

    @Test(
        "Resuming the same conversation in a replacement process refreshes its native identity",
        arguments: [false, true]
    )
    func resumedConversationReplacesRuntime(reusesPID: Bool) async throws {
        let rows = LockIsolated("100 1 zsh\n101 100 claude\n")
        let stored = LockIsolated<AgentSessionIdentity?>(nil)
        let runtimes = LockIsolated(["101": "101:start-1"])
        let client = AgentSessionIdentityClient(load: { _ in stored.value }, save: {
            stored.setValue($0)
            return true
        }, runtimeID: { runtimes.value[$0] }, codexSessionID: { _, _ in nil })
        try await withDependencies {
            defaults(&$0, rows: rows, client: client)
        } operation: {
            let original = manager()
            let sessionID = UUID().uuidString
            let names = ["claude-code": ["claude"]]
            original.applyState(
                pluginID: "claude-code",
                sessionID: sessionID,
                state: .idle,
                tmuxPane: "%5",
                projectPath: "/repo"
            )
            await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: names)
            let old = try #require(stored.value)

            // A process can exit without delivering SessionEnd. Its replacement
            // can resume the same native conversation before the next scan.
            let replacementPID = reusesPID ? "101" : "202"
            rows.setValue("100 1 zsh\n\(replacementPID) 100 claude\n")
            runtimes.setValue([replacementPID: "\(replacementPID):start-2"])
            original.applyState(
                pluginID: "claude-code",
                sessionID: sessionID,
                state: .idle,
                tmuxPane: "%5",
                projectPath: "/repo"
            )
            await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: names)

            let replacement = try #require(stored.value)
            #expect(replacement.source == old.source)
            #expect(replacement.processID == replacementPID)
            #expect(replacement.runtimeID == "\(replacementPID):start-2")
            #expect(replacement != old)
        }
    }

    @Test("A hook waiting for a failed identity write retries instead of losing its registration")
    func concurrentHookRetriesFailedWrite() async throws {
        try await withMainSerialExecutor {
            let rows = LockIsolated("100 1 zsh\n101 100 claude\n")
            let stored = LockIsolated<AgentSessionIdentity?>(nil)
            let writes = LockIsolated(0)
            let (started, start) = AsyncStream<Void>.makeStream()
            let (release, resume) = AsyncStream<Void>.makeStream()
            defer { start.finish()
                resume.finish()
            }
            let client = AgentSessionIdentityClient(load: { _ in stored.value }, save: { identity in
                if
                    writes.withValue({ $0 += 1
                        return $0 }) == 1 {
                    start.yield(())
                    var iterator = release.makeAsyncIterator()
                    _ = await iterator.next()
                    return false
                }
                stored.setValue(identity)
                return true
            }, runtimeID: { "\($0):start-1" }, codexSessionID: { _, _ in nil })
            try await withDependencies {
                defaults(&$0, rows: rows, client: client)
            } operation: {
                let original = manager()
                let sessionID = UUID().uuidString
                let names = ["claude-code": ["claude"]]
                original.applyState(
                    pluginID: "claude-code",
                    sessionID: sessionID,
                    state: .idle,
                    tmuxPane: "%5",
                    projectPath: "/repo"
                )
                let first = Task { await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: names) }
                var iterator = started.makeAsyncIterator()
                _ = await iterator.next()
                let second = Task { await original.rememberAgentSessionIdentity(forPane: "%5", processNamesByPlugin: names) }
                await Task.yield()
                #expect(writes.value == 1)
                resume.yield(())
                await first.value
                await second.value
                let identity = try #require(stored.value)
                #expect(identity.source.sessionID == sessionID)
                #expect(writes.value == 2)
            }
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
        }, runtimeID: { _ in "101:start-1" }, codexSessionID: { _, _ in nil })
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
