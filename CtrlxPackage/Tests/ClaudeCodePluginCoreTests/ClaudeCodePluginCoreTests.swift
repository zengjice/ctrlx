import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore

/// Lifecycle + auto-launch behavior of the core itself (the pieces not covered
/// by the translator / keystroke / scanner / installer suites).
@Suite("ClaudeCodePluginCore")
struct ClaudeCodePluginCoreTests {
    @Test("Verified Claude recovery binds automatic support to the recorded CLI version")
    func nativeResumeVerifiedVersion() async throws {
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in try #require(roots.first) }
        } operation: {
            let core = ClaudeCodePluginCore()
            let descriptor = try await core.recoveryDescriptor(sessionID: UUID().uuidString, projectPath: "/project", invocation: .init(executable: "/tools/claude", arguments: [], version: "2.1.276 (Claude Code)"))
            #expect(descriptor.automaticResumeUnavailableReason == nil)
            #expect(descriptor.cliVersion == "2.1.276 (Claude Code)")
            #expect(try await core.commandForResume(descriptor).command.args == ["--resume", descriptor.sessionID])
        }
    }

    @Test("An explicitly set Claude root stays explicit even when it is the default directory")
    func nativeResumeInvocation() async throws {
        let id = UUID().uuidString
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").resolvingSymlinksInPath().path
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in
                #expect(roots == [root])
                return root
            }
        } operation: {
            let core = ClaudeCodePluginCore()
            let descriptor = try await core.recoveryDescriptor(sessionID: id, projectPath: "/project", invocation: .init(executable: "/tools/claude", arguments: ["--resume", "old-id", "--fork-session", "--model", "sonnet", "--permission-mode", "plan", "private prompt"], configurationRoots: ["CLAUDE_CONFIG_DIR": root], version: "fixture-version"))
            #expect(!descriptor.usesDefaultConfiguration)
            #expect(descriptor.automaticResumeUnavailableReason != nil)
            let launch = try await core.commandForResume(descriptor)
            #expect(launch.command.command == "/tools/claude")
            #expect(launch.command.args == ["--resume", id, "--model", "sonnet", "--permission-mode", "plan"])
            #expect(launch.command.env == ["CLAUDE_CONFIG_DIR": root] && launch.unsetEnvironment.isEmpty)
            let encoded = try String(decoding: JSONEncoder().encode(descriptor), as: UTF8.self)
            #expect(!encoded.contains("private prompt") && !encoded.contains("old-id"))
            await #expect(throws: AgentResumeConfigurationError.self) {
                try await core.recoveryDescriptor(sessionID: id, projectPath: "/project", invocation: .init(executable: "/tools/claude", arguments: ["--settings", "/temporary/settings.json"], configurationRoots: ["CLAUDE_CONFIG_DIR": root]))
            }
        }
    }

    @Test("Recovery preserves Claude default/custom configuration semantics and never forks", arguments: [false, true])
    func nativeResume(defaultConfiguration: Bool) async throws {
        let id = UUID().uuidString
        let root = defaultConfiguration
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").resolvingSymlinksInPath().path
            : "/Host/original claude"
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { sessionID, _, layout in
                #expect(sessionID == id && layout == .claude)
                return root
            }
        } operation: {
            let core = ClaudeCodePluginCore()
            try await core.initialize(makeEnv(settings: JSONEncoder().encode(ClaudeCodeSettings(autoRun: false))), host: MockPluginHost())
            let descriptor = try await core.recoveryDescriptor(sessionID: id, projectPath: "/Host/project")
            _ = try await core.applySettings(JSONEncoder().encode(ClaudeCodeSettings(commandPath: "/tools/claude", autoRun: false, additionalConfigFolders: ["/Host/another account"])))
            let resumed = try await withDependencies {
                $0[AgentForkHistoryClient.self].root = { sessionID, roots, _ in
                    #expect(sessionID == id && roots == [root])
                    return root
                }
            } operation: { try await core.commandForResume(descriptor) }
            #expect(resumed.command.command == "/tools/claude")
            #expect(resumed.command.args == ["--resume", id])
            #expect(resumed.command.env == (defaultConfiguration ? [:] : ["CLAUDE_CONFIG_DIR": root]))
            #expect(resumed.unsetEnvironment == (defaultConfiguration ? ["CLAUDE_CONFIG_DIR"] : []))
            await #expect(throws: AgentForkError.self) {
                try await withDependencies {
                    $0[AgentForkHistoryClient.self].root = { _, _, _ in throw AgentForkError("History removed") }
                } operation: { try await core.commandForResume(descriptor) }
            }
            await #expect(throws: AgentForkError.self) { try await core.recoveryDescriptor(sessionID: "--continue", projectPath: "/Host/project") }
            await core.shutdown()
        }
    }

    @Test("Native Fork resumes the exact ID into a new conversation, preserving custom config root with Auto-run off")
    func nativeFork() async throws {
        let id = UUID().uuidString
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { sessionID, roots, layout in
                #expect(sessionID == id)
                #expect(roots.contains("/Host/custom claude"))
                #expect(layout == .claude)
                return "/Host/custom claude"
            }
        } operation: {
            let core = ClaudeCodePluginCore()
            try await core.initialize(makeEnv(settings: JSONEncoder().encode(ClaudeCodeSettings(commandPath: "/tools/my claude", autoRun: false, additionalConfigFolders: ["/Host/custom claude"]))), host: MockPluginHost())
            let fork = try await core.commandForFork(sessionID: id, projectPath: "/Host/new repo")
            let command = fork.command
            #expect(command.command == "/tools/my claude")
            #expect(command.args == ["--resume", id, "--fork-session"])
            #expect(command.env == ["CLAUDE_CONFIG_DIR": "/Host/custom claude"])
            #expect(fork.unsetEnvironment.isEmpty)
            let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").resolvingSymlinksInPath().path
            let defaultCommand = try await withDependencies {
                $0[AgentForkHistoryClient.self].root = { _, _, _ in defaultRoot }
            } operation: { try await core.commandForFork(sessionID: id, projectPath: "/Host/new repo") }
            #expect(defaultCommand.command.env.isEmpty)
            #expect(defaultCommand.unsetEnvironment == ["CLAUDE_CONFIG_DIR"])
            await #expect(throws: AgentForkError.self) { try await core.commandForFork(sessionID: "--continue", projectPath: "/repo") }
            await core.shutdown()
        }
    }

    private func makeEnv(settings: Data = Data()) -> PluginEnv {
        PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ctrlx-cc-core-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settings,
            marketplaceSource: URL(fileURLWithPath: "/")
        )
    }

    @Test("Forking to a custom Claude Provider preserves the source config root and injects Keychain credentials")
    func customProviderFork() async throws {
        let id = UUID().uuidString
        let profile = ClaudeProviderProfile(
            id: "custom",
            name: "Custom Anthropic",
            baseURL: "https://api.example.com/v1",
            model: "claude-custom",
            authKind: .authToken,
            environmentKey: ClaudeProviderAuthKind.authToken.environmentKey,
            reasoningEffort: .high,
            contextWindowTokens: 1_000_000
        )
        let settings = try JSONEncoder().encode(ClaudeCodeSettings(providers: [profile]))
        let secrets = SecretsService.inMemory()
        try await secrets.storeSecret(
            "fixture-key",
            AgentProviderKeychainAccount.account(pluginID: ClaudeCodePluginCore.pluginID, providerID: profile.id)
        )

        try await withDependencies {
            $0[SecretsService.self] = secrets
            $0[AgentForkHistoryClient.self].root = { _, _, layout in
                #expect(layout == .claude)
                return "/source/claude"
            }
        } operation: {
            let core = ClaudeCodePluginCore()
            try await core.initialize(makeEnv(settings: settings), host: MockPluginHost())

            let fork = try await core.commandForFork(sessionID: id, projectPath: "/repo", targetProviderID: profile.id)
            #expect(fork.command.command == "claude")
            #expect(fork.command.args == ["--resume", id, "--fork-session", "--effort", "high"])
            #expect(fork.command.env == [
                "ANTHROPIC_BASE_URL": "https://api.example.com/v1",
                "ANTHROPIC_AUTH_TOKEN": "fixture-key",
                "ANTHROPIC_MODEL": "claude-custom",
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1000000",
                AgentProviderEnvironment.markerKey: profile.id,
                "CLAUDE_CONFIG_DIR": "/source/claude",
            ])
            #expect(Set(fork.unsetEnvironment) == Set([
                "ANTHROPIC_BASE_URL",
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_MODEL",
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
            ]))
        }
    }

    @Test("Custom Claude Provider launch applies its effort and context window")
    func customProviderLaunchEffortAndContextWindow() async throws {
        let profile = ClaudeProviderProfile(
            id: "custom",
            name: "Custom Anthropic",
            baseURL: "https://api.example.com/v1",
            model: "claude-custom",
            authKind: .authToken,
            environmentKey: ClaudeProviderAuthKind.authToken.environmentKey,
            reasoningEffort: .max,
            contextWindowTokens: 500_000
        )
        let settings = try JSONEncoder().encode(ClaudeCodeSettings(providers: [profile], defaultProviderID: profile.id))
        let secrets = SecretsService.inMemory()
        try await secrets.storeSecret(
            "fixture-key",
            AgentProviderKeychainAccount.account(pluginID: ClaudeCodePluginCore.pluginID, providerID: profile.id)
        )

        try await withDependencies {
            $0[SecretsService.self] = secrets
        } operation: {
            let core = ClaudeCodePluginCore()
            try await core.initialize(makeEnv(settings: settings), host: MockPluginHost())
            let launch = try #require(try await core.commandForLaunch(projectPath: "/repo", providerID: nil))
            #expect(launch.args == ["--effort", "max"])
            #expect(launch.env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] == "500000")
            #expect(launch.unsetEnvironment.contains("CLAUDE_CODE_MAX_CONTEXT_TOKENS"))
        }
    }

    @Test("Choosing the official Claude Provider clears inherited API Provider overrides")
    func officialProviderLaunch() async throws {
        let settings = try JSONEncoder().encode(ClaudeCodeSettings(defaultProviderID: ClaudeCodeSettings.builtInProviderID))
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(settings: settings), host: MockPluginHost())

        let launch = try #require(try await core.commandForLaunch(projectPath: "/repo", providerID: nil))
        #expect(launch.env == [AgentProviderEnvironment.markerKey: ClaudeCodeSettings.builtInProviderID])
        #expect(Set(launch.unsetEnvironment) == Set([
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_MODEL",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
        ]))
    }

    @Test("Claude custom Provider launch and Fork reject missing or unknown Providers")
    func providerValidation() async throws {
        let profile = ClaudeProviderProfile(
            id: "custom",
            name: "Custom Anthropic",
            baseURL: "https://api.example.com/v1",
            model: "claude-custom",
            authKind: .apiKey,
            environmentKey: ClaudeProviderAuthKind.apiKey.environmentKey
        )
        let settings = try JSONEncoder().encode(ClaudeCodeSettings(providers: [profile]))

        try await withDependencies {
            $0[SecretsService.self] = .inMemory()
            $0[AgentForkHistoryClient.self].root = { _, _, _ in "/source/claude" }
        } operation: {
            let core = ClaudeCodePluginCore()
            try await core.initialize(makeEnv(settings: settings), host: MockPluginHost())
            await #expect(throws: AgentProviderError.self) {
                try await core.commandForLaunch(projectPath: "/repo", providerID: "removed")
            }
            await #expect(throws: AgentProviderError.self) {
                try await core.commandForFork(sessionID: UUID().uuidString, projectPath: "/repo", targetProviderID: profile.id)
            }
        }
    }

    @Test("Claude recovery records and rebuilds a custom Provider identity")
    func customProviderRecovery() async throws {
        let id = UUID().uuidString
        let profile = ClaudeProviderProfile(
            id: "custom",
            name: "Custom Anthropic",
            baseURL: "https://api.example.com/v1",
            model: "claude-custom",
            authKind: .apiKey,
            environmentKey: ClaudeProviderAuthKind.apiKey.environmentKey,
            reasoningEffort: .high,
            contextWindowTokens: 1_000_000
        )
        let settings = try JSONEncoder().encode(ClaudeCodeSettings(providers: [profile]))
        let secrets = SecretsService.inMemory()
        try await secrets.storeSecret(
            "fixture-key",
            AgentProviderKeychainAccount.account(pluginID: ClaudeCodePluginCore.pluginID, providerID: profile.id)
        )

        try await withDependencies {
            $0[SecretsService.self] = secrets
            $0[AgentForkHistoryClient.self].root = { _, _, _ in "/source/claude" }
        } operation: {
            let core = ClaudeCodePluginCore()
            try await core.initialize(makeEnv(settings: settings), host: MockPluginHost())
            let descriptor = try await core.recoveryDescriptor(
                sessionID: id,
                projectPath: "/repo",
                invocation: .init(
                    executable: "/tools/claude",
                    arguments: ["--effort", "high"],
                    configurationRoots: ["CLAUDE_CONFIG_DIR": "/source/claude"],
                    providerID: profile.id
                )
            )
            #expect(descriptor.providerID == profile.id)
            let resumed = try await core.commandForResume(descriptor)
            #expect(resumed.command.env["ANTHROPIC_API_KEY"] == "fixture-key")
            #expect(resumed.command.env["ANTHROPIC_BASE_URL"] == "https://api.example.com/v1")
            #expect(resumed.command.env["ANTHROPIC_MODEL"] == "claude-custom")
            #expect(resumed.command.env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] == "1000000")
            #expect(resumed.command.env["CLAUDE_CONFIG_DIR"] == "/source/claude")
            #expect(resumed.command.args == ["--resume", id, "--effort", "high"])
        }
    }

    @Test("pluginID is claude-code")
    func pluginID() {
        #expect(ClaudeCodePluginCore.pluginID == "claude-code")
    }

    @Test("initialize pushes a project list to the host")
    func initializePushesProjects() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)
        let calls = await host.projectsCalls
        // At least one setProjects call happened during the initial scan.
        #expect(calls.count >= 1)
    }

    @Test("refreshProjects pushes again")
    func refreshPushesProjects() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)
        let before = await host.projectsCalls.count
        await core.refreshProjects()
        let after = await host.projectsCalls.count
        #expect(after == before + 1)
    }

    @Test("commandForLaunch returns the configured command when autoRun is on")
    func commandForLaunchEnabled() async throws {
        let settings = try JSONEncoder().encode(
            ClaudeCodeSettings(commandPath: "/opt/claude", autoRun: true)
        )
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "/opt/claude")
    }

    @Test("commandForLaunch declines when autoRun is off")
    func commandForLaunchDisabled() async throws {
        let settings = try JSONEncoder().encode(
            ClaudeCodeSettings(commandPath: "/opt/claude", autoRun: false)
        )
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch == nil)
    }

    @Test("applySettings updates the launch command")
    func applySettingsUpdatesLaunch() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)

        let newSettings = try JSONEncoder().encode(
            ClaudeCodeSettings(commandPath: "/new/claude", autoRun: true)
        )
        let result = await core.applySettings(newSettings)
        guard case .applied = result else {
            Issue.record("expected .applied")
            return
        }
        let launch = await core.commandForLaunch(projectPath: "/x")
        #expect(launch?.command == "/new/claude")
    }

    @Test("shutdown is safe to call and stops delivery")
    func shutdownStopsDelivery() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)
        await core.shutdown()

        // After shutdown the host reference is cleared, so delivery is a no-op.
        await core.deliverResponse(sessionID: "s", requestID: "r", .prompt(text: "hi"))
        let texts = await host.sentText
        #expect(texts.isEmpty)
    }
}
