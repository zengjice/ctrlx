import CodexPluginCore
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

/// Opt-in, private no-network CLI fixture; never targets the user's tmux server.
@MainActor
struct AgentHookTrustNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_SOCKET"] != nil))
    func nativeApprovalWithoutRestart() async throws {
        let rejectTrust = LockIsolated(true)
        let rejectedTrust = LockIsolated(false)
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
        } operation: {
            let socket = try #require(ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_SOCKET"])
            try #require(socket.hasSuffix("/.build-local/hook-trust-shortcut/native/tmux.sock"))
            let directory = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let settings = AppSettings()
            settings.tmuxPath = "/opt/homebrew/bin/tmux"
            settings.tmuxSocket = socket
            let coordinator = AppCoordinator(settings: settings)
            coordinator.tmuxService.workflowInputGate = AgentWorkflowInputGate(authorizeHumanInput: { _ in .init() })
            let target = try await coordinator.tmuxService.captureWorkspacePane(target: "probe")
            let paneID = target.info.paneId
            coordinator.windowManager.setPaneStatesForPreview([.init(paneId: paneID, agentSession: .init(paneId: paneID, pluginID: "codex"), workspaceIdentity: target.identity)])
            let registry = PluginRegistry()
            let root = directory.appendingPathComponent("plugin-state")
            try await registry.enable("codex", host: MockPluginHost(), env: .init(pluginRoot: root, stateDir: root, appVersion: "test", settings: JSONEncoder().encode(CodexSettings(exportTelemetry: false)), marketplaceSource: root))
            coordinator.pluginRegistry = registry
            let pid: @Sendable () async throws -> String = {
                try await ProcessRunner.liveValue.run("/opt/homebrew/bin/tmux", ["-S", socket, "display-message", "-p", "-t", paneID, "#{pane_pid}"], nil, 5).stdoutString
            }
            let beforePID = try await pid()
            do {
                var stale = target.identity
                stale.paneID = UUID()
                await #expect(throws: (any Error).self) {
                    _ = try await coordinator.handleTrustAgentHooks(.init(workspacePane: stale), paneID: paneID)
                }
                await #expect(throws: AgentHookTrustError.self) {
                    _ = try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity), paneID: paneID)
                }
                try #require(rejectedTrust.value)
                rejectTrust.setValue(false)
                var closed = false
                for _ in 0..<30 {
                    let screen = try await coordinator.tmuxService.captureAgentTerminal(paneID: paneID, identity: target.identity)
                    if AgentWorkflowComposerInspection.readiness(screen, composer: CodexPluginCore().hookTrustComposer) == .ready {
                        closed = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try #require(closed, "A recognized hooks panel must close after a failed approval")
                #expect(try !String(contentsOf: directory.appendingPathComponent("codex/config.toml"), encoding: .utf8).contains("trusted_hash"))
                let approved = try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity), paneID: paneID)
                #expect(approved == .approved)
                #expect(try await pid() == beforePID)
                let config = try String(contentsOf: directory.appendingPathComponent("codex/config.toml"), encoding: .utf8)
                #expect(config.components(separatedBy: "trusted_hash").count - 1 == 2)
                #expect(config.contains("enabled = false"))
                let repeated = try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity, refreshIfTrusted: false), paneID: paneID)
                #expect(repeated == .alreadyTrusted)
                #expect(try await pid() == beforePID)
            } catch {
                await registry.disable("codex")
                throw error
            }
            await registry.disable("codex")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_SHARED_SOCKET"] != nil))
    func nativeSharedApprovalNeedsRefresh() async throws {
        let onToggle = LockIsolated<(@MainActor @Sendable () async -> Void)?>(nil)
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0[ProcessRunner.self].runWithLaunch = { executable, arguments, environment, timeout, launch in
                let result = try await ProcessRunner.liveValue.runWithLaunch(executable, arguments, environment, timeout, launch)
                let command = arguments.joined(separator: " ")
                if
                    command.contains("send-keys"), command.contains("Space"),
                    let inject = onToggle.withValue({ value in let action = value
                        value = nil
                        return action }) {
                    await inject()
                }
                return result
            }
            $0.continuousClock = ContinuousClock()
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[AgentSessionIdentityClient.self].runtimeID = AgentSessionIdentityClient.liveValue.runtimeID
        } operation: {
            let socket = try #require(ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_SHARED_SOCKET"])
            // The fixture has two private Codex processes sharing one CODEX_HOME.
            try #require(socket.contains("/.build-local/hook-trust-plugin-probe/run-") && socket.hasSuffix("/tmux.sock"))
            let directory = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let config = directory.appendingPathComponent("codex/config.toml")
            let before = try Data(contentsOf: config)
            let settings = AppSettings()
            settings.tmuxPath = "/opt/homebrew/bin/tmux"
            settings.tmuxSocket = socket
            let coordinator = AppCoordinator(settings: settings)
            let inputGate = AgentWorkflowInputGate(authorizeHumanInput: { _ in .init() })
            coordinator.tmuxService.workflowInputGate = inputGate
            let target = try await coordinator.tmuxService.captureWorkspacePane(target: "probe:first")
            let paneID = target.info.paneId
            coordinator.windowManager.setPaneStatesForPreview([.init(paneId: paneID, agentSession: .init(paneId: paneID, pluginID: "codex"), workspaceIdentity: target.identity)])
            let registry = PluginRegistry()
            let root = directory.appendingPathComponent("plugin-state")
            try await registry.enable("codex", host: MockPluginHost(), env: .init(pluginRoot: root, stateDir: root, appVersion: "test", settings: JSONEncoder().encode(CodexSettings(exportTelemetry: false)), marketplaceSource: root))
            coordinator.pluginRegistry = registry
            let takeover = ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_TAKEOVER"] == "1"
            let humanTask = LockIsolated<Task<Bool, Error>?>(nil)
            if takeover {
                onToggle.setValue {
                    let generation = inputGate.claim(paneID: paneID).generation
                    humanTask.setValue(Task { @MainActor in
                        try await inputGate.human(paneID: paneID) { _ in
                            let screen = try await coordinator.tmuxService.captureAgentTerminal(paneID: paneID, identity: target.identity)
                            return AgentWorkflowComposerInspection.readiness(screen, composer: CodexPluginCore().hookTrustComposer) == .ready
                        }
                    })
                    while inputGate.claim(paneID: paneID).generation == generation {
                        await Task.yield()
                    }
                }
            }
            do {
                let refresh = ProcessInfo.processInfo.environment["CTRLX_HOOK_TRUST_REFRESH"] == "1"
                if takeover {
                    do {
                        _ = try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity), paneID: paneID)
                        Issue.record("Human takeover must stop refresh")
                    } catch let error as AgentHookTrustError {
                        #expect(error.preservePanel)
                    }
                    let task = try #require(humanTask.value)
                    #expect(try await task.value, "Queued human input must reach the composer, not a hook toggle")
                } else {
                    let result = try await coordinator.handleTrustAgentHooks(.init(workspacePane: target.identity, refreshIfTrusted: refresh), paneID: paneID)
                    #expect(result == .alreadyTrusted)
                }
                if !refresh {
                    #expect(try Data(contentsOf: config) == before)
                }
                let screen = try await coordinator.tmuxService.captureAgentTerminal(paneID: paneID, identity: target.identity)
                #expect(AgentWorkflowComposerInspection.readiness(screen, composer: CodexPluginCore().hookTrustComposer) == .ready)
            } catch {
                await registry.disable("codex")
                throw error
            }
            await registry.disable("codex")
        }
    }
}
