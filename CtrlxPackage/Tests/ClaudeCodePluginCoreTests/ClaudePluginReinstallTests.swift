import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore

@Suite("Claude plugin reinstall")
struct ClaudePluginReinstallTests {
    private actor Recorder {
        var calls: [[String]] = []
        func append(_ call: [String]) {
            calls.append(call)
        }
    }

    @Test("Reinstall is user-scoped, preserves plugin data and verifies version", arguments: ["1.3.2", "1.3.3"])
    func reinstalls(target: String) async throws {
        let recorder = Recorder()
        let installer = ClaudeCodeCLIInstaller(processRunner: ProcessRunner { _, args, env, _ in
            #expect(env == ["CLAUDE_CONFIG_DIR": "/isolated/claude"])
            await recorder.append(args)
            let output = args.contains("marketplace")
                ? #"[{"name":"ctrlx","path":"/bundle/plugin"}]"#
                : #"[{"id":"ctrlx@ctrlx","version":"\#(target)","scope":"user"}]"#
            return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        }, command: "claude", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin"))
        let status = try await withDependencies {
            $0[AgentPluginResourceClient.self].version = { _ in target }
        } operation: { try await installer.reinstall(configRoot: "/isolated/claude") }
        #expect(status == .installed(version: target))
        #expect(await recorder.calls == [
            ["claude", "plugin", "marketplace", "add", "/bundle/plugin"],
            ["claude", "plugin", "marketplace", "list", "--json"],
            ["claude", "plugin", "marketplace", "update", "ctrlx"],
            ["claude", "plugin", "list", "--json"],
            ["claude", "plugin", "uninstall", "ctrlx@ctrlx", "--scope", "user", "--keep-data"],
            ["claude", "plugin", "install", "ctrlx@ctrlx", "--scope", "user"],
            ["claude", "plugin", "list", "--json"],
        ])
    }

    @Test("Preparation or removal failure never continues to install", arguments: ["source", "check", "uninstall"])
    func preparationFailure(mode: String) async {
        let recorder = Recorder()
        let installer = ClaudeCodeCLIInstaller(processRunner: ProcessRunner { _, args, _, _ in
            await recorder.append(args)
            let root = mode == "source" ? "/wrong" : "/bundle/plugin"
            let output = args.contains("marketplace")
                ? #"[{"name":"ctrlx","path":"\#(root)"}]"#
                : #"[{"id":"ctrlx@ctrlx","version":"1.3.1","scope":"user"}]"#
            let fail = (mode == "check" && args == ["claude", "plugin", "list", "--json"]) || args.contains("uninstall")
            return ProcessResult(exitCode: fail ? 1 : 0, stdout: Data(output.utf8), stderr: Data("failed".utf8))
        }, command: "claude", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin"))
        await withDependencies {
            $0[AgentPluginResourceClient.self].version = { _ in "1.3.2" }
        } operation: {
            await #expect(throws: (any Error).self) { _ = try await installer.reinstall(configRoot: nil) }
        }
        #expect(await recorder.calls.allSatisfy { !$0.contains("install") })
        if mode != "uninstall" { #expect(await recorder.calls.allSatisfy { !$0.contains("uninstall") }) }
    }

    @Test("Project-scoped installation does not mask missing user installation")
    func projectScope() {
        #expect(ClaudeCodeCLIInstaller.parseStatus(from: #"[{"id":"ctrlx@ctrlx","version":"1.3.2","scope":"project"}]"#) == .notInstalled)
    }

    @Test("Install and verification failures report partial reinstall for retry", arguments: [true, false])
    func installFailure(failsCommand: Bool) async {
        let recorder = Recorder()
        let installer = ClaudeCodeCLIInstaller(processRunner: ProcessRunner { _, args, _, _ in
            await recorder.append(args)
            let output = args.contains("marketplace")
                ? #"[{"name":"ctrlx","path":"/bundle/plugin"}]"#
                : #"[{"id":"ctrlx@ctrlx","version":"1.0.0","scope":"user"}]"#
            return ProcessResult(exitCode: failsCommand && args.contains("install") ? 1 : 0, stdout: Data(output.utf8), stderr: Data("install failed".utf8))
        }, command: "claude", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin"))
        await withDependencies {
            $0[AgentPluginResourceClient.self].version = { _ in "1.3.2" }
        } operation: {
            do {
                _ = try await installer.reinstall(configRoot: nil)
                Issue.record("Unexpected successful reinstall")
            } catch {
                #expect(error.localizedDescription.contains("previous copy may have been removed"))
                #expect(error.localizedDescription.contains("Retry"))
            }
        }
        #expect(await recorder.calls.contains { $0.contains("uninstall") })
        #expect(await recorder.calls.contains { $0.contains("install") })
    }

    @Test("Timeout remains a check error")
    func failedCheck() async {
        let installer = ClaudeCodeCLIInstaller(processRunner: ProcessRunner { _, _, _, _ in throw ProcessRunnerError.timeout }, command: "claude", marketplaceSource: URL(fileURLWithPath: "/bundle"))
        #expect(await installer.installStatus(configRoot: nil) == .checkFailed(message: ProcessRunnerError.timeout.localizedDescription))
    }

    @Test("Failed checks include the exit code when the CLI has no diagnostic", arguments: ["", " \n"])
    func emptyCheckDiagnostic(stderr: String) async {
        let installer = ClaudeCodeCLIInstaller(processRunner: ProcessRunner { _, _, _, _ in
            ProcessResult(exitCode: 2, stdout: Data(), stderr: Data(stderr.utf8))
        }, command: "claude", marketplaceSource: URL(fileURLWithPath: "/bundle"))
        #expect(await installer.installStatus(configRoot: nil) == .checkFailed(message: "Claude Code CLI exited with code 2."))
    }
}
