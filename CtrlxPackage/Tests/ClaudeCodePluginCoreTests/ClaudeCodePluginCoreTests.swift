import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Lifecycle + auto-launch behavior of the core itself (the pieces not covered
/// by the translator / keystroke / scanner / installer suites).
@Suite("ClaudeCodePluginCore")
struct ClaudeCodePluginCoreTests {
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
