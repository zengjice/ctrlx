#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite
    struct AgentProcessReconciliationTests {
        private func makeWindowManager(tmuxService: TmuxService? = nil) -> MirrorWindowManager {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[ProcessRunner.self] = .previewValue
                $0[LoginItemService.self] = .previewValue
            } operation: {
                let tmux = tmuxService ?? TmuxService()
                let control = TmuxControlClientManager()
                let streams = PaneStreamManager(tmuxService: tmux, controlClientManager: control)
                let manager = MirrorWindowManager(
                    settings: AppSettings(),
                    tmuxService: tmux,
                    paneStreamManager: streams,
                    editorSessionManager: EditorSessionManager()
                )
                manager.updatePaneStates(from: [
                    PaneInfo(
                        paneId: "%5",
                        target: "work:0.0",
                        sessionName: "work",
                        windowIndex: 0,
                        paneIndex: 0,
                        command: "zsh",
                        currentPath: "/tmp",
                        width: 80,
                        height: 24,
                        isActive: true
                    ),
                ])
                return manager
            }
        }

        private func detected(
            pluginID: String = "codex",
            path: String = "/tmp/project",
            processIDs: Set<String> = ["101"]
        ) -> [String: TmuxService.DetectedAgentPane] {
            ["%5": .init(path: path, pluginID: pluginID, processIDs: processIDs)]
        }

        @Test("agent process reconciliation runs every ten seconds")
        func reconciliationInterval() {
            #expect(MirrorWindowManager.agentReconciliationInterval == .seconds(10))
        }

        @Test("Concurrent agent detection shares one process snapshot")
        func sharedProcessSnapshot() async {
            let calls = LockIsolated<[String: Int]>([:])
            await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable executable, arguments, _, _ in
                    if executable == "/bin/ps" {
                        calls.withValue { $0["ps", default: 0] += 1 }
                        return ProcessResult(
                            exitCode: 0,
                            stdout: Data("100 1 zsh\n101 100 codex\n".utf8),
                            stderr: Data()
                        )
                    }
                    if arguments.contains("list-panes") {
                        calls.withValue { $0["tmux", default: 0] += 1 }
                        try await Task.sleep(for: .milliseconds(10))
                        let separator = String(PaneInfo.fieldSeparator)
                        return ProcessResult(
                            exitCode: 0,
                            stdout: Data("%1\(separator)100\(separator)/tmp/project\n".utf8),
                            stderr: Data()
                        )
                    }
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("unexpected".utf8))
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                async let first = tmux.detectAgentPanes(processNamesByPlugin: ["codex": ["codex"]])
                async let second = tmux.detectAgentPanes(processNamesByPlugin: ["other": ["codex"]])
                let results = await (first, second)

                #expect(results.0["%1"]?.pluginID == "codex")
                #expect(results.0["%1"]?.processIDs == ["101"])
                #expect(results.1["%1"]?.pluginID == "other")
            }

            #expect(calls.value["tmux"] == 1)
            #expect(calls.value["ps"] == 1)
        }

        @Test("Agent detection ignores nested helpers but keeps independent peers",
              arguments: ["codex", "claude-code"], ["nested", "exec", "peers"])
        func outermostAgentProcesses(pluginID: String, shape: String) async throws {
            let command = pluginID == "codex" ? "codex" : "claude"
            let mainPID = shape == "exec" ? "100" : "101"
            var rows = shape == "exec" ? "100 1 \(command)\n" : "100 1 zsh\n101 100 \(command)\n"
            rows += "201 \(mainPID) node_repl\n202 201 /tools/\(command)\n303 202 \(command)\n"
            if shape == "peers" { rows += "501 100 zsh\n502 501 \(command)\n503 502 \(command)\n" }
            // Process listing order must not choose the nested process first.
            let output = rows.split(separator: "\n").reversed().joined(separator: "\n")
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                    let stdout: String
                    if executable == "/bin/ps" { stdout = output }
                    else if arguments.contains("list-panes") { stdout = "%5\(PaneInfo.fieldSeparator)100\(PaneInfo.fieldSeparator)/repo\n" }
                    else { throw AgentForkError("Unexpected process request") }
                    return .init(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                let panes = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: [pluginID: [command]])
                let detected = try #require(panes?["%5"])
                #expect(detected.pluginID == pluginID)
                #expect(detected.processIDs == (shape == "peers" ? [mainPID, "502"] : [mainPID]))
            }
        }

        @Test("process detection creates, updates, and removes its own session")
        func processOwnedSessionLifecycle() {
            let manager = makeWindowManager()

            #expect(manager.reconcileDetectedAgentSessions(detected()))
            #expect(manager.paneStates["%5"]?.agentSession?.pluginID == "codex")
            #expect(manager.paneStates["%5"]?.agentSession?.detectedProjectPath == "/tmp/project")
            #expect(manager.paneStates["%5"]?.agentSession?.state == .idle)

            #expect(!manager.reconcileDetectedAgentSessions(detected()))

            #expect(manager.reconcileDetectedAgentSessions(detected(path: "/tmp/renamed")))
            #expect(manager.paneStates["%5"]?.agentSession?.detectedProjectPath == "/tmp/renamed")

            #expect(manager.reconcileDetectedAgentSessions([:]))
            #expect(manager.paneStates["%5"]?.agentSession == nil)
            #expect(!manager.reconcileDetectedAgentSessions([:]))
        }

        @Test("plugin state takes ownership from process detection")
        func pluginStateTakesOwnership() {
            let manager = makeWindowManager()
            #expect(manager.reconcileDetectedAgentSessions(detected()))

            manager.applyState(
                pluginID: "claude-code",
                sessionID: "session-1",
                state: .working,
                tmuxPane: "%5",
                projectPath: "/tmp/hook-project"
            )

            #expect(!manager.reconcileDetectedAgentSessions([:]))
            #expect(manager.paneStates["%5"]?.agentSession?.pluginID == "claude-code")
            #expect(manager.paneStates["%5"]?.agentSession?.state == .working)
            #expect(manager.paneStates["%5"]?.agentSession?.detectedProjectPath == "/tmp/hook-project")
        }

        @Test("session end suppresses detection until the old process disappears")
        func endedSessionIsNotResurrected() {
            let manager = makeWindowManager()
            manager.reconcileDetectedAgentSessions(detected())
            manager.applyState(
                pluginID: "codex",
                sessionID: "session-1",
                state: .idle,
                tmuxPane: "%5",
                projectPath: "/tmp/project"
            )

            #expect(manager.endAgentSession(forPane: "%5"))
            #expect(!manager.reconcileDetectedAgentSessions(detected()))
            #expect(manager.paneStates["%5"]?.agentSession == nil)

            // One reliable absent snapshot proves the old process exited and
            // releases the tombstone. A later detection is a new agent process.
            #expect(!manager.reconcileDetectedAgentSessions([:]))
            #expect(manager.reconcileDetectedAgentSessions(detected()))
            #expect(manager.paneStates["%5"]?.agentSession != nil)
        }

        @Test("A new process in the same pane releases suppression without an absent scan",
              arguments: [Set(["202"]), Set(["101", "202"])])
        func quickResume(processIDs: Set<String>) {
            let manager = makeWindowManager()
            manager.reconcileDetectedAgentSessions(detected())
            #expect(manager.endAgentSession(forPane: "%5"))
            #expect(manager.paneStates["%5"]?.agentSession == nil)

            #expect(manager.reconcileDetectedAgentSessions(detected(processIDs: processIDs)))
            #expect(manager.paneStates["%5"]?.agentSession?.pluginID == "codex")
        }

        @Test("An end before the first process scan cannot suppress an unknown future process")
        func endWithoutObservedProcess() {
            let manager = makeWindowManager()
            manager.applyState(pluginID: "codex", sessionID: "old", state: .idle,
                               tmuxPane: "%5", projectPath: "/tmp/project")
            #expect(manager.endAgentSession(forPane: "%5"))
            #expect(manager.reconcileDetectedAgentSessions(detected(processIDs: ["202"])))
            #expect(manager.paneStates["%5"]?.agentSession?.pluginID == "codex")
        }

        @Test("A fresh command-panel probe bypasses an old cached snapshot",
              arguments: [false, true])
        func freshProcessSnapshot(replacesShell: Bool) async throws {
            let rows = LockIsolated("100 1 zsh\n101 100 codex\n")
            await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable executable, arguments, _, _ in
                    let output: String
                    if executable == "/bin/ps" {
                        output = rows.value
                    } else if arguments.contains("list-panes") {
                        let separator = String(PaneInfo.fieldSeparator)
                        output = "%5\(separator)100\(separator)/tmp/project\n"
                    } else {
                        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                let processNames = ["codex": ["codex"]]
                let first = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: processNames)
                #expect(first?["%5"]?.processIDs == ["101"])
                rows.setValue(replacesShell ? "100 1 codex\n" : "100 1 zsh\n202 100 codex\n")
                let cached = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: processNames)
                #expect(cached?["%5"]?.processIDs == ["101"])
                let fresh = await tmux.detectAgentPanesIfAvailable(
                    processNamesByPlugin: processNames, refreshSnapshot: true
                )
                #expect(fresh?["%5"]?.processIDs == (replacesShell ? ["100"] : ["202"]))
                let subsequent = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: processNames)
                #expect(subsequent?["%5"]?.processIDs == fresh?["%5"]?.processIDs)
            }
        }

        @Test("On-demand reconciliation preserves failed probes and publishes only changed identity")
        func onDemandReconciliation() async {
            let available = LockIsolated(false)
            await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable executable, arguments, _, _ in
                    guard available.value else {
                        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
                    }
                    let separator = String(PaneInfo.fieldSeparator)
                    let output = executable == "/bin/ps"
                        ? "100 1 zsh\n202 100 codex\n"
                        : "%5\(separator)100\(separator)/tmp/project\n"
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let manager = makeWindowManager(tmuxService: TmuxService(tmuxPath: "/usr/bin/tmux"))
                let updates = LockIsolated(0)
                manager.onAgentProcessReconciliationChanged = { updates.withValue { $0 += 1 } }
                manager.reconcileDetectedAgentSessions(detected())
                manager.endAgentSession(forPane: "%5")
                let names = ["codex": ["codex"]]
                await manager.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
                #expect(manager.paneStates["%5"]?.agentSession == nil)
                #expect(updates.value == 0)
                #expect(!manager.reconcileDetectedAgentSessions(detected()))

                available.setValue(true)
                await manager.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
                #expect(manager.paneStates["%5"]?.agentSession?.pluginID == "codex")
                #expect(updates.value == 1)
                await manager.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
                #expect(updates.value == 1)
                available.setValue(false)
                await manager.refreshDetectedAgentSessions(processNamesByPlugin: names, refreshSnapshot: true)
                #expect(manager.paneStates["%5"]?.agentSession?.pluginID == "codex")
                #expect(updates.value == 1)
            }
        }

        @Test("A slow older background probe cannot replace fresh command-panel identity")
        func concurrentFreshSnapshot() async {
            let calls = LockIsolated(0)
            let started = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            defer {
                started.continuation.finish()
                release.continuation.finish()
            }
            await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable executable, arguments, _, _ in
                    if executable == "/bin/ps" {
                        let call = calls.withValue { value in
                            value += 1
                            return value
                        }
                        if call == 1 {
                            started.continuation.yield(())
                            for await _ in release.stream { break }
                        }
                        let pid = call == 1 ? "101" : "202"
                        return ProcessResult(exitCode: 0,
                                             stdout: Data("100 1 zsh\n\(pid) 100 codex\n".utf8), stderr: Data())
                    }
                    let separator = String(PaneInfo.fieldSeparator)
                    return ProcessResult(exitCode: 0,
                                         stdout: Data("%5\(separator)100\(separator)/tmp/project\n".utf8), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                let names = ["codex": ["codex"]]
                let older = Task { await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: names) }
                for await _ in started.stream { break }
                let fresh = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: names, refreshSnapshot: true)
                #expect(fresh?["%5"]?.processIDs == ["202"])
                release.continuation.yield(())
                let result = await older.value
                #expect(result?["%5"]?.processIDs == ["202"])
                let cached = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: names)
                #expect(cached?["%5"]?.processIDs == ["202"])
            }
        }

        @Test("detections for unknown panes are ignored")
        func unknownPaneIsIgnored() {
            let manager = makeWindowManager()
            let unknown = [
                "%99": TmuxService.DetectedAgentPane(path: "/tmp/project", pluginID: "codex", processIDs: ["101"]),
            ]

            #expect(!manager.reconcileDetectedAgentSessions(unknown))
            #expect(manager.paneStates["%99"] == nil)
        }
    }
#endif
