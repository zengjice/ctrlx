import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct WorkspaceAgentProcessTests {
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
