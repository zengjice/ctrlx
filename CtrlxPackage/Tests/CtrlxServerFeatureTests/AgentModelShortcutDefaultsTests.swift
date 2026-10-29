import ClaudeCodePluginCore
import CodexPluginCore
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentModelShortcutDefaultsTests {
    @Test("Provider settings read native model metadata without starting a conversation", arguments: [false, true])
    func catalog(official: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-shortcut-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[LoginShellPath.self] = .testValue
            $0[AgentCLIClient.self].inspect = { agent, _ in
                #expect(agent == .codex)
                return .available(path: "/fixture/codex", version: "codex-cli 0.165.0")
            }
            $0[ProcessRunner.self].runWithExactEnvironment = { executable, arguments, _, _, _, input in
                #expect(executable == "/usr/bin/env")
                #expect(arguments.prefix(5).elementsEqual(["-C", FileManager.default.homeDirectoryForCurrentUser.path, "/fixture/codex", "debug", "models"]))
                #expect(arguments.contains(#"model_provider="openai""#) == official)
                #expect(input == nil)
                return ProcessResult(exitCode: 0, stdout: Data(#"{"models":[{"slug":"model","display_name":"Model","visibility":"list","supported_reasoning_levels":[{"effort":"high"}]}]}"#.utf8), stderr: Data())
            }
        } operation: {
            let coordinator = AppCoordinator()
            coordinator.ctrlxPaths = CtrlxPaths(stateRootOverride: root)
            let settings = try JSONEncoder().encode(CodexSettings(exportTelemetry: false, defaultProviderID: "team"))
            #expect(await coordinator.setPluginSettings(id: "codex", settings) == nil)
            let registry = PluginRegistry()
            await registry.enable("codex", host: MockPluginHost(), env: PluginEnv(
                pluginRoot: root.appendingPathComponent("plugin"), stateDir: root,
                appVersion: "test", settings: settings, marketplaceSource: root
            ))
            coordinator.pluginRegistry = registry
            let options = try await coordinator.agentProviderModels(pluginID: "codex", providerID: official ? "openai" : nil)
            #expect(options.map(\.id) == ["model"])
            #expect(options.first?.efforts == ["high"])
            await registry.disable("codex")
        }
    }

    @Test("Provider defaults persist independently and only initialize new tabs", arguments: ["codex", "claude-code"])
    func providerDefaults(pluginID: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-shortcuts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: { () async throws in
            let coordinator = AppCoordinator()
            coordinator.ctrlxPaths = CtrlxPaths(stateRootOverride: root)
            let official = pluginID == "codex" ? "openai" : "anthropic"
            var configured = [
                "": AgentModelShortcuts(models: ["cli-hidden"]),
                official: AgentModelShortcuts(efforts: ["low"]),
                "team": AgentModelShortcuts(models: ["team-hidden"], efforts: ["medium"]),
            ]
            func encoded() throws -> Data {
                if pluginID == "codex" {
                    return try JSONEncoder().encode(CodexSettings(
                        providers: [.init(id: "team", name: "Team", baseURL: "https://example.com", model: "model", environmentKey: "API_KEY")],
                        defaultProviderID: "team", modelShortcutDefaults: configured
                    ))
                }
                return try JSONEncoder().encode(ClaudeCodeSettings(
                    providers: [.init(id: "team", name: "Team", baseURL: "https://example.com", model: "model", authKind: .apiKey, environmentKey: "ANTHROPIC_API_KEY")],
                    defaultProviderID: "team", modelShortcutDefaults: configured
                ))
            }
            #expect(try await coordinator.setPluginSettings(id: pluginID, encoded()) == nil)
            #expect(coordinator.newAgentModelShortcuts(pluginID: pluginID, providerID: nil) == configured["team"])
            #expect(coordinator.newAgentModelShortcuts(pluginID: pluginID, providerID: official) == configured[official])
            let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            let key = AgentModelPreferences.Key(hostID: "local", serverID: pane.serverID, windowID: pane.windowID)
            let original = coordinator.newAgentModelShortcuts(pluginID: pluginID, providerID: nil)
            coordinator.agentModelPreferences.initialize(.init(pane: pane, defaults: original), hostID: "local")
            coordinator.agentModelPreferences.tabs[key]?.models.insert("tab-hidden")
            configured["team"] = .init(models: ["new-default"])
            #expect(try await coordinator.setPluginSettings(id: pluginID, encoded()) == nil)
            #expect(coordinator.agentModelPreferences.tabs[key]?.models == ["team-hidden", "tab-hidden"])
            #expect(coordinator.agentModelPreferences.defaults[key] == original)

            let next = WorkspacePaneIdentity(serverID: pane.serverID, sessionID: pane.sessionID, windowID: UUID(), paneID: UUID())
            let nextDefaults = coordinator.newAgentModelShortcuts(pluginID: pluginID, providerID: nil)
            coordinator.agentModelPreferences.initialize(.init(pane: next, defaults: nextDefaults), hostID: "local")
            #expect(nextDefaults.models == ["new-default"])
            // An unrelated settings save must preserve the stored display defaults.
            let saved = coordinator.pluginSettingsData(id: pluginID)
            if pluginID == "codex" {
                var settings = CodexSettings.decode(from: saved)
                settings.autoRun = false
                #expect(try JSONDecoder().decode(CodexSettings.self, from: JSONEncoder().encode(settings)).modelShortcutDefaults == configured)
            } else {
                var settings = ClaudeCodeSettings.decode(from: saved)
                settings.autoRun = false
                #expect(try JSONDecoder().decode(ClaudeCodeSettings.self, from: JSONEncoder().encode(settings)).modelShortcutDefaults == configured)
            }
            #expect(await coordinator.setPluginSettings(id: pluginID, Data("{}".utf8)) == nil)
            #expect(coordinator.newAgentModelShortcuts(pluginID: pluginID, providerID: nil) == .init())
        }
    }

    @Test("Creation snapshots do not overwrite tab edits, cross Hosts or survive closing")
    func snapshots() {
        let store = AgentModelPreferences()
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let defaults = AgentModelShortcuts(models: ["hidden"], efforts: ["low"])
        let key = AgentModelPreferences.Key(hostID: "office", serverID: pane.serverID, windowID: pane.windowID)
        store.initialize(.init(pane: pane, defaults: defaults), hostID: "office")
        store.tabs[key]?.models.insert("edited")
        store.initialize(.init(pane: pane, defaults: .init()), hostID: "office")
        #expect(store.defaults[key] == defaults)
        #expect(store.tabs[key]?.models == ["hidden", "edited"])
        store.initialize(.init(pane: pane, defaults: .init()), hostID: "home")
        let home = AgentModelPreferences.Key(hostID: "home", serverID: pane.serverID, windowID: pane.windowID)
        #expect(store.tabs[home]?.models.isEmpty == true)
        store.prune(hostID: "office", identities: [pane])
        #expect(store.defaults[key] == defaults)
        store.prune(hostID: "office", identities: [])
        #expect(store.defaults[key] == nil && store.tabs[key] == nil)
        #expect(store.defaults[home] != nil)
    }

    @Test("Old settings show all buttons and old peers ignore the creation snapshot")
    func compatibility() throws {
        #expect(try JSONDecoder().decode(CodexSettings.self, from: Data("{}".utf8)).modelShortcutDefaults.isEmpty)
        #expect(try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data("{}".utf8)).modelShortcutDefaults.isEmpty)
        let old = Data("{\"commandId\":\"\(UUID())\",\"success\":true}".utf8)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: old).agentModelShortcuts == nil)
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let initialization = AgentModelShortcutInitialization(pane: pane, defaults: .init(models: ["a"], efforts: ["low"]))
        let response = CommandResponseMessage(commandId: UUID(), success: true, paneId: "%7", agentModelShortcuts: initialization)
        let data = try JSONEncoder().encode(response)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: data).agentModelShortcuts == initialization)
        struct OldResponse: Decodable { let success: Bool
            let paneId: String?
        }
        #expect(try JSONDecoder().decode(OldResponse.self, from: data).paneId == "%7")
    }
}
