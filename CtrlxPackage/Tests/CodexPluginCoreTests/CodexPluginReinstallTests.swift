import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore

@Suite("Codex plugin reinstall")
struct CodexPluginReinstallTests {
    private actor Recorder {
        var calls: [[String]] = []
        func append(_ call: [String]) {
            calls.append(call)
        }
    }

    @Test("Add refreshes an installed version without an uninstall gap", arguments: ["1.1.1", "1.1.2"])
    func reinstalls(target: String) async throws {
        let recorder = Recorder()
        let installer = CodexCLIInstaller(processRunner: ProcessRunner { _, args, env, _ in
            #expect(env == ["CODEX_HOME": "/isolated/codex"])
            await recorder.append(args)
            let output: String
            if args.contains("--json") {
                output = #"{"marketplaces":[{"name":"ctrlx","root":"/bundle/plugin"}]}"#
            } else if args.contains("list") {
                output = "ctrlx@ctrlx installed, enabled \(target) /bundle/plugin/ctrlx"
            } else {
                output = "Added"
            }
            return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        }, command: "codex", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin"))
        let status = try await withDependencies {
            $0[AgentPluginResourceClient.self].version = { _ in target }
        } operation: { try await installer.reinstall(configRoot: "/isolated/codex") }
        #expect(status == .installed(version: target))
        #expect(await recorder.calls == [
            ["codex", "plugin", "marketplace", "add", "/bundle/plugin"],
            ["codex", "plugin", "marketplace", "list", "--json"],
            ["codex", "plugin", "add", "ctrlx@ctrlx"],
            ["codex", "plugin", "list", "-m", "ctrlx"],
        ])
    }

    @Test("Wrong source, stale version and already-installed are not reinstall success", arguments: ["source", "version", "already", "failure"])
    func rejectsUnverified(mode: String) async {
        let recorder = Recorder()
        let installer = CodexCLIInstaller(processRunner: ProcessRunner { _, args, _, _ in
            await recorder.append(args)
            var output = "Added"
            if args.contains("--json") {
                let root = mode == "source" ? "/other/source" : "/bundle/plugin"
                output = #"{"marketplaces":[{"name":"ctrlx","root":"\#(root)"}]}"#
            } else if args.contains("list") {
                output = "ctrlx@ctrlx installed 1.0.0 /bundle/plugin"
            }
            if args == ["codex", "plugin", "add", "ctrlx@ctrlx"], mode == "already" {
                output = "Already installed"
            }
            return ProcessResult(exitCode: mode == "failure" ? 1 : 0, stdout: Data(output.utf8), stderr: Data("failed".utf8))
        }, command: "codex", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin"))
        await withDependencies {
            $0[AgentPluginResourceClient.self].version = { _ in "1.1.2" }
        } operation: {
            await #expect(throws: (any Error).self) { _ = try await installer.reinstall(configRoot: nil) }
        }
        #expect(await recorder.calls.allSatisfy { !$0.contains("remove") })
        if mode == "source" {
            #expect(await recorder.calls.count == 2)
        }
    }

    @Test(
        "Failed marketplace queries preserve the exit code and stderr before decoding stdout",
        arguments: ["", #"{"marketplaces":[{"name":"ctrlx","root":"/bundle/plugin"}]}"#],
        ["error: unexpected argument '--json' found", ""]
    )
    func failedMarketplaceQuery(stdout: String, stderr: String) async {
        let recorder = Recorder()
        let installer = CodexCLIInstaller(processRunner: ProcessRunner { _, args, _, _ in
            await recorder.append(args)
            if args.contains("--json") {
                return ProcessResult(exitCode: 2, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
            }
            return ProcessResult(exitCode: 0, stdout: Data("Added".utf8), stderr: Data())
        }, command: "codex", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin"))
        await withDependencies {
            $0[AgentPluginResourceClient.self].version = { _ in "1.1.7" }
        } operation: {
            do {
                _ = try await installer.reinstall(configRoot: "/isolated/codex")
                Issue.record("Unexpected successful reinstall")
            } catch let ProcessRunnerError.executionFailed(exitCode, diagnostic) {
                #expect(exitCode == 2)
                #expect(diagnostic == stderr)
            } catch {
                Issue.record("The marketplace command error was replaced by \(error)")
            }
        }
        #expect(await recorder.calls == [
            ["codex", "plugin", "marketplace", "add", "/bundle/plugin"],
            ["codex", "plugin", "marketplace", "list", "--json"],
        ])
    }

    @Test("Malformed marketplace responses explain the failed command and stop before replacement", arguments: [
        "", "not JSON", "[]", #"{"marketplaces":[{"name":"ctrlx"}]}"#,
        #"{"marketplaces":[{"name":"ctrlx","root":7}]}"#,
    ])
    func malformedMarketplaceQuery(stdout: String) async {
        let recorder = Recorder()
        let installer = CodexCLIInstaller(processRunner: ProcessRunner { _, args, _, _ in
            await recorder.append(args)
            return ProcessResult(exitCode: 0, stdout: Data((args.contains("--json") ? stdout : "Added").utf8), stderr: Data())
        }, command: "codex", marketplaceSource: URL(fileURLWithPath: "/bundle/plugin"))
        await withDependencies {
            $0[AgentPluginResourceClient.self].version = { _ in "1.1.7" }
        } operation: {
            do {
                _ = try await installer.reinstall(configRoot: "/isolated/codex")
                Issue.record("Unexpected successful reinstall")
            } catch let error as AgentPluginInstallError {
                #expect(error.message.contains("plugin marketplace list --json"))
                #expect(error.message.contains("Expected a JSON marketplace list with name and root fields"))
                #expect(error.message.contains("The existing plugin was not replaced"))
            } catch {
                Issue.record("Missing actionable marketplace error: \(error)")
            }
        }
        #expect(await recorder.calls == [
            ["codex", "plugin", "marketplace", "add", "/bundle/plugin"],
            ["codex", "plugin", "marketplace", "list", "--json"],
        ])
    }

    @Test("Timeout remains a check error, not a missing CLI")
    func failedCheck() async {
        let installer = CodexCLIInstaller(processRunner: ProcessRunner { _, _, _, _ in throw ProcessRunnerError.timeout }, command: "codex", marketplaceSource: URL(fileURLWithPath: "/bundle"))
        #expect(await installer.installStatus(configRoot: nil) == .checkFailed(message: ProcessRunnerError.timeout.localizedDescription))
    }

    @Test("Malformed list is unknown and fresh-root empty list is not installed")
    func listing() {
        #expect(CodexCLIInstaller.parseStatus(from: "No plugins found in marketplace `ctrlx`.") == .notInstalled)
        #expect(CodexCLIInstaller.parseStatus(from: "not a plugin table") == .checkFailed(message: "Codex returned an unrecognized plugin list."))
        #expect(CodexCLIInstaller.parseStatus(from: "PLUGIN STATUS VERSION\nnot-ctrlx@ctrlx installed 1.0.0") == .notInstalled)
    }

    @Test("Failed checks include the exit code when the CLI has no diagnostic", arguments: ["", " \n"])
    func emptyCheckDiagnostic(stderr: String) async {
        let installer = CodexCLIInstaller(processRunner: ProcessRunner { _, _, _, _ in
            ProcessResult(exitCode: 2, stdout: Data(), stderr: Data(stderr.utf8))
        }, command: "codex", marketplaceSource: URL(fileURLWithPath: "/bundle"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-missing-\(UUID())")
        #expect(await installer.installStatus(configRoot: root.path) == .checkFailed(message: "Codex CLI exited with code 2."))
    }
}
