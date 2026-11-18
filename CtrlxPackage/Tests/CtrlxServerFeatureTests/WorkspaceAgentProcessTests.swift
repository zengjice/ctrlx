import ClaudeCodePluginCore
import CodexPluginCore
import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct WorkspaceAgentProcessTests {
    @Test("Version discovery accepts Traex's installation line without hiding unknown output")
    func versionOutput() async {
        let cases: [(String, Int32, String?)] = [
            ("codex-cli 0.167.0\n", 0, "codex-cli 0.167.0"),
            ("2.1.308 (Claude Code)\n", 0, "2.1.308 (Claude Code)"),
            ("traecli 0.213.1\ninstallation: public\n", 0, "traecli 0.213.1"),
            ("traecli 0.214.0\ninstallation: public\n", 0, "traecli 0.214.0"),
            ("traecli 0.213.1\ninstallation: public\nextra output\n", 0, nil),
            ("traecli 0.213.1\nunrecognized diagnostic\n", 0, nil),
            ("codex-cli 0.167.0\ninstallation: public\n", 0, nil),
            ("traecli 0.213.1\ninstallation: public\n", 1, nil),
        ]
        for (output, exitCode, expected) in cases {
            await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    #expect(arguments == ["--version"])
                    return .init(exitCode: exitCode, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let version = await WorkspaceAgentProcessClient.liveValue.version("/fixture/\(UUID())/agent")
                #expect(version == expected)
                if let version, version.hasPrefix("traecli ") {
                    let core = CodexPluginCore(distribution: .traex)
                    #expect((core.workflowRuntimeIssue(cliVersion: version) == nil) == (version == "traecli 0.213.1"))
                }
            }
        }
    }

    @Test("Native Traex multiline version reaches model and automatic-resume admission", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_TRAEX_NATIVE_TESTS"] == "1"))
    func nativeTraexVersion() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(environment["CTRLX_TRAEX_TEST_EXECUTABLE"]
            ?? (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/traex" }
            .first { FileManager.default.isExecutableFile(atPath: $0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-traex-version-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0[ProcessRunner.self].run = { path, arguments, _, timeout in
                try await ProcessRunner.liveValue.run(path, arguments, [
                    "HOME": root.path, "TRAE_HOME": root.path,
                    "TRAEX_AUTO_UPDATE_ON_STARTUP": "0", "TRAECLI_AUTO_UPDATE_ON_STARTUP": "0",
                ], timeout)
            }
            $0[AgentForkHistoryClient.self].root = { _, _, _ in root.path }
        } operation: {
            let version = try #require(await WorkspaceAgentProcessClient.liveValue.version(executable))
            #expect(version == "traecli 0.213.1")
            let core = CodexPluginCore(distribution: .traex)
            #expect(core.workflowRuntimeIssue(cliVersion: version) == nil)
            let context = AgentModelContext(invocation: .init(executable: executable, arguments: [], version: version), environment: [:], directory: root.path)
            #expect(core.modelRuntimeIssue(context) == nil)
            let descriptor = try await core.recoveryDescriptor(sessionID: UUID().uuidString, projectPath: root.path, invocation: context.invocation)
            #expect(descriptor.automaticResumeUnavailableReason == nil)
            #expect(await core.automaticResumeUnavailableReason(descriptor, currentVersion: version) == nil)
        }
    }

    @Test("Removing the running executable preserves identity and workflow version admission", arguments: ["codex", "claude-code"])
    func removedExecutable(pluginID: String) async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let provider: any AgentWorkflowProviding = pluginID == "codex" ? CodexPluginCore() : ClaudeCodePluginCore()
            let version = pluginID == "codex" ? "codex-cli 0.167.0" : "2.1.308 (Claude Code)"
            let source = directory.appendingPathComponent("agent.c")
            let executable = directory.appendingPathComponent("agent")
            try "#include <unistd.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (argc > 1) { puts(\"\(version)\"); return 0; } sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            let result = try await ProcessRunner.liveValue.run("/usr/bin/clang", [source.path, "-o", executable.path], nil, 15)
            try #require(result.isSuccess, "\(result.stderrString)")
            let process = Process()
            process.executableURL = executable
            process.environment = ["PATH": "/usr/bin", "CODEX_HOME": directory.appendingPathComponent("codex").path]
            let exits = AsyncStream<Int32> { continuation in
                process.terminationHandler = { process in
                    continuation.yield(process.terminationStatus)
                    continuation.finish()
                }
            }
            try process.run()
            func stopProcess() async {
                if process.isRunning {
                    process.terminate()
                }
                var exit = exits.makeAsyncIterator()
                _ = await exit.next()
            }
            do {
                let pid = String(process.processIdentifier)
                let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
                let client = WorkspaceAgentProcessClient.liveValue
                let invocation = try await client.invocation(pid, runtime)
                #expect(invocation.version == version)
                #expect(provider.workflowRuntimeIssue(cliVersion: invocation.version) == nil)
                try FileManager.default.removeItem(at: executable)
                let removed = try await client.invocation(pid, runtime)
                // Kernel argv retains the launch path; proc_pidpath can canonicalize /var.
                #expect(removed.executable == executable.path)
                #expect(removed.arguments == invocation.arguments)
                #expect(removed.configurationRoots == invocation.configurationRoots)
                #expect(removed.version == nil)
                #expect(provider.workflowRuntimeIssue(cliVersion: removed.version) == nil)
                await #expect(throws: WorkspaceRecoveryError.self) { try await client.invocation(pid, "replacement-process") }
                await #expect(throws: AgentModelError.self) { try await client.modelContext(pid, runtime, directory.path, "agent") }
                #expect(process.isRunning)
            } catch {
                await stopProcess()
                throw error
            }
            await stopProcess()
        }
    }

    @Test("Live process provenance reads only the owned PID instance and recorded configuration roots")
    func liveProcess() async throws {
        let process = Process()
        let python = try #require(["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }, "A non-system Python is required to exercise readable process environment on macOS")
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import time; time.sleep(30)"]
        process.environment = ["CODEX_HOME": "/fixture/codex", "TRAE_HOME": "/fixture/traex", "PRIVATE_TOKEN": "not-persisted"]
        // Observe exit without blocking Swift's cooperative test executor.
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()

        func stopProcess() async {
            if process.isRunning {
                process.terminate()
            }
            var exit = exits.makeAsyncIterator()
            let status = await exit.next()
            #expect(status != nil)
            #expect(!process.isRunning)
        }

        do {
            let pid = String(process.processIdentifier)
            let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0.continuousClock = ContinuousClock()
            } operation: {
                let client = WorkspaceAgentProcessClient.liveValue
                let invocation = try await client.invocation(pid, runtime)
                #expect(invocation.executable.hasPrefix("/") && invocation.executable.lowercased().contains("python"))
                #expect(invocation.arguments == ["-c", "import time; time.sleep(30)"])
                #expect(invocation.configurationRoots == ["CODEX_HOME": "/fixture/codex", "TRAE_HOME": "/fixture/traex"])
                await #expect(throws: WorkspaceRecoveryError.self) { try await client.invocation(pid, "obsolete-runtime") }
            }
        } catch {
            await stopProcess()
            throw error
        }
        await stopProcess()
    }

    private func arguments(_ argv: [String], environment: [String]) -> Data {
        var argc = Int32(argv.count)
        var data = Data(bytes: &argc, count: MemoryLayout<Int32>.size)
        data += Data("/tools/agent\0\0\0".utf8)
        for value in argv + environment {
            data += Data((value + "\0").utf8)
        }
        data += Data([0, 0])
        return data
    }

    @Test("Kernel argv decoding preserves empty arguments but only admits configuration roots from env")
    func decode() throws {
        let argv = ["/tools/agent", "--model", "large", "", "private prompt"]
        let data = arguments(argv, environment: [
            "API_KEY=private-token",
            "CODEX_HOME=/private/codex",
            "TRAE_HOME=/private/traex",
            "CLAUDE_CONFIG_DIR=/private/claude",
            "\(AgentProviderEnvironment.markerKey)=custom",
            "PATH=/bin",
        ])
        let parsed = try WorkspaceAgentProcessArguments.parse(data)
        #expect(parsed.arguments == argv)
        #expect(parsed.configurationRoots == ["CODEX_HOME": "/private/codex", "TRAE_HOME": "/private/traex", "CLAUDE_CONFIG_DIR": "/private/claude"])
        #expect(parsed.providerID == "custom")
    }

    @Test("Relative, conflicting or truncated process evidence is rejected")
    func invalid() {
        #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceAgentProcessArguments.parse(arguments(["agent"], environment: [])) }
        #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceAgentProcessArguments.parse(arguments(["agent"], environment: ["CODEX_HOME=relative"])) }
        #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceAgentProcessArguments.parse(arguments(["agent"], environment: ["CODEX_HOME=/one", "CODEX_HOME=/two"])) }
        #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceAgentProcessArguments.parse(arguments(["agent"], environment: ["\(AgentProviderEnvironment.markerKey)=one", "\(AgentProviderEnvironment.markerKey)=two"])) }
        #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceAgentProcessArguments.parse(Data([1, 0, 0, 0, 65])) }
        #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceAgentProcessArguments.parse(Data([255, 255, 255, 255])) }
    }
}
