import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeResumeUpgradeTests {
    @Test("Recovery reevaluates legacy warnings and CLI upgrades through the plugin contract", arguments: ["2.1.276 (Claude Code)", "2.1.308 (Claude Code)", "2.1.319 (Claude Code)"])
    func legacyWarning(version: String) async {
        let core: any AgentSessionResuming = ClaudeCodePluginCore()
        let saved = AgentResumeDescriptor(
            pluginID: "claude-code", sessionID: UUID().uuidString, projectPath: "/project", configurationRoot: "/original/claude", usesDefaultConfiguration: false,
            executable: "/removed/claude", cliVersion: version,
            automaticResumeUnavailableReason: version == "2.1.276 (Claude Code)" ? nil : "Automatic resume has not been verified for Claude Code \(version)."
        )
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "2.1.319 (Claude Code)") == nil)
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "2.1.320 (Claude Code)") != nil)
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: nil) != nil)
        let incomplete = AgentResumeDescriptor(pluginID: "claude-code", sessionID: saved.sessionID, projectPath: saved.projectPath, configurationRoot: saved.configurationRoot, usesDefaultConfiguration: false)
        #expect(await core.automaticResumeUnavailableReason(incomplete, currentVersion: "2.1.319 (Claude Code)") != nil)
    }

    @Test("Unsupported Claude versions remain available for manual resume only")
    func unsupportedVersions() async throws {
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in try #require(roots.first) }
        } operation: {
            let core = ClaudeCodePluginCore()
            for version: String? in [
                nil, "", "2.1.276 (Claude Code)", "2.1.299 (Claude Code)", "2.1.320 (Claude Code)", "3.1.308 (Claude Code)",
                "2.1.308-beta (Claude Code)", "2.1.308+build (Claude Code)", "2.1.0308 (Claude Code)", "2.1.308",
            ] {
                let descriptor = try await core.recoveryDescriptor(
                    sessionID: UUID().uuidString, projectPath: "/project",
                    invocation: .init(executable: "/tools/claude", arguments: [], version: version)
                )
                let reason = await core.automaticResumeUnavailableReason(descriptor, currentVersion: version)
                #expect(reason?.contains("2.1.300–2.1.319") == true)
                #expect(descriptor.automaticResumeUnavailableReason == reason)
                #expect(try await core.commandForResume(descriptor).command.args == ["--resume", descriptor.sessionID])
                #expect(await core.automaticResumeUnavailableReason(descriptor, currentVersion: "2.1.319 (Claude Code)") == nil)
            }
        }
    }

    @Test("A replacement Claude CLI preserves the exact conversation, configuration root and options")
    func replacementCommand() async throws {
        let saved = AgentResumeDescriptor(
            pluginID: "claude-code", sessionID: UUID().uuidString, projectPath: "/project", configurationRoot: "/original/claude", usesDefaultConfiguration: false,
            executable: "/removed/claude", cliVersion: "2.1.300 (Claude Code)", arguments: ["--model", "sonnet", "--permission-mode", "plan"],
            automaticResumeUnavailableReason: nil
        )
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { id, roots, _ in
                #expect(id == saved.sessionID && roots == [saved.configurationRoot])
                return saved.configurationRoot
            }
            $0[AgentResumeExecutableClient.self].resolve = { recorded, _ in
                #expect(recorded == saved.executable)
                return "/installed/claude"
            }
        } operation: {
            let core = ClaudeCodePluginCore()
            let launch = try await core.commandForResume(saved)
            #expect(launch.command.command == "/installed/claude")
            #expect(launch.command.args == ["--resume", saved.sessionID] + saved.arguments)
            #expect(launch.command.env == ["CLAUDE_CONFIG_DIR": saved.configurationRoot])
            #expect(launch.unsetEnvironment.isEmpty)
            #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "2.1.319 (Claude Code)") == nil)
        }
    }
}
