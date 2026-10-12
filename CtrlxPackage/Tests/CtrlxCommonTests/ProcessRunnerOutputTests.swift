import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

#if os(macOS)
    import Darwin

    @Suite("ProcessRunner output completeness", .serialized)
    struct ProcessRunnerOutputTests {
        @Test func cancelledCommandDoesNotLaunch() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("launched")
            let gate = AsyncStream<Void>.makeStream()
            let task = Task {
                for await _ in gate.stream { break }
                return try await ProcessRunner.liveValue.runCancellable("/usr/bin/touch", [marker.path], nil, 5)
            }
            task.cancel()
            gate.continuation.finish()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }

        @Test func cancellationStopsCommandAndChildBeforeReturning() async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/usr/bin:/bin" })
                $0.continuousClock = ContinuousClock()
            } operation: {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let ready = directory.appendingPathComponent("pids")
                let task = Task {
                    try await ProcessRunner.liveValue.runCancellable("/bin/sh", ["-c",
                        "trap '' TERM; sleep 20 & child=$!; printf '%s %s' \"$$\" \"$child\" > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; wait",
                        "process-runner-test", ready.path], nil, 25)
                }
                defer { task.cancel() }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pids = try String(contentsOf: ready, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
                try #require(pids.count == 2)
                #expect(getpgid(pids[0]) == pids[0])
                #expect(getpgid(pids[1]) == pids[0])
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
                for pid in pids {
                    let reapDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while kill(pid, 0) == 0, ContinuousClock.now < reapDeadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(kill(pid, 0) == -1 && errno == ESRCH)
                }
            }
        }

        @Test func cancellableCommandPreservesSuccessfulOutput() async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/usr/bin:/bin" })
                $0.continuousClock = ContinuousClock()
            } operation: {
                let result = try await ProcessRunner.liveValue.runCancellable("/bin/echo", ["complete"], nil, 5)
                #expect(result.isSuccess)
                #expect(result.stdoutString == "complete\n")
            }
        }

        @Test func boundedOutputKeepsRecentBytesAndDrainsBothStreams() async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/usr/bin:/bin" })
                $0.continuousClock = ContinuousClock()
            } operation: {
                let script = "awk 'BEGIN { for (i=0; i<20000; i++) { print i; print i > \"/dev/stderr\" } }'"
                let expected = Data((0..<20000).map { "\($0)\n" }.joined().utf8)
                let result = try await ProcessRunner.liveValue.runBounded("/bin/sh", ["-c", script], nil, 10, 1024)
                #expect(result.isSuccess)
                #expect(result.stdout == expected.suffix(1024))
                #expect(result.stderr == expected.suffix(1024))
                #expect(result.outputTruncated)
                let small = try await ProcessRunner.liveValue.runBounded("/bin/echo", ["测试 🙂"], nil, 10, 1024)
                #expect(small.stdoutString == "测试 🙂\n")
                #expect(!small.outputTruncated)
            }
        }

        @Test(arguments: 0..<10) func fastConcurrentProcessesKeepCompleteOutput(round: Int) async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/usr/bin:/bin" })
                $0.continuousClock = ContinuousClock()
            } operation: {
                let runner = ProcessRunner.liveValue
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<40 {
                        group.addTask {
                            let expected = "pane-\(round)-\(index)\n"
                            let result = try await runner.run("/bin/echo", ["pane-\(round)-\(index)"], nil, 10)
                            #expect(result.isSuccess)
                            #expect(result.stdoutString == expected)
                        }
                    }
                    try await group.waitForAll()
                }
            }
        }

        @Test func pipeSizedOutputKeepsBothStreamsAndTail() async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/usr/bin:/bin" })
                $0.continuousClock = ContinuousClock()
            } operation: {
                let script = "awk 'BEGIN { for (i=0; i<20000; i++) { print i; print i > \"/dev/stderr\" } }'"
                let expected = (0..<20000).map { "\($0)\n" }.joined()
                for _ in 0..<5 {
                    let result = try await ProcessRunner.liveValue.run("/bin/sh", ["-c", script], nil, 10)
                    #expect(result.isSuccess)
                    #expect(result.stdoutString == expected)
                    #expect(result.stderrString == expected)
                }
            }
        }
    }
#endif
