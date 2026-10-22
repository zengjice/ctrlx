#if os(macOS)
    import CtrlxCommon
    import Darwin
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Agent CLI isolated process checks")
    struct AgentCLIProcessTests {
        private actor Output {
            var text = ""
            func append(_ value: String) {
                text += value
            }
        }

        @Test("Streams stdout and stderr before exit; cancellation kills the installer and its child")
        func streamingAndCancellation() async throws {
            let messages = AsyncStream<String>.makeStream()
            let task = Task {
                try await withDependencies { $0[LoginShellPath.self].resolve = { "/usr/bin:/bin" } } operation: {
                    try await AgentCLIProcess.run(
                        executable: "/bin/sh", arguments: ["-c", "sleep 60 & child=$!; echo child:$child; echo stderr-line >&2; wait"],
                        timeout: 10, output: { messages.continuation.yield($0) }
                    )
                }
            }
            var iterator = messages.stream.makeAsyncIterator()
            let first = try #require(await iterator.next())
            #expect(first.contains("child:"))
            let line = try #require(first.split(separator: "\n").first(where: { $0.hasPrefix("child:") }))
            let child = try #require(Int32(line.dropFirst(6)))
            #expect(kill(child, 0) == 0)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            // launchd may need a moment to reap an orphaned child after its group is killed.
            for _ in 0..<50 where kill(child, 0) == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(kill(child, 0) == -1)
        }

        @Test("Silent installers time out and a final short log is drained")
        func timeoutAndOutput() async throws {
            let output = Output()
            try await withDependencies { $0[LoginShellPath.self].resolve = { "/usr/bin:/bin" } } operation: {
                let exit = try await AgentCLIProcess.run(executable: "/bin/sh", arguments: ["-c", "echo first; echo last >&2; exit 7"], timeout: 2, output: { await output.append($0) })
                #expect(exit == 7)
                #expect(await output.text.contains("last"))
                await #expect(throws: AgentCLIError.self) {
                    try await AgentCLIProcess.run(executable: "/bin/sh", arguments: ["-c", "sleep 60"], timeout: 0.15, output: { _ in })
                }
            }
        }

        @Test("A native launcher only requires path repair when resolved outside PATH", arguments: InstallableAgentCLI.allCases)
        func nativeCommandResolution(agent: InstallableAgentCLI) async throws {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-cli-path-test-\(UUID().uuidString)")
            let binary = URL(fileURLWithPath: agent.nativePath(home: home))
            let directory = binary.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            try Data("#!/bin/sh\necho fixture-1.2.3\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            await withDependencies {
                $0[LoginShellPath.self].resolve = { "/usr/bin:/bin" }
            } operation: {
                let onPath = await AgentCLIClient.inspect(agent, command: agent.command, searchPath: directory.path, home: home)
                #expect(onPath == .available(path: binary.path, version: "fixture-1.2.3"))
                let fallback = await AgentCLIClient.inspect(agent, command: agent.command, searchPath: "/usr/bin:/bin", home: home)
                #expect(fallback == .available(path: binary.path, version: "fixture-1.2.3", requiresPathRepair: true))
                let explicit = await AgentCLIClient.inspect(agent, command: binary.path, searchPath: "/usr/bin:/bin", home: home)
                #expect(explicit == .available(path: binary.path, version: "fixture-1.2.3"))
            }
        }

        @Test("Custom command is authoritative and a nonzero version check is not absence")
        func customCommand() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-cli-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let binary = folder.appendingPathComponent("my agent")
            try Data("#!/bin/sh\necho fixture-1.2.3\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0[LoginShellPath.self].resolve = { "/usr/bin:/bin" }
            } operation: {
                #expect(await AgentCLIClient.inspect(.codex, command: binary.path, searchPath: "/usr/bin:/bin") == .available(path: binary.path, version: "fixture-1.2.3"))
                let missing = await AgentCLIClient.inspect(.codex, command: folder.appendingPathComponent("absent").path, searchPath: "/usr/bin:/bin")
                #expect(!missing.isMissing)
            }
            try Data("#!/bin/sh\nexit 2\n".utf8).write(to: binary)
            await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0[LoginShellPath.self].resolve = { "/usr/bin:/bin" }
            } operation: {
                let broken = await AgentCLIClient.inspect(.codex, command: binary.path, searchPath: "/usr/bin:/bin")
                if case .unavailable = broken { } else {
                    Issue.record("Broken binary must not trigger installation")
                }
            }
        }
    }
#endif
