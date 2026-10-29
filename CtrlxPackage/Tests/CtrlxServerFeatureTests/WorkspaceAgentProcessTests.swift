import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct WorkspaceAgentProcessTests {
    @Test("A running Agent whose executable was removed explains how to restore CLI integration")
    func removedExecutable() async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("agent.c")
            let executable = directory.appendingPathComponent("agent")
            try "#include <unistd.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (argc > 1) { puts(\"fixture-cli 1\"); return 0; } sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            let result = try await ProcessRunner.liveValue.run("/usr/bin/clang", [source.path, "-o", executable.path], nil, 15)
            try #require(result.isSuccess, "\(result.stderrString)")
            let process = Process()
            process.executableURL = executable
            process.environment = ["PATH": "/usr/bin"]
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
                #expect(invocation.version == "fixture-cli 1")
                try FileManager.default.removeItem(at: executable)
                let expected = WorkspaceRecoveryError("The Agent CLI was updated or removed while this session was running. Restart the Agent and resume this conversation.")
                await #expect(throws: expected) { try await client.invocation(pid, runtime) }
                await #expect(throws: expected) { try await client.modelContext(pid, runtime, directory.path) }
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
        process.environment = ["CODEX_HOME": "/fixture/codex", "PRIVATE_TOKEN": "not-persisted"]
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
                #expect(invocation.configurationRoots == ["CODEX_HOME": "/fixture/codex"])
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
            "CLAUDE_CONFIG_DIR=/private/claude",
            "\(AgentProviderEnvironment.markerKey)=custom",
            "PATH=/bin",
        ])
        let parsed = try WorkspaceAgentProcessArguments.parse(data)
        #expect(parsed.arguments == argv)
        #expect(parsed.configurationRoots == ["CODEX_HOME": "/private/codex", "CLAUDE_CONFIG_DIR": "/private/claude"])
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
