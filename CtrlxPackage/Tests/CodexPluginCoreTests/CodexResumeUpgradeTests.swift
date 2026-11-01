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
            executable: "/removed/codex", cliVersion: "codex-cli 0.166.0",
            automaticResumeUnavailableReason: "Automatic resume has not been verified for Codex codex-cli 0.166.0."
        )
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "codex-cli 0.166.0") == nil)
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "codex-cli 0.999.0") != nil)
        #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: nil) != nil)
        let incomplete = AgentResumeDescriptor(pluginID: "codex", sessionID: saved.sessionID, projectPath: saved.projectPath, configurationRoot: saved.configurationRoot, usesDefaultConfiguration: false)
        #expect(await core.automaticResumeUnavailableReason(incomplete, currentVersion: "codex-cli 0.166.0") != nil)
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
            #expect(await core.automaticResumeUnavailableReason(saved, currentVersion: "codex-cli 0.166.0") == nil)
        }
    }
}
