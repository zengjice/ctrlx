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
struct AgentModelCatalogRefreshTests {
    @Test("Catalog refresh preserves only the same process's valid list", arguments: ["failed", "unsupported", "replaced", "cancelled"])
    func refresh(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-catalog-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = WorkspacePaneIdentity(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let sep = String(PaneInfo.fieldSeparator)
        let pane = ["%1", "work", "0", "0", "codex", "/fixture", "80", "5", "1", "", "", "dev", "1", "", "", "", "@1", identity.serverID, identity.sessionID.uuidString, identity.windowID.uuidString, identity.paneID.uuidString, "$1", "0"].joined(separator: sep)
        let terminal = ["80", "5", "2", "1", "1", "1", "0", "codex"].joined(separator: sep) + "\n\n› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n  Test Model low · /fixture\n\n"
        let runtime = LockIsolated("runtime")
        let behavior = LockIsolated(mode)
        let calls = LockIsolated(0)
        let models = [AgentModelOption(id: "test-model", name: "Test Model", efforts: ["low", "high"], defaultEffort: "low")]
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[AgentSessionIdentityClient.self].runtimeID = { _ in runtime.value }
            $0[WorkspaceAgentProcessClient.self].modelContext = { _, _, _, command in
                calls.withValue { $0 += 1 }
                #expect(command == "codex")
                switch behavior.value {
                case "replaced": runtime.setValue("replacement")
                    throw AgentModelError("Process replaced")
                case "cancelled": throw CancellationError()
                case "failed": throw AgentModelError("Metadata CLI temporarily unavailable")
                default: return .init(invocation: .init(executable: "/removed/codex", arguments: []), environment: [:], directory: "/fixture", discoveryExecutable: "/installed/codex", discoveryVersion: behavior.value == "unsupported" ? "unknown CLI" : "codex-cli 0.999.0")
                }
            }
            $0[ProcessRunner.self].run = { executable, args, _, _ in
                let output: String
                if executable == "/bin/ps" {
                    output = "100 1 zsh\n101 100 codex\n"
                } else if args.contains("list-panes") {
                    output = "%1\(sep)100\(sep)/fixture\n"
                } else if args.first == "display-message" {
                    output = pane
                } else if args.first == "if-shell" {
                    output = terminal
                } else {
                    throw AgentModelError("Unexpected fixture command")
                }
                #expect(!args.contains("send-keys"))
                return .init(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
            }
            $0[ProcessRunner.self].runWithExactEnvironment = { _, _, _, _, _, _ in
                .init(exitCode: 0, stdout: Data(#"{"models":[{"slug":"test-model","display_name":"Test Model","visibility":"list","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}"#.utf8), stderr: Data())
            }
        } operation: {
            let coordinator = AppCoordinator()
            let registry = PluginRegistry()
            try await registry.enable("codex", host: MockPluginHost(), env: .init(pluginRoot: root, stateDir: root, appVersion: "test", settings: JSONEncoder().encode(CodexSettings(exportTelemetry: false)), marketplaceSource: root))
            coordinator.pluginRegistry = registry
            coordinator.windowManager.setPaneStatesForPreview([.init(paneId: "%1", agentSession: .init(paneId: "%1", pluginID: "codex"), workspaceIdentity: identity)])
            coordinator.agentModelCatalogs["%1"] = .init(runtimeID: "runtime", models: models)
            do {
                if mode == "replaced" || mode == "cancelled" {
                    await #expect(throws: (any Error).self) { try await coordinator.handleAgentModels(.init(workspacePane: identity, refresh: true), paneID: "%1") }
                    #expect(coordinator.agentModelCatalogs["%1"]?.catalogWarning == nil)
                } else {
                    let value = try await coordinator.handleAgentModels(.init(workspacePane: identity, refresh: true), paneID: "%1")
                    #expect(value.models == models)
                    #expect(value.selection == .init(model: "test-model", effort: "low"))
                    #expect(value.unavailableReason == nil)
                    #expect(value.catalogWarning?.contains("previous list") == true)
                    let subsequent = try await coordinator.handleAgentModels(.init(workspacePane: identity), paneID: "%1")
                    #expect(subsequent.catalogWarning == value.catalogWarning)
                    #expect(calls.value == 1)
                    behavior.setValue("success")
                    let recovered = try await coordinator.handleAgentModels(.init(workspacePane: identity, refresh: true), paneID: "%1")
                    #expect(recovered.catalogWarning == nil)
                    #expect(recovered.models == models)
                    #expect(calls.value == 2)
                }
            } catch {
                await registry.disable("codex")
                throw error
            }
            await registry.disable("codex")
        }
    }
}
