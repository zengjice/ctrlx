import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

struct CodexResumeUpgradeTests {
    @Test("Legacy version warnings are reevaluated using the CLI that will actually run")
    func legacyWarning() async {
        let core = CodexPluginCore()
        let saved = AgentResumeDescriptor(
            pluginID: "codex", sessionID: UUID().uuidString, projectPath: "/project", configurationRoot: "/original/codex", usesDefaultConfiguration: false,
            executable: "/removed/codex", cliVersion: "codex-cli 0.167.0",
            automaticResumeUnavailableReason: "Automatic resume has not been verified for Codex codex-cli 0.167.0."
        )
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "codex-cli 0.167.0") == nil)
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "codex-cli 0.999.0") != nil)
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: nil) != nil)
        let incomplete = AgentResumeDescriptor(pluginID: "codex", sessionID: saved.sessionID, projectPath: saved.projectPath, configurationRoot: saved.configurationRoot, usesDefaultConfiguration: false)
        #expect(await core.automaticResumeUnavailableReason(incomplete, currentVersion: "codex-cli 0.167.0") != nil)
    }

    @Test("Unsupported Codex versions remain available for manual resume only")
    func unsupportedVersions() async throws {
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { _, roots, _ in try #require(roots.first) }
        } operation: {
            let core = CodexPluginCore()
            for version: String? in [
                nil, "", "codex-cli 0.159.99", "codex-cli 0.170.0", "codex-cli 1.160.0",
                "codex-cli 0.167.0-beta", "codex-cli 0.167.0+build", "codex-cli 0.167.01", "0.167.0",
            ] {
                let descriptor = try await core.recoveryDescriptor(
                    sessionID: UUID().uuidString, projectPath: "/project",
                    invocation: .init(executable: "/tools/codex", arguments: [], version: version)
                )
                let reason = await core.automaticResumeUnavailableReason(descriptor, currentVersion: version)
                #expect(reason?.contains("0.160.x–0.169.x") == true)
                #expect(descriptor.automaticResumeUnavailableReason == reason)
                #expect(core.workflowRuntimeIssue(cliVersion: version) != nil)
                let command = try await core.commandForResume(descriptor).command
                #expect(Array(command.args.prefix(2)) == ["resume", descriptor.sessionID])
                #expect(await core.automaticResumeUnavailableReason(descriptor, currentVersion: "codex-cli 0.167.0") == nil)
            }
        }
    }

    @Test("A replacement CLI resumes the exact recorded history, account root and options")
    func replacementCommand() async throws {
        let saved = AgentResumeDescriptor(
            pluginID: "codex", sessionID: UUID().uuidString, projectPath: "/project", configurationRoot: "/original/codex", usesDefaultConfiguration: false,
            executable: "/removed/codex", arguments: ["--profile", "work", "--sandbox", "read-only"]
        )
        try await withDependencies {
            $0[AgentForkHistoryClient.self].root = { id, roots, _ in
                #expect(id == saved.sessionID && roots == [saved.configurationRoot])
                return saved.configurationRoot
            }
            $0[AgentResumeExecutableClient.self].resolve = { recorded, _ in
                #expect(recorded == saved.executable)
                return "/installed/codex"
            }
        } operation: {
            let core = CodexPluginCore()
            let command = try await core.commandForResume(saved).command
            #expect(command.command == "/installed/codex")
            #expect(command.args == ["resume", saved.sessionID, "-C", saved.projectPath] + saved.arguments + ["--dangerously-bypass-hook-trust", "--no-daemon"])
            #expect(command.env["CODEX_HOME"] == saved.configurationRoot)
            #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "codex-cli 0.167.0") == nil)
        }
    }
}
