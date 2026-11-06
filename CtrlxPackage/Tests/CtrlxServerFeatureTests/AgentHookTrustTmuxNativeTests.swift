import CodexPluginCore
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

/// Real Codex, private configuration and tmux socket; never submits a model prompt.
@MainActor
struct AgentHookTrustTmuxNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_CODEX_EXECUTABLE"] != nil))
    func approvalAndErrorCleanupWithoutRestart() async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: { try await runNative() }
    }

    private func runNative() async throws {
        let codex = try #require(ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_CODEX_EXECUTABLE"])
        let executable = try #require(ProcessInfo.processInfo.environment["CTRLX_TMUX_COMPAT_EXECUTABLE"])
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ctrlx-hook-native-\(UUID())")
        let home = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        model = "fixture"
        model_provider = "fixture"
        cli_auth_credentials_store = "file"
        approval_policy = "never"
        sandbox_mode = "read-only"
        [model_providers.fixture]
        name = "Local no-prompt fixture"
        base_url = "http://127.0.0.1:1/v1"
        wire_api = "responses"
        requires_openai_auth = false
        [projects."\(directory.path)"]
        trust_level = "trusted"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try #"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#
            .write(to: home.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        let socket = directory.appendingPathComponent("tmux.sock").path
        let run: @Sendable ([String]) async throws -> ProcessResult = { arguments in
            try await ProcessRunner.liveValue.run(executable, ["-S", socket, "-f", "/dev/null"] + arguments, ["TMUX": "", "TMUX_PANE": ""], 10)
        }
        let rejectTrust = LockIsolated(true)
        let rejectedTrust = LockIsolated(false)
        let nativeTurnCompleted = LockIsolated(false)
        let registry = PluginRegistry()
        do {
            try #require(try await run([
                "new-session", "-d", "-s", "probe", "-x", "80", "-y", "30", "-c", directory.path,
                "/usr/bin/env", "-i", "HOME=\(directory.path)", "CODEX_HOME=\(home.path)",
                "PATH=/opt/homebrew/bin:/usr/bin:/bin", "TERM=xterm-256color", codex, "--no-daemon", "--no-alt-screen",
            ]).isSuccess)
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0[ProcessRunner.self].runWithLaunch = { executable, arguments, environment, timeout, launch in
                    let plain = arguments.joined(separator: " ").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
                    if rejectTrust.value, plain.contains("send-keys"), plain.contains(" -l -- t") {
                        rejectedTrust.setValue(true)
                        throw AgentHookTrustError("Fixture: trust key was not sent")
                    }
                    return try await ProcessRunner.liveValue.runWithLaunch(executable, arguments, environment, timeout, launch)
                }
                $0.continuousClock = ContinuousClock()
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
                $0[AgentSessionIdentityClient.self].runtimeID = AgentSessionIdentityClient.liveValue.runtimeID
                $0[CodexHookTrustIdleClient.self].isIdle = { _, _ in nativeTurnCompleted.value }
            } operation: {
                let settings = AppSettings()
                settings.tmuxPath = executable
                settings.tmuxSocket = socket
                let coordinator = AppCoordinator(settings: settings)
                coordinator.tmuxService.workflowInputGate = AgentWorkflowInputGate()
                let target = try await coordinator.tmuxService.captureWorkspacePane(target: "probe")
                let paneID = target.info.paneId
                // Simulate a lost Stop event. FD ownership and native-record
                // parsing are exercised separately by the reader's native tests.
                coordinator.windowManager.setPaneStatesForPreview([.init(paneId: paneID, agentSession: .init(paneId: paneID, pluginID: "codex", state: .working), workspaceIdentity: target.identity)])
                let root = directory.appendingPathComponent("plugin-state")
                try await registry.enable("codex", host: MockPluginHost(), env: .init(pluginRoot: root, stateDir: root, appVersion: "test", settings: JSONEncoder().encode(CodexSettings(exportTelemetry: false)), marketplaceSource: root))
                coordinator.pluginRegistry = registry
                var ready = false
                var stableReads = 0
                var skippedStartup = false
                for _ in 0..<100 {
                    let screen = try await coordinator.tmuxService.captureAgentTerminal(paneID: paneID, identity: target.identity)
                    let lines = screen.plainLines.map { $0.trimmingCharacters(in: .whitespaces) }
                    if !skippedStartup, lines.contains("Hooks need review"), lines.contains("enter confirm · esc skip") {
                        // Let the startup prompt finish before declining trust;
                        // approval below must come from the Host action.
                        try await Task.sleep(for: .seconds(1))
                        _ = try await run(["send-keys", "-t", paneID, "Escape"])
                        skippedStartup = true
                        stableReads = 0
                    } else if AgentWorkflowComposerInspection.readiness(screen, composer: CodexPluginCore().hookTrustComposer, allowUnknownBracketedPaste: true) == .ready {
                        stableReads += 1
                        if stableReads >= 10 {
                            ready = true
                            break
                        }
                    } else {
                        stableReads = 0
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try #require(ready, "Private Codex did not reach its composer. Evidence: \(directory.path)")
                let pid = try await run(["display-message", "-p", "-t", paneID, "#{pane_pid}"]).stdoutString
                await #expect(throws: AgentHookTrustError.self) {
                    _ = try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity), paneID: paneID)
                }
                #expect(!rejectedTrust.value)
                nativeTurnCompleted.setValue(true)
                do {
                    _ = try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity), paneID: paneID)
                    Issue.record("The injected trust-key failure must be reported")
                } catch let error as AgentHookTrustError {
                    #expect(error.message == "Fixture: trust key was not sent")
                }
                try #require(rejectedTrust.value)
                let afterFailure = try await coordinator.tmuxService.captureAgentTerminal(paneID: paneID, identity: target.identity)
                #expect(AgentWorkflowComposerInspection.readiness(afterFailure, composer: CodexPluginCore().hookTrustComposer, allowUnknownBracketedPaste: true) == .ready)
                rejectTrust.setValue(false)
                #expect(try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity), paneID: paneID) == .approved)
                #expect(try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8).contains("trusted_hash"))
                #expect(try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity, refreshIfTrusted: false), paneID: paneID) == .alreadyTrusted)
                #expect(try await run(["display-message", "-p", "-t", paneID, "#{pane_pid}"]).stdoutString == pid)
                #expect(coordinator.windowManager.paneStates[paneID]?.agentSession?.state == .working)
                let screen = try await coordinator.tmuxService.captureAgentTerminal(paneID: paneID, identity: target.identity)
                #expect(AgentWorkflowComposerInspection.readiness(screen, composer: CodexPluginCore().hookTrustComposer, allowUnknownBracketedPaste: true) == .ready)
            }
        } catch {
            let screen = try? await run(["capture-pane", "-p", "-t", "probe"])
            try? screen?.stdoutString.write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            await registry.disable("codex")
            _ = try? await run(["kill-server"])
            print("Hook trust native evidence: \(directory.path)")
            throw error
        }
        await registry.disable("codex")
        _ = try await run(["kill-server"])
        try FileManager.default.removeItem(at: directory)
    }
}
