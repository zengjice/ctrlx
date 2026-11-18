import CtrlxCommon
import CtrlxEncryption
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexProviderModelsTests {
    @Test("Legacy single-model profiles and new lists keep the launch default")
    func persistence() throws {
        let legacy = Data(#"{"id":"team","name":"Team","base_url":"https://example.com","model":"model-a","environment_key":"API_KEY"}"#.utf8)
        var profile = try JSONDecoder().decode(CodexProviderProfile.self, from: legacy)
        #expect(profile.modelIDs == ["model-a"])
        profile.models = [" model-b ", "model-a", "", "model-b", "vendor/model@revision"]
        let restored = try JSONDecoder().decode(CodexProviderProfile.self, from: JSONEncoder().encode(profile))
        #expect(restored.model == "model-a")
        #expect(restored.modelIDs == ["model-a", "model-b", "vendor/model@revision"])
        #expect(AgentProviderModels.isValid(defaultModel: restored.model, models: restored.models))
        #expect(!CodexSettings.isValidEnvironmentKey("TRAE_HOME"))
        #expect(!AgentProviderModels.isValid(defaultModel: "", models: ["model-a"]))
        #expect(!AgentProviderModels.isValid(defaultModel: "model-a", models: ["bad model", "bad\nmodel"]))
        #expect(!AgentProviderModels.isValid(defaultModel: "model-a", models: (0..<100).map { "model-\($0)" }))
    }

    @Test("Codex and Traex launch, Fork and resume use all Provider models and separate credentials", arguments: [CodexDistribution.codex, .traex])
    func launches(distribution: CodexDistribution) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-provider-models-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = SecretsService.inMemory()
        for plugin in ["codex", "traex"] {
            try await secrets.storeSecret("\(plugin)-key", AgentProviderKeychainAccount.account(pluginID: plugin, providerID: "team"))
        }
        var profile = CodexProviderProfile(id: "team", name: "Team", baseURL: "http://127.0.0.1:9/v1", model: "model-a", models: ["model-a", "vendor/model@revision"], environmentKey: "API_KEY", reasoningEffort: .high)
        try await withDependencies {
            $0[SecretsService.self] = secrets
            $0[AgentForkHistoryClient.self].root = { _, _, layout in
                #expect(layout == (distribution == .codex ? .codex : .traex))
                return "/source/config"
            }
            $0[AgentResumeExecutableClient.self].resolve = { _, configured in configured }
            $0[ProcessRunner.self].runBounded = { _, args, _, _, _ in
                #expect(args == [distribution.command, "debug", "models", "--bundled"])
                return ProcessResult(exitCode: 0, stdout: Data(#"{"models":[{"model_messages":{"instructions_template":"instructions"}}]}"#.utf8), stderr: Data())
            }
        } operation: {
            let core = CodexPluginCore(distribution: distribution)
            func encoded() throws -> Data {
                try JSONEncoder().encode(CodexSettings(commandPath: distribution.command, exportTelemetry: false, providers: [profile], defaultProviderID: profile.id))
            }
            try await core.initialize(.init(pluginRoot: root, stateDir: root, appVersion: "test", settings: encoded(), marketplaceSource: root), host: MockPluginHost())
            #expect(await core.providerOptions().contains { $0.id == "team" })
            #expect(await core.providerOptions().contains { $0.id == "openai" } == (distribution == .codex))
            let launch = try #require(try await core.commandForLaunch(projectPath: "/project", providerID: nil))
            #expect(launch.env["API_KEY"] == "\(distribution.pluginID)-key")
            #expect(launch.args.suffix(4) == ["--model", "model-a", "--dangerously-bypass-hook-trust", "--no-daemon"])
            let catalog = root.appendingPathComponent("model-catalogs/team.json")
            #expect(try CodexModelCatalog.parse(Data(contentsOf: catalog)).map(\.id) == ["model-a", "vendor/model@revision"])
            let id = UUID().uuidString
            let fork = try await core.commandForFork(sessionID: id, projectPath: "/project", targetProviderID: "team")
            #expect(fork.command.env[distribution == .codex ? "CODEX_HOME" : "TRAE_HOME"] == "/source/config")
            #expect(fork.command.args.contains("model-a"))
            let descriptor = try await core.recoveryDescriptor(sessionID: id, projectPath: "/project", invocation: .init(executable: "/tools/\(distribution.command)", arguments: launch.args, providerID: "team"))
            #expect(!descriptor.arguments.joined().contains("-key"))
            profile.models = ["model-a", "model-c"]
            _ = try await core.applySettings(encoded())
            let resumed = try await core.commandForResume(descriptor)
            #expect(resumed.command.env["API_KEY"] == "\(distribution.pluginID)-key")
            #expect(try CodexModelCatalog.parse(Data(contentsOf: catalog)).map(\.id) == ["model-a", "model-c"])
            await core.shutdown()
        }
    }
}
