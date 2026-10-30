import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentModelProcessUpdateTests {
    @Test("An unlinked running CLI keeps its configuration and uses an installed metadata helper", arguments: ["codex", "claude", "codex-code-mode-host", "claude/versions/2.1.310"])
    func updatedCLI(name: String) async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ctrlx-model-update-\(UUID())")
            let previous = root.appendingPathComponent("old/\(name)")
            let installed = root.appendingPathComponent("current")
            let command = name.hasPrefix("claude") ? "claude" : "codex"
            let version = command == "claude" ? "2.2.0 (Claude Code)" : "codex-cli 0.999.0"
            let helper = installed.appendingPathComponent(command)
            try FileManager.default.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("agent.c")
            let ready = root.appendingPathComponent("ready")
            try "#include <unistd.h>\n#include <stdio.h>\n#include <stdlib.h>\nint main(void) { FILE *f = fopen(getenv(\"CTRLX_TEST_READY\"), \"w\"); if (!f) return 1; fclose(f); sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            let compiled = try await ProcessRunner.liveValue.run("/usr/bin/clang", [source.path, "-o", previous.path], nil, 15)
            try #require(compiled.isSuccess, "\(compiled.stderrString)")
            try "#!/bin/sh\nprintf '%s\\n' '\(version)'\n".write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let process = Process()
            process.executableURL = previous
            process.arguments = ["30"]
            process.environment = ["PATH": installed.path, "CODEX_HOME": root.appendingPathComponent("config").path, "PRIVATE_TEST_TOKEN": "fixture-only", "CTRLX_TEST_READY": ready.path]
            let exits = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { process in
                exits.continuation.yield(process.terminationStatus)
                exits.continuation.finish()
            }
            try process.run()
            do {
                // Unlink only after dyld has loaded the fixture, as a real update would.
                for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(FileManager.default.fileExists(atPath: ready.path))
                let pid = String(process.processIdentifier)
                let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
                try FileManager.default.removeItem(at: previous)
                let client = WorkspaceAgentProcessClient.liveValue
                // First discovery happens after the update: no previous model cache is needed.
                let context = try await client.modelContext(pid, runtime, root.path, command)
                #expect(context.invocation.executable == previous.path)
                #expect(context.invocation.version == nil)
                #expect(context.invocation.arguments == ["30"])
                #expect(context.discoveryExecutable == helper.path)
                #expect(context.discoveryVersion == version)
                #expect(context.environment["PATH"] == installed.path)
                #expect(context.invocation.configurationRoots["CODEX_HOME"] == root.appendingPathComponent("config").path)
                #expect(context.environment["PRIVATE_TEST_TOKEN"] == "fixture-only")
                #expect(process.isRunning)
                await #expect(throws: WorkspaceRecoveryError.self) { try await client.modelContext(pid, "replaced", root.path, command) }
                await #expect(throws: AgentModelError.self) { try await client.modelContext(pid, runtime, root.path, nil) }
                try FileManager.default.removeItem(at: helper)
                do {
                    _ = try await client.modelContext(pid, runtime, root.path, command)
                    Issue.record("A removed helper must not be reused")
                } catch let error as AgentModelError {
                    #expect(error.message.contains("/model"))
                    #expect(!error.message.contains("Restart"))
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                for await _ in exits.stream {
                    break
                }
                throw error
            }
            if process.isRunning {
                process.terminate()
            }
            for await _ in exits.stream {
                break
            }
        }
    }
}
