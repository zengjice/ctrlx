import CtrlxCommon
import CtrlxEncryption
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeProviderModelsTests {
    @Test("Legacy Claude profiles retain their default when adding models")
    func persistence() throws {
        let legacy = Data(#"{"id":"team","name":"Team","base_url":"https://example.com","model":"model-a","auth_kind":"api_key","environment_key":"ANTHROPIC_API_KEY"}"#.utf8)
        var profile = try JSONDecoder().decode(ClaudeProviderProfile.self, from: legacy)
        #expect(profile.modelIDs == ["model-a"])
        profile.models = ["model-a", "model-b"]
        #expect(try JSONDecoder().decode(ClaudeProviderProfile.self, from: JSONEncoder().encode(profile)) == profile)
    }

    @Test("Claude launch, Fork, discovery and recovery share the native custom picker")
    func launchAndRecovery() async throws {
        let secrets = SecretsService.inMemory()
        try await secrets.storeSecret("fixture-key", AgentProviderKeychainAccount.account(pluginID: "claude-code", providerID: "team"))
        var profile = ClaudeProviderProfile(id: "team", name: "Team", baseURL: "http://127.0.0.1:9", model: "model-a", models: ["model-a", "model-b"], authKind: .apiKey, environmentKey: "ANTHROPIC_API_KEY", reasoningEffort: .high)
        try await withDependencies {
            $0[SecretsService.self] = secrets
            $0[AgentForkHistoryClient.self].root = { _, _, _ in "/source/config" }
            $0[AgentResumeExecutableClient.self].resolve = { _, configured in configured }
            $0[ProcessRunner.self].runWithExactEnvironment = { _, args, environment, _, _, input in
                let index = try #require(args.firstIndex(of: "--settings"))
                let settings = try #require(JSONSerialization.jsonObject(with: Data(args[index + 1].utf8)) as? [String: Any])
                #expect(settings["disableAllHooks"] as? Bool == true)
                #expect(try modelIDs(settings) == ["model-a", "model-b"])
                #expect(args.contains("--strict-mcp-config"))
                #expect(environment["ANTHROPIC_MODEL"] == "model-a")
                #expect(input.map { String(decoding: $0, as: UTF8.self).contains("initialize") } == true)
                return ProcessResult(exitCode: 0, stdout: Data(#"{"type":"control_response","response":{"response":{"models":[{"value":"model-a","displayName":"model-a"},{"value":"model-b","displayName":"model-b"}]}}}"#.utf8), stderr: Data())
            }
        } operation: {
            let core = ClaudeCodePluginCore()
            func encoded() throws -> Data {
                try JSONEncoder().encode(ClaudeCodeSettings(providers: [profile], defaultProviderID: "team"))
            }
            _ = try await core.applySettings(encoded())
            let launch = try #require(try await core.commandForLaunch(projectPath: "/project", providerID: nil))
            #expect(launch.env["ANTHROPIC_MODEL"] == "model-a")
            #expect(try modelIDs(ClaudeProviderModelPicker.extracting(from: launch.args).settings) == ["model-a", "model-b"])
            let context = AgentModelContext(invocation: .init(executable: "/tools/claude", arguments: launch.args, version: "2.1.327 (Claude Code)"), environment: launch.env, directory: "/project")
            #expect(core.modelRuntimeIssue(context) == nil)
            #expect(try await core.modelOptions(context).map(\.id) == ["model-a", "model-b"])
            let id = UUID().uuidString
            let fork = try await core.commandForFork(sessionID: id, projectPath: "/project", targetProviderID: "team")
            #expect(fork.command.env["CLAUDE_CONFIG_DIR"] == "/source/config")
            #expect(try modelIDs(ClaudeProviderModelPicker.extracting(from: fork.command.args).settings) == ["model-a", "model-b"])
            let saved = try await core.recoveryDescriptor(sessionID: id, projectPath: "/project", invocation: .init(executable: "/tools/claude", arguments: launch.args, configurationRoots: ["CLAUDE_CONFIG_DIR": "/source/config"], providerID: "team"))
            #expect(saved.arguments == ["--effort", "high"])
            profile.models = ["model-a", "model-c"]
            _ = try await core.applySettings(encoded())
            let resumed = try await core.commandForResume(saved)
            #expect(try modelIDs(ClaudeProviderModelPicker.extracting(from: resumed.command.args).settings) == ["model-a", "model-c"])
            #expect(resumed.command.args.prefix(4) == ["--resume", id, "--effort", "high"])
        }
    }

    @Test("Unrelated inline settings are never replayed as a model catalog", arguments: [
        "{}", "/tmp/settings.json", #"{"modelPicker":{"options":[],"replaceBuiltInOptions":true}}"#,
        #"{"modelPicker":{"options":[{"model":"a","label":"a"}],"replaceBuiltInOptions":true},"env":{"ANTHROPIC_API_KEY":"secret"}}"#,
    ])
    func rejectsUnrelatedSettings(settings: String) {
        #expect(throws: (any Error).self) { try ClaudeProviderModelPicker.extracting(from: ["--settings", settings]) }
        let core = ClaudeCodePluginCore()
        let context = AgentModelContext(invocation: .init(executable: "/tools/claude", arguments: ["--settings", settings], version: "2.1.327 (Claude Code)"), environment: [:], directory: "/project")
        #expect(core.modelRuntimeIssue(context) != nil)
    }

    private func modelIDs(_ settings: [String: Any]?) throws -> [String] {
        let picker = try #require(settings?["modelPicker"] as? [String: Any])
        #expect(picker["replaceBuiltInOptions"] as? Bool == true)
        return try #require(picker["options"] as? [[String: String]]).compactMap { $0["model"] }
    }
}
