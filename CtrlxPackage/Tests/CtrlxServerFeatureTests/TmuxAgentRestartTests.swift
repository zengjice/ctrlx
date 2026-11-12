import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct TmuxAgentRestartTests {
    private struct ProcessFailure: Error, CustomStringConvertible {
        let description: String
    }

    @Test("Restart and SessionEnd preserve the pane; ordinary and successor exits still close it", arguments: ["direct", "shell", "environment", "changed", "busy", "busy-late", "busy-cached", "busy-cached-late", "cli-error", "normal-exit", "terminate-error", "successor-exit", "successor-cached-exit"])
    func terminalLifecycle(mode: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/ctrlx-restart-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("tmux.sock").path
        let binary = try #require(TmuxBinaryLocator.liveValue.find())
        let runner = ProcessRunner.liveValue
        let environment = ["HOME": directory.path, "ZDOTDIR": directory.path, "TMUX": "", "TMUX_PANE": ""]
        let execute: @Sendable (String, [String], [String: String]?, TimeInterval?) async throws -> ProcessResult = { path, arguments, supplied, timeout in
            do {
                return try await runner.run(executable: path, arguments: arguments, environment: (supplied ?? [:]).merging(environment) { _, isolated in isolated }, timeout: timeout)
            } catch {
                throw ProcessFailure(description: "\(mode): \(path) \(arguments) failed: \(error)")
            }
        }
        let run: @Sendable ([String]) async throws -> ProcessResult = { arguments in
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                try await execute(binary, ["-S", socket, "-f", "/dev/null"] + arguments, environment, 10)
            }
        }
        do {
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0[LoginItemService.self] = .previewValue
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
                $0[AgentRestartProcessClient.self].terminate = { pid, runtime in
                    if mode == "terminate-error" {
                        throw AgentRestartError("Fixture: signal was not sent")
                    }
                    try AgentRestartProcessClient.liveValue.terminate(pid, runtime)
                }
                $0[AgentSessionIdentityClient.self].runtimeID = { AgentSessionIdentityClient.processRuntimeID($0) }
                $0[ProcessRunner.self].run = execute
                $0[ProcessRunner.self].runWithInput = { path, arguments, supplied, timeout, input in
                    #expect(!arguments.joined().contains("private-provider-value"))
                    return try await runner.runWithInput(executable: path, arguments: arguments, environment: (supplied ?? [:]).merging(environment) { _, isolated in isolated }, timeout: timeout, input: input)
                }
            } operation: {
                let busy = mode.hasPrefix("busy")
                let cached = busy && mode.contains("cached")
                let wrapped = mode == "shell" || busy
                let command = wrapped ? ["/bin/zsh", "-f", "-c", busy ? "/bin/sleep 60 & /bin/cat; wait" : "/bin/sleep 60; exec /bin/zsh -f"] : ["/bin/sleep", "60"]
                try #require(try await run(["new-session", "-d", "-s", "fixture", "-c", directory.path] + command).isSuccess)
                let settings = AppSettings()
                settings.tmuxPath = binary
                settings.tmuxSocket = socket
                let coordinator = AppCoordinator(settings: settings)
                coordinator.pluginRegistry = PluginRegistry()
                let tmux = coordinator.tmuxService
                tmux.zdotDirOverride = directory.path
                tmux.workflowInputGate = AgentWorkflowInputGate()
                let info = try #require(await tmux.refreshPanes().first)
                let workspace = try #require(info.workspaceIdentity)
                let rootPID = try await run(["display-message", "-p", "-t", info.paneId, "#{pane_pid}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                var pid = rootPID
                var children: [String] = []
                if wrapped {
                    for _ in 0..<80 {
                        let rows = try await runner.run(executable: "/bin/ps", arguments: ["-eo", "pid,ppid,comm"], environment: environment, timeout: 5).stdoutString.split(separator: "\n")
                        children = rows.compactMap { row in
                            let values = row.split(whereSeparator: \.isWhitespace)
                            return values.count >= 3 && values[1] == rootPID && values.last == "/bin/sleep" ? String(values[0]) : nil
                        }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
                        let foreground = rows.compactMap { row -> String? in
                            let values = row.split(whereSeparator: \.isWhitespace)
                            return values.count >= 3 && values[1] == rootPID && values.last == (busy ? "/bin/cat" : "/bin/sleep") ? String(values[0]) : nil
                        }
                        if children.count == 1, let child = foreground.first {
                            pid = child
                            break
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    try #require(pid != rootPID)
                }
                let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
                var pane = PaneState(
                    paneId: info.paneId, sessionName: info.sessionName, tmuxWindowId: info.tmuxWindowId,
                    currentPath: info.currentPath, agentSession: .init(paneId: info.paneId, pluginID: "codex", processRuntimeID: runtime),
                    claudeSessionID: UUID().uuidString, workspaceIdentity: workspace
                )
                coordinator.windowManager.setPaneStatesForPreview([pane])
                coordinator.windowManager.setYoloMode(enabled: true, for: pane.paneId)
                let source = try #require(AgentForkSource(pane: pane))
                let end = {
                    let action = AppAction.sessionEnded(sessionID: source.paneID, closePaneEligible: true)
                    await coordinator.handlePluginAppAction(action, event: .init(pluginID: source.pluginID, sessionID: source.sessionID, appActions: [action], tmuxPane: source.paneID), peer: nil)
                    #expect(coordinator.windowManager.paneStates[source.paneID]?.agentSession == nil)
                    #expect(coordinator.windowManager.paneStates[source.paneID]?.claudeSessionID == nil)
                    #expect(!coordinator.windowManager.isYoloModeEnabled(for: source.paneID))
                }
                let marker = directory.appendingPathComponent("resumed.txt")
                if mode == "environment" {
                    for file in [".bashrc", ".zshrc"] {
                        try Data("export CTRLX_RESTART_UPDATED_ENV=fresh\n".utf8).write(to: directory.appendingPathComponent(file))
                    }
                }
                let output = mode == "environment" ? #"printf 'resumed[%s]' "$CTRLX_RESTART_UPDATED_ENV""# : "printf resumed"
                let launch = AgentForkLaunch(command: .init(command: mode == "cli-error" ? "/usr/bin/false" : "/bin/sh", args: mode == "cli-error" ? [] : ["-c", "\(output) > \(marker.path.posixSingleQuoted); exec /bin/cat"], env: ["CTRLX_RESTART_FIXTURE": "private-provider-value"]))
                let restart = {
                    try await tmux.restartAgent(.init(source: source, processID: pid, runtimeID: runtime), command: launch) {
                        if mode == "changed" {
                            throw AgentRestartError("The Agent changed")
                        }
                        if cached {
                            // Production validation primes this same one-second
                            // cache immediately before sending SIGTERM.
                            let detected = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: ["codex": ["cat"]], refreshSnapshot: true)
                            #expect(detected?[info.paneId]?.processIDs == [pid])
                        }
                    }
                }
                if mode == "changed" || mode == "terminate-error" {
                    await #expect(throws: AgentRestartError.self) { try await restart() }
                    #expect(!FileManager.default.fileExists(atPath: marker.path))
                    #expect(AgentSessionIdentityClient.processRuntimeID(pid) == runtime)
                    if mode == "changed" {
                        let event = PluginEvent(pluginID: source.pluginID, sessionID: source.sessionID, tmuxPane: source.paneID)
                        #expect(try tmux.shouldCloseAgentPane(after: #require(AgentSessionEndContext(event: event, pane: pane)), eligible: true))
                    }
                } else if busy {
                    let task = Task { try await restart() }
                    defer { task.cancel() }
                    if mode == "busy" || cached {
                        for _ in 0..<120 where AgentSessionIdentityClient.processRuntimeID(pid) == runtime {
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        try #require(AgentSessionIdentityClient.processRuntimeID(pid) == nil)
                        if cached {
                            await coordinator.windowManager.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["cat"]])
                            let refreshed = coordinator.windowManager.paneStates[source.paneID]
                            // The production cached-PID lookup now returns nil,
                            // but the session's last verified owner must survive.
                            #expect(refreshed?.agentSession != nil)
                            #expect(refreshed?.agentSession?.processRuntimeID == runtime)
                            #expect(refreshed?.claudeSessionID == source.sessionID)
                        }
                        if !mode.hasSuffix("-late") {
                            await end()
                        }
                    }
                    await #expect(throws: AgentRestartError.self) { try await task.value }
                    if mode.hasSuffix("-late") {
                        await end()
                    }
                    #expect(!FileManager.default.fileExists(atPath: marker.path))
                    #expect(try AgentSessionIdentityClient.processRuntimeID(#require(children.first)) != nil)
                } else if mode != "normal-exit" {
                    try await restart()
                    if mode != "cli-error" {
                        for _ in 0..<80 where !FileManager.default.fileExists(atPath: marker.path) {
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        #expect(try String(contentsOf: marker, encoding: .utf8) == (mode == "environment" ? "resumed[fresh]" : "resumed"))
                    } else {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    #expect(AgentSessionIdentityClient.processRuntimeID(pid) == nil)
                }
                if ["normal-exit", "terminate-error", "successor-exit", "successor-cached-exit"].contains(mode) {
                    if mode.hasPrefix("successor") {
                        // Same conversation and pane, but the resumed process's
                        // ordinary exit must not inherit the predecessor's opt-out.
                        let detected = await tmux.detectAgentPanesIfAvailable(processNamesByPlugin: ["codex": ["cat"]], refreshSnapshot: true)
                        let nextPID = try #require(detected?[info.paneId]?.processIDs.first)
                        let nextRuntime: String = try #require(AgentSessionIdentityClient.processRuntimeID(nextPID))
                        pane.agentSession?.processRuntimeID = nextRuntime
                        #expect(pane.agentSession?.processRuntimeID != runtime)
                        coordinator.windowManager.setPaneStatesForPreview([pane])
                        if mode == "successor-cached-exit" {
                            try AgentRestartProcessClient.liveValue.terminate(nextPID, nextRuntime)
                            for _ in 0..<120 where AgentSessionIdentityClient.processRuntimeID(nextPID) == nextRuntime {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            try #require(AgentSessionIdentityClient.processRuntimeID(nextPID) == nil)
                            await coordinator.windowManager.refreshDetectedAgentSessions(processNamesByPlugin: ["codex": ["cat"]])
                            #expect(coordinator.windowManager.paneStates[source.paneID]?.agentSession?.processRuntimeID == nextRuntime)
                        }
                    } else {
                        try #require(try await run(["set-option", "-p", "-t", info.paneId, "remain-on-exit", "on"]).isSuccess)
                        try AgentRestartProcessClient.liveValue.terminate(pid, runtime)
                        for _ in 0..<120 where AgentSessionIdentityClient.processRuntimeID(pid) == runtime {
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        try #require(AgentSessionIdentityClient.processRuntimeID(pid) == nil)
                    }
                    await end()
                    for _ in 0..<100 {
                        if try await !run(["has-session", "-t", "fixture"]).isSuccess {
                            break
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    #expect(try await !run(["has-session", "-t", "fixture"]).isSuccess)
                    return
                }
                if !busy, mode != "changed" {
                    await end()
                }
                if mode != "changed" {
                    // Includes a late end after restart returned (CLI error and
                    // busy timeout), beyond the auto-close task's two-second grace.
                    try await Task.sleep(for: .milliseconds(2_300))
                }
                let after = await tmux.refreshPanes()
                #expect(after.count == 1 && after.first?.paneId == info.paneId && after.first?.workspaceIdentity == workspace)
                #expect(try await run(["display-message", "-p", "-t", info.paneId, "#{pane_dead}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
                #expect(try await run(["show-options", "-p", "-q", "-t", info.paneId, "remain-on-exit"]).stdoutString.isEmpty)
            }
        } catch {
            _ = try? await run(["kill-server"])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = try? await run(["kill-server"])
        try FileManager.default.removeItem(at: directory)
    }
}
