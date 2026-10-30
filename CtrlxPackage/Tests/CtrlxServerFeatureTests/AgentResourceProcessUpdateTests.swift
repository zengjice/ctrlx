import CtrlxCommon
import CtrlxNetworking
import CtrlxSimulatorProtocol
import Darwin
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentResourceProcessUpdateTests {
    @Test(arguments: ["codex", "claude", "pretender"])
    func liveHostInspectionSurvivesSupportedCLIUpdate(_ name: String) async throws {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-process-update-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("agent.c")
            let binary = root.appendingPathComponent(name)
            let ready = root.appendingPathComponent("ready")
            try "#include <unistd.h>\n#include <string.h>\n#include <fcntl.h>\nint main(int argc, char **argv) { strcpy(argv[0], \"codex\"); close(open(argv[1], O_WRONLY|O_CREAT, 0600)); alarm(30); pause(); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            let compiled = try await ProcessRunner.liveValue.run("/usr/bin/clang", [source.path, "-o", binary.path], nil, 15)
            try #require(compiled.isSuccess, "\(compiled.stderrString)")
            let fixture = Process()
            fixture.executableURL = binary
            fixture.arguments = [ready.path]
            let exits = AsyncStream<Int32> { continuation in
                fixture.terminationHandler = { process in
                    continuation.yield(process.terminationStatus)
                    continuation.finish()
                }
            }
            try fixture.run()
            func stop() async {
                if fixture.isRunning {
                    fixture.terminate()
                }
                var exit = exits.makeAsyncIterator()
                _ = await exit.next()
            }
            do {
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: ready.path) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(FileManager.default.fileExists(atPath: ready.path))
                let system = SimulatorSystemClient.liveValue
                let before = try system.inspect(fixture.processIdentifier)
                try FileManager.default.removeItem(at: binary)
                if name == "pretender" {
                    #expect(throws: SimulatorFailure.self) { try system.inspect(fixture.processIdentifier) }
                } else {
                    let after = try system.inspect(fixture.processIdentifier)
                    #expect(after.owner == before.owner)
                    #expect(after.parentPID == before.parentPID)
                    #expect(after.executable == name)
                    // The same Host inspector is used by browser conversation binding.
                    let response = await withDependencies {
                        $0[SimulatorSystemClient.self] = system
                        $0[ProcessRunner.self] = .previewValue
                    } operation: {
                        let service = AgentSimulatorService()
                        service.start(root: root, resolveRoute: { _ in throw SimulatorFailure("Identity must not resolve a route") })
                        let result = await service.handle(JSONRPCRequest(id: "test", method: "simulator.action", params: [
                            "command": .string("identity"), "_peerPID": .int(Int(fixture.processIdentifier)),
                        ]))
                        await service.shutdown()
                        return result
                    }
                    #expect(response.ok)
                    #expect(response.result?["owner"]?.objectValue?["pid"]?.intValue == Int(before.owner.pid))
                }
            } catch {
                await stop()
                throw error
            }
            await stop()
        }
    }
}
