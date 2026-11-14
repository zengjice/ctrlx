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
struct AgentWorkflowModelControlsTests {
    @Test(arguments: ["codex", "claude-code"], ["success", "revoked", "human"])
    func nativeModelControlsReuseTheWorkflowClaimAndCheckEveryWrite(pluginID: String, mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-model-controls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = WorkspacePaneIdentity(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let isClaude = pluginID == "claude-code"
        let command = isClaude ? "claude" : "codex"
        let sep = String(PaneInfo.fieldSeparator)
        let pane = ["%1", "work", "0", "0", command, "/fixture", "80", "6", "1", "", "", "dev", "1", "", "", "", "@1", identity.serverID, identity.sessionID.uuidString, identity.windowID.uuidString, identity.paneID.uuidString, "$1", "0"].joined(separator: sep)
        let effort = LockIsolated("low")
        let writes = LockIsolated(0)
        let pickerOpen = LockIsolated(false)
        let escapes = LockIsolated(0)
        let gate = AgentWorkflowInputGate()
        let claim = gate.claim(paneID: "%1")
        let authorization = AgentWorkflowWriteAuthorization(expiresAt: .distantFuture)
        try authorization.beginConfiguration()
        defer { authorization.endConfiguration() }
        let human = LockIsolated<Task<Void, Error>?>(nil)
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[AgentSessionIdentityClient.self].runtimeID = { _ in "runtime" }
            $0[ProcessRunner.self].run = { executable, args, _, _ in
                let output: String
                if executable == "/bin/ps" {
                    output = "100 1 zsh\n101 100 \(command)\n"
                } else if args.contains("list-panes") {
                    output = "%1\(sep)100\(sep)/fixture\n"
                } else if args.first == "display-message" {
                    output = pane
                } else if args.first == "if-shell" {
                    if isClaude {
                        let rule = String(repeating: "─", count: 80)
                        let lines = pickerOpen.value
                            ? ["Select model", "❯ 1. Test Model ✔", "● \(effort.value.capitalized) effort ←/→ to adjust", "Enter to set as default · s to use this session only · Esc to cancel", "", ""]
                            : ["Claude Code v2.1.310", "Test Model with \(effort.value) effort · API Usage Billing", rule, "❯\u{a0}\u{1b}[7m \u{1b}[0m", rule, ""]
                        output = ["80", "6", "2", "3", "1", "1", "0", command].joined(separator: sep) + "\n" + lines.joined(separator: "\n") + "\n"
                    } else {
                        output = ["80", "6", "2", "1", "1", "1", "0", command].joined(separator: sep) + "\n\n› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n  Test Model \(effort.value) · /fixture\n\n\n"
                    }
                } else {
                    throw AgentWorkflowError("Unexpected read")
                }
                #expect(!args.contains("send-keys"))
                return .init(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
            }
            $0[ProcessRunner.self].runWithLaunch = { _, args, _, _, launch in
                #expect(args.contains { $0.contains("send-keys") })
                let body = args[5]
                let cleanup = body.contains("'Escape'")
                let shouldInterrupt = !isClaude || body.contains("'Home'")
                if mode == "revoked", shouldInterrupt {
                    authorization.revoke()
                }
                if mode == "human", shouldInterrupt {
                    human.setValue(Task { try await gate.human(paneID: "%1") { } })
                    while (try? await gate.validate(claim)) != nil {
                        await Task.yield()
                    }
                }
                try await launch { writes.withValue { $0 += 1 } }
                if isClaude {
                    if body.contains(AgentModelTmuxSubmission.rejection) {
                        pickerOpen.setValue(true)
                    } else if body.contains("'Right'") {
                        effort.setValue("high")
                    } else if body.contains("'s'") || cleanup {
                        pickerOpen.setValue(false)
                    }
                    if cleanup {
                        escapes.withValue { $0 += 1 }
                    }
                } else {
                    effort.setValue("high")
                }
                return .init(exitCode: 0, stdout: Data(), stderr: Data())
            }
        } operation: {
            let coordinator = AppCoordinator()
            let registry = PluginRegistry()
            let settings = try isClaude ? JSONEncoder().encode(ClaudeCodeSettings()) : JSONEncoder().encode(CodexSettings(exportTelemetry: false))
            await registry.enable(pluginID, host: MockPluginHost(), env: .init(pluginRoot: root, stateDir: root, appVersion: "test", settings: settings, marketplaceSource: root))
            coordinator.pluginRegistry = registry
            coordinator.tmuxService.workflowInputGate = gate
            coordinator.windowManager.setPaneStatesForPreview([.init(paneId: "%1", agentSession: .init(paneId: "%1", pluginID: pluginID), workspaceIdentity: identity)])
            coordinator.agentModelCatalogs["%1"] = .init(runtimeID: "runtime", models: [.init(id: "test-model", name: "Test Model", efforts: ["low", "high"], defaultEffort: "low", screenNames: ["Test Model"])], pluginID: pluginID)
            let request = AgentModelControls(workspacePane: identity, runtimeID: "runtime", selection: .init(model: "test-model", effort: "high"))
            do {
                if mode == "success" {
                    let snapshot = try await gate.workflow(claim) {
                        try await coordinator.handleAgentModels(request, paneID: "%1", workflowInput: .init(claim: claim, authorization: authorization))
                    }
                    #expect(snapshot.selection == request.selection)
                    try gate.validate(claim)
                    #expect(writes.value == (isClaude ? 6 : 1))
                } else {
                    await #expect(throws: (any Error).self) {
                        try await gate.workflow(claim) {
                            try await coordinator.handleAgentModels(request, paneID: "%1", workflowInput: .init(claim: claim, authorization: authorization))
                        }
                    }
                    #expect(writes.value == (isClaude ? 2 : 0) && effort.value == "low")
                }
                #expect(!pickerOpen.value)
                #expect(escapes.value == (isClaude ? 1 : 0))
            } catch {
                await registry.disable(pluginID)
                throw error
            }
            await registry.disable(pluginID)
        }
        try await human.value?.value
    }
}
