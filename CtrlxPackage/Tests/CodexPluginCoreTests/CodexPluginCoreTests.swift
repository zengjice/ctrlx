import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

/// Lifecycle + auto-launch behavior of the core itself (the pieces not covered
/// by the translator / keystroke / scanner / installer / correlation suites).
struct CodexPluginCoreTests {
    @Test("Verified Codex recovery binds automatic support to the recorded CLI version and disables shared daemon")
    func nativeResumeVerifiedVersion() async throws {
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in try #require(roots.first) }
        } operation: {
            let core = makeCore()
            let descriptor = try await core.recoveryDescriptor(sessionID: UUID().uuidString, projectPath: "/project", invocation: .init(executable: "/tools/codex", arguments: [], version: "codex-cli 0.162.1"))
            #expect(descriptor.automaticResumeUnavailableReason == nil)
            #expect(descriptor.cliVersion == "codex-cli 0.162.1")
            #expect(try await core.commandForResume(descriptor).command.args.last == "--no-daemon")
        }
    }

    @Test("Native recovery records the observed config/profile/permissions but excludes prompts, images and old telemetry")
    func nativeResumeInvocation() async throws {
        let id = UUID().uuidString
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in
                #expect(roots == ["/original/account"])
                return "/original/account"
            }
        } operation: {
            let core = makeCore()
            let invocation = AgentResumeInvocation(executable: "/tools/codex", arguments: ["resume", "old-id", "secret prompt", "-p", "work", "-s", "read-only", "-a", "on-request", "-c", "model_reasoning_effort=high", "-c", "otel.log_user_prompt=false", "--image", "/secret/image.png"], configurationRoots: ["CODEX_HOME": "/original/account"], version: "fixture-version")
            let descriptor = try await core.recoveryDescriptor(sessionID: id, projectPath: "/project", invocation: invocation)
            #expect(descriptor.arguments == ["--profile", "work", "--sandbox", "read-only", "--ask-for-approval", "on-request", "--config", "model_reasoning_effort=high"])
            #expect(descriptor.automaticResumeUnavailableReason != nil)
            let encoded = try String(decoding: JSONEncoder().encode(descriptor), as: UTF8.self)
            #expect(!encoded.contains("secret") && !encoded.contains("old-id") && !encoded.contains("otel"))
            let launch = try await core.commandForResume(descriptor)
            #expect(launch.command.command == "/tools/codex")
            #expect(launch.command.args == ["resume", id, "-C", "/project"] + descriptor.arguments)
            await #expect(throws: AgentResumeConfigurationError.self) {
                try await core.recoveryDescriptor(sessionID: id, projectPath: "/project", invocation: .init(executable: "/tools/codex", arguments: ["--remote", "unix:///private/agent.sock"], configurationRoots: ["CODEX_HOME": "/original/account"]))
            }
        }
    }

    @Test("Recovery resumes the recorded Codex identity/root without a prompt or Auto-run")
    func nativeResume() async throws {
        let id = UUID().uuidString
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { sessionID, _, layout in
                #expect(sessionID == id && layout == .codex)
                return "/Host/original codex"
            }
        } operation: {
            let core = makeCore()
            try await core.initialize(makeEnv(settings: JSONEncoder().encode(CodexSettings(autoRun: false, exportTelemetry: false))), host: MockPluginHost())
            let descriptor = try await core.recoveryDescriptor(sessionID: id, projectPath: "/Host/project")
            _ = try await core.applySettings(JSONEncoder().encode(CodexSettings(commandPath: "/tools/codex", autoRun: false, additionalConfigFolders: ["/Host/another account"], exportTelemetry: false)))
            let resumed = try await withDependencies {
                $0[AgentForkHistoryClient.self].root = { sessionID, roots, _ in
                    #expect(sessionID == id && roots == ["/Host/original codex"])
                    return "/Host/original codex"
                }
            } operation: { try await core.commandForResume(descriptor) }
            #expect(resumed.command.command == "/tools/codex")
            #expect(resumed.command.args == ["resume", id, "-C", "/Host/project"])
            #expect(resumed.command.env == ["CODEX_HOME": "/Host/original codex"])
            await #expect(throws: AgentForkError.self) {
                try await withDependencies {
                    $0[AgentForkHistoryClient.self].root = { _, _, _ in throw AgentForkError("History removed") }
                } operation: { try await core.commandForResume(descriptor) }
            }
            await #expect(throws: AgentForkError.self) { try await core.recoveryDescriptor(sessionID: "--last", projectPath: "/Host/project") }
            await core.shutdown()
        }
    }

    @Test("Native Fork uses the exact ID and target cwd, preserves config root and telemetry, independent of Auto-run")
    func nativeFork() async throws {
        let id = UUID().uuidString
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { sessionID, _, layout in
                #expect(sessionID == id)
                #expect(layout == .codex)
                return "/Host/custom codex"
            }
        } operation: {
            let core = makeCore()
            try await core.initialize(makeEnv(settings: JSONEncoder().encode(CodexSettings(commandPath: "/tools/my codex", autoRun: false)), otlpEndpoint: URL(string: "http://127.0.0.1:4318")), host: MockPluginHost())
            let fork = try await core.commandForFork(sessionID: id, projectPath: "/Host/new repo")
            let command = fork.command
            #expect(command.command == "/tools/my codex")
            #expect(Array(command.args.prefix(4)) == ["fork", id, "-C", "/Host/new repo"])
            #expect(command.args.contains("otel.log_user_prompt=false"))
            #expect(command.env == ["CODEX_HOME": "/Host/custom codex"])
            #expect(fork.unsetEnvironment.isEmpty)
            _ = try await core.applySettings(JSONEncoder().encode(CodexSettings(autoRun: false, exportTelemetry: false)))
            let withoutTelemetry = try await core.commandForFork(sessionID: id, projectPath: "/Host/new repo")
            #expect(withoutTelemetry.command.args == ["fork", id, "-C", "/Host/new repo"])
            await #expect(throws: AgentForkError.self) { try await core.commandForFork(sessionID: "--last", projectPath: "/repo") }
            await core.shutdown()
        }
    }

    private func makeEnv(settings: Data = Data(), otlpEndpoint: URL? = nil) -> PluginEnv {
        PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ctrlx-cx-core-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settings,
            marketplaceSource: URL(fileURLWithPath: "/"),
            otlpReceiverEndpoint: otlpEndpoint
        )
    }

    /// A core whose correlation store points at a throwaway temp dir so tests
    /// never touch the real `~/.ctrlx/codex-sessions/`.
    private func makeCore() -> CodexPluginCore {
        let correlationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctrlx-cx-core-corr-\(UUID().uuidString)")
        return CodexPluginCore(correlation: CodexSessionCorrelation(root: correlationRoot))
    }

    @Test("pluginID is codex")
    func pluginID() {
        #expect(CodexPluginCore.pluginID == "codex")
    }

    @Test("initialize pushes a project list to the host")
    func initializePushesProjects() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)
        let calls = await host.projectsCalls
        // At least one setProjects call happened during the initial scan.
        #expect(calls.count >= 1)
    }

    @Test("refreshProjects pushes again")
    func refreshPushesProjects() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)
        let before = await host.projectsCalls.count
        await core.refreshProjects()
        let after = await host.projectsCalls.count
        #expect(after == before + 1)
    }

    @Test("commandForLaunch returns the configured command when autoRun is on")
    func commandForLaunchEnabled() async throws {
        let settings = try JSONEncoder().encode(
            CodexSettings(commandPath: "/opt/codex", autoRun: true)
        )
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "/opt/codex")
    }

    @Test("commandForLaunch appends -c otel overrides when a receiver endpoint is present")
    func commandForLaunchInjectsOtel() async throws {
        let settings = try JSONEncoder().encode(CodexSettings(commandPath: "codex", autoRun: true))
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(
            makeEnv(settings: settings, otlpEndpoint: URL(string: "http://127.0.0.1:4318")),
            host: host
        )

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "codex")
        let args = launch?.args ?? []
        #expect(args.contains("-c"))
        #expect(args.contains(#"otel.exporter.otlp-http.endpoint="http://127.0.0.1:4318/v1/logs""#))
        #expect(args.contains(#"otel.log_user_prompt=false"#))
    }

    @Test("commandForLaunch omits otel overrides when exportTelemetry is off")
    func commandForLaunchRespectsTelemetryOptOut() async throws {
        let settings = try JSONEncoder().encode(
            CodexSettings(commandPath: "codex", autoRun: true, exportTelemetry: false)
        )
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(
            makeEnv(settings: settings, otlpEndpoint: URL(string: "http://127.0.0.1:4318")),
            host: host
        )

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "codex")
        #expect(launch?.args.isEmpty == true)
    }

    @Test("commandForLaunch omits otel overrides when no receiver endpoint is available")
    func commandForLaunchNoEndpoint() async throws {
        let settings = try JSONEncoder().encode(CodexSettings(commandPath: "codex", autoRun: true))
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(settings: settings), host: host) // no endpoint

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.args.isEmpty == true)
    }

    @Test("commandForLaunch declines when autoRun is off")
    func commandForLaunchDisabled() async throws {
        let settings = try JSONEncoder().encode(
            CodexSettings(commandPath: "/opt/codex", autoRun: false)
        )
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch == nil)
    }

    @Test("Manual telemetry shares UI defaults but is independent of Auto-run")
    func terminalTelemetry() async throws {
        let core = makeCore()
        let endpoint = URL(string: "http://127.0.0.1:54321")
        try await core.initialize(makeEnv(otlpEndpoint: endpoint), host: MockPluginHost())
        let automatic = await core.commandForLaunch(projectPath: "/fixture")
        #expect(await core.terminalTelemetryArguments() == automatic?.args)
        _ = try await core.applySettings(JSONEncoder().encode(CodexSettings(autoRun: false)))
        #expect(await core.commandForLaunch(projectPath: "/fixture") == nil)
        #expect(await core.terminalTelemetryArguments() == automatic?.args)
        _ = try await core.applySettings(JSONEncoder().encode(CodexSettings(exportTelemetry: false)))
        #expect(await core.terminalTelemetryArguments().isEmpty)
        await core.shutdown()
    }

    @Test("applySettings updates the launch command")
    func applySettingsUpdatesLaunch() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)

        let newSettings = try JSONEncoder().encode(
            CodexSettings(commandPath: "/new/codex", autoRun: true)
        )
        let result = await core.applySettings(newSettings)
        guard case .applied = result else {
            Issue.record("expected .applied")
            return
        }
        let launch = await core.commandForLaunch(projectPath: "/x")
        #expect(launch?.command == "/new/codex")
    }

    @Test("shutdown is safe to call and stops delivery")
    func shutdownStopsDelivery() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)
        await core.shutdown()

        // After shutdown the host reference is cleared, so delivery is a no-op.
        await core.deliverResponse(sessionID: "s", requestID: "r", .prompt(text: "hi"))
        let texts = await host.sentText
        #expect(texts.isEmpty)
    }
}
