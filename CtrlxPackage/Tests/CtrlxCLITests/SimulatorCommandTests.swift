import ArgumentParser
import CtrlxSimulatorProtocol
import Dependencies
import Foundation
import Synchronization
import Testing

@testable import CtrlxCLI

struct SimulatorCommandTests {
    @Test func recordingAndPinchSurviveBatchEncodingWithoutTreatingVideoAsPNG() throws {
        let batch = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let prepared = try batch.prepare(JSONEncoder().encode([
            ["record-start", "--device", "owned", "--output", "/tmp/recording.mp4", "--seconds", "10"],
            ["pinch", "--device", "owned", "--x", "180", "--y", "300", "--scale", "2", "--duration-ms", "500"],
            ["record-stop", "--device", "owned"],
        ]))
        guard case let .array(rows)? = prepared.parameters["actions"],
              case let .object(record) = rows[0], case let .object(pinch) = rows[1] else {
            Issue.record("Missing recording/pinch actions"); return
        }
        #expect(record["output"] == .string("/tmp/recording.mp4"))
        #expect(pinch["scale"] == .double(2))
        #expect(pinch["durationMs"] == .int(500))
        let video: [String: JSONValue] = ["state": .string("recording"), "path": .string("/tmp/recording.mp4")]
        #expect(try prepared.actions[0].saveScreenshot(video, requestedAt: 0) == video)
    }

    @Test(arguments: [
        ["record-start", "--device", "d"],
        ["record-start", "--device", "d", "--output", "relative.mp4"],
        ["record-start", "--device", "d", "--output", "/tmp/record.mov"],
        ["record-start", "--device", "d", "--output", "/tmp/record.mp4", "--seconds", "61"],
        ["record-stop", "--device", "d", "--seconds", "5"],
        ["pinch", "--device", "d", "--x", "100", "--y", "100"],
        ["pinch", "--device", "d", "--x", "100", "--y", "100", "--scale", "nan"],
        ["pinch", "--device", "d", "--x", "100", "--y", "100", "--scale", "1"],
        ["pinch", "--device", "d", "--x", "100", "--y", "100", "--scale", "2", "--end-x", "200"],
        ["tap", "--device", "d", "--scale", "2"],
    ]) func invalidRecordingOrPinchIsRejected(_ arguments: [String]) throws {
        let command = try SimulatorActionCommand.parse(arguments)
        #expect(throws: (any Error).self) { try command.parameters() }
    }

    @Test(arguments: ["open", "erase", "delete"])
    func storageTargetsSurviveBatchEncoding(_ operation: String) throws {
        let udid = UUID().uuidString
        let batch = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let prepared = try batch.prepare(JSONEncoder().encode([[operation, "--udid", udid]]))
        guard case let .array(actions)? = prepared.parameters["actions"], case let .object(action) = actions[0] else {
            Issue.record("Missing storage action"); return
        }
        #expect(action["command"]?.stringValue == operation)
        #expect(action["udid"]?.stringValue == udid)
        #expect(action["device"] == nil)
    }

    @Test(arguments: [
        ["erase"], ["delete", "--udid", "all"], ["erase", "--udid", "../outside"],
        ["status", "--udid", "00000000-0000-0000-0000-000000000001"],
        ["open", "--udid", "00000000-0000-0000-0000-000000000001", "--runtime", "runtime"],
        ["delete", "--udid", "00000000-0000-0000-0000-000000000001", "--device", "other"],
        ["uninstall", "--device", "device"], ["uninstall", "--bundle", "com.example.app"],
        ["uninstall", "--device", "device", "--bundle", "com.example/other"],
    ]) func invalidStorageAndUninstallTargetsNeverContactHost(_ arguments: [String]) throws {
        let calls = Mutex(0)
        let action = try SimulatorActionCommand.parse(arguments)
        withDependencies {
            $0[SimulatorCommandClient.self].send = { _, _, _, _ in
                calls.withLock { $0 += 1 }
                throw CLIError.connectionFailed
            }
        } operation: { #expect(throws: (any Error).self) { try action.run() } }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func storageListsWithoutDeviceAndUninstallKeepsExactBundle() throws {
        #expect(try SimulatorActionCommand.parse(["storage"]).parameters() == ["command": .string("storage")])
        let action = try SimulatorActionCommand.parse(["uninstall", "--device", "owned", "--bundle", "com.example.app"])
        #expect(try action.parameters() == ["command": .string("uninstall"), "device": .string("owned"), "bundle": .string("com.example.app")])
    }

    @Test func showSplitIsExplicitAndSurvivesBatchEncoding() throws {
        let device = UUID().uuidString
        let normal = try SimulatorActionCommand.parse(["show", "--device", device])
        #expect(try normal.parameters()["split"] == nil)
        let command = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let prepared = try command.prepare(JSONEncoder().encode([["show", "--device", device, "--split"]]))
        guard case let .array(actions)? = prepared.parameters["actions"], case let .object(action) = actions[0] else {
            Issue.record("Missing split show action"); return
        }
        #expect(action["command"]?.stringValue == "show")
        #expect(action["device"]?.stringValue == device)
        #expect(action["split"]?.boolValue == true)
    }

    @Test(arguments: ["open", "tap", "status", "close"])
    func splitCannotBeAppliedToOtherActions(_ operation: String) throws {
        let command = try SimulatorActionCommand.parse([operation, "--device", UUID().uuidString, "--split"])
        #expect(throws: ValidationError.self) { try command.parameters() }
    }

    @Test(arguments: [
        "[]", "[[]]", "[[\"run\",\"codex\"]]", "[[\"batch\"]]", "[[\"identity\",\"--socket\",\"/other.sock\"]]",
        "[[\"identity\"], [\"status\",\"--timeout-ms\",\"5\"]]", "[{\"command\":\"identity\"}]",
        "[[\"screenshot\",\"--device\",\"test\",\"--output\",\"/tmp/new.png\"],[\"identity\"]]",
    ]) func malformedBatchDoesNotContactTheHost(_ input: String) throws {
        let command = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let sent = Mutex(0)
        withDependencies {
            $0[SimulatorCommandClient.self].send = { _, _, _, _ in
                sent.withLock { $0 += 1 }
                throw CLIError.connectionFailed
            }
        } operation: {
            #expect(throws: (any Error).self) { try command.execute(Data(input.utf8)) }
        }
        #expect(sent.withLock { $0 } == 0)
    }

    @Test func batchBoundsAreCheckedBeforeConnection() throws {
        let command = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let rows = Array(repeating: ["identity"], count: 17)
        #expect(throws: ValidationError.self) { try command.prepare(JSONEncoder().encode(rows)) }
        #expect(throws: ValidationError.self) { try command.prepare(Data(repeating: 32, count: 64001)) }
    }

    @Test func batchUsesOneRequestAndRetainsTheStoppedResults() throws {
        let command = try SimulatorBatchCommand.parse(["--input", "/unused.json", "--socket", "/owned.sock"])
        let sent = Mutex(0)
        let result = try withDependencies {
            $0[SimulatorCommandClient.self].send = { request, socket, timeout, limit in
                sent.withLock { $0 += 1 }
                #expect(socket == "/owned.sock")
                #expect(request.method == "simulator.action")
                #expect(request.params["command"]?.stringValue == "batch")
                #expect(timeout == SimulatorBatchLimits.transportSeconds)
                #expect(limit == SimulatorBatchLimits.maximumResponseBytes)
                return JSONRPCResponse(id: request.id, result: ["success": .bool(false), "planned": .int(3), "completed": .int(1), "stoppedAt": .int(1),
                    "results": .array([
                        .object(["index": .int(0), "command": .string("identity"), "ok": .bool(true), "result": .object(["verified": .bool(true)])]),
                        .object(["index": .int(1), "command": .string("devices"), "ok": .bool(false),
                            "error": .object(["message": .string("Owner exited")])]),
                    ])])
            }
        } operation: {
            try command.execute(Data("[[\"identity\"],[\"devices\"],[\"identity\"]]".utf8))
        }
        #expect(sent.withLock { $0 } == 1)
        #expect(result["success"]?.boolValue == false)
        #expect(result["completed"]?.intValue == 1)
        #expect(result["stoppedAt"]?.intValue == 1)
        if case let .array(rows)? = result["results"] { #expect(rows.count == 2) }
        else { Issue.record("Stopped results were lost") }
    }

    @Test func batchTransportTimeoutDoesNotRetry() throws {
        let command = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let sent = Mutex(0)
        withDependencies {
            $0[SimulatorCommandClient.self].send = { _, _, _, _ in
                sent.withLock { $0 += 1 }
                throw CLIError.responseTimeout
            }
        } operation: {
            #expect(throws: CLIError.self) { try command.execute(Data("[[\"identity\"]]".utf8)) }
        }
        #expect(sent.withLock { $0 } == 1)
    }

    @Test func batchScreenshotCreationRacePreservesTheExistingFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        let command = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let input = try JSONEncoder().encode([["screenshot", "--device", UUID().uuidString, "--output", file.path]])
        let result = try withDependencies {
            $0[SimulatorCommandClient.self].send = { request, _, _, _ in
                try Data("keep-raced-file".utf8).write(to: file)
                return JSONRPCResponse(id: request.id, result: ["success": .bool(true), "planned": .int(1), "completed": .int(1),
                    "results": .array([.object(["index": .int(0), "command": .string("screenshot"), "ok": .bool(true),
                        "result": .object(["data": .string(Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString())])])])])
            }
        } operation: { try command.execute(input) }
        #expect(result["success"]?.boolValue == false)
        #expect(result["stoppedAt"]?.intValue == 0)
        #expect(try Data(contentsOf: file) == Data("keep-raced-file".utf8))
        guard case let .array(rows)? = result["results"], case let .object(row) = rows[0],
              case let .object(metadata)? = row["result"] else { Issue.record("Missing artifact failure details"); return }
        #expect(metadata["data"] == nil)
        #expect(row["outcome"]?.stringValue == "action-completed-artifact-failed")
    }

    @Test func batchScreenshotKeepsLiteralArgumentsAndNeverOverwrites() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("keep".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let command = try SimulatorBatchCommand.parse(["--input", "/unused.json"])
        let rows = [["paste", "--device", UUID().uuidString, "--text", "a; $(literal)\n你好"],
                    ["screenshot", "--device", UUID().uuidString, "--output", file.path]]
        #expect(throws: ValidationError.self) { try command.prepare(JSONEncoder().encode(rows)) }
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
        let prepared = try command.prepare(JSONEncoder().encode(Array(rows.prefix(1))))
        if case let .array(actions)? = prepared.parameters["actions"], case let .object(action) = actions[0] {
            #expect(action["text"]?.stringValue == "a; $(literal)\n你好")
        } else { Issue.record("Literal paste arguments were lost") }
    }

    @Test(arguments: [
        ["launch", "--bundle", "com.example.app", "--timeout-ms", "0"],
        ["launch", "--bundle", "com.example.app", "--timeout-ms", "60001"],
        ["wait", "--identifier", "ready", "--timeout-ms", "0"],
        ["status", "--timeout-ms", "1000"],
    ]) func invalidReadinessDeadlinesAreRejectedBeforeConnection(_ arguments: [String]) throws {
        let command = try CtrlxCLI.parseAsRoot(["simulator"] + arguments + ["--device", UUID().uuidString,
            "--socket", "/nonexistent-simulator-test.sock"])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(throws: ValidationError.self) { try action.run() }
    }

    @Test(arguments: SimulatorTouchEdge.allCases) func parsesExplicitSwipeEdge(_ edge: SimulatorTouchEdge) throws {
        let command = try CtrlxCLI.parseAsRoot(["simulator", "swipe", "--device", UUID().uuidString, "--edge", edge.rawValue])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(action.edge == edge)
    }

    @Test(arguments: ["none", "bottom-right", "3"]) func rejectsUnknownSwipeEdges(_ edge: String) {
        #expect(throws: (any Error).self) { try CtrlxCLI.parseAsRoot(["simulator", "swipe", "--edge", edge]) }
    }

    @Test(arguments: [
        ["status", "--modifiers", "shift"], ["key"], ["key", "--usage", "3"],
        ["key", "--usage", "4", "--modifiers", "shift,shift"],
        ["key", "--usage", "4", "--modifiers", "command,"],
        ["key", "--usage", "4", "--modifiers", "meta"],
        ["key", "--usage", "225", "--modifiers", "shift"],
    ]) func rejectsInvalidKeyModifiersBeforeConnection(_ arguments: [String]) throws {
        let command = try CtrlxCLI.parseAsRoot(["simulator"] + arguments + ["--device", UUID().uuidString])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(throws: (any Error).self) { try action.run() }
    }

    @Test func negativeCoordinatesAreOptionValues() throws {
        let command = try CtrlxCLI.parseAsRoot(["simulator", "location", "--device", UUID().uuidString,
            "--latitude", "-33.8688", "--longitude", "-122.009"])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(action.latitude == -33.8688)
        #expect(action.longitude == -122.009)
    }

    @Test(arguments: [false, true]) func codexAdapterKeepsLiteralArguments(_ alreadyLocal: Bool) async throws {
        let captured = Mutex<[String]>([])
        let literal = "literal spaces; $HOME `command`"
        let options = (alreadyLocal ? ["--no-daemon"] : []) + ["--no-alt-screen", literal]
        let command = try CtrlxCLI.parseAsRoot(["simulator", "run", "--", "codex"] + options)
        let adapter = try #require(command as? SimulatorRunCommand)
        try await withDependencies {
            $0[SimulatorLaunchClient.self].run = { name, arguments in captured.withLock { $0 = [name] + arguments } }
        } operation: {
            try await adapter.run()
        }
        #expect(captured.withLock { $0 } == ["codex", "--no-daemon", "--no-alt-screen", literal])
    }

    @Test func codexAdapterReportsMissingExecutable() async {
        await #expect(throws: ValidationError.self) {
            try await SimulatorLaunchClient.liveValue.run("/nonexistent-\(UUID().uuidString)/codex", ["--no-daemon"])
        }
    }

    @Test(arguments: ["--no-daemon", "--remote", "--remote=unix:///tmp/other"])
    func codexAdapterPreservesOptionLikePrompt(_ prompt: String) async throws {
        let captured = Mutex<[String]>([])
        let command = try CtrlxCLI.parseAsRoot(["simulator", "run", "--", "codex", "--", prompt])
        let adapter = try #require(command as? SimulatorRunCommand)
        try await withDependencies {
            $0[SimulatorLaunchClient.self].run = { name, arguments in captured.withLock { $0 = [name] + arguments } }
        } operation: {
            try await adapter.run()
        }
        #expect(captured.withLock { $0 } == ["codex", "--no-daemon", "--", prompt])
    }

    @Test(arguments: [["claude"], ["codex", "--remote", "unix:///tmp/other"], ["codex", "--remote=unix:///tmp/other"]])
    func adapterRejectsOtherAgentsAndExternalServers(_ words: [String]) async throws {
        let command = try CtrlxCLI.parseAsRoot(["simulator", "run", "--"] + words)
        let adapter = try #require(command as? SimulatorRunCommand)
        await #expect(throws: ValidationError.self) { try await adapter.run() }
    }

    @Test func screenshotCannotOverwriteAnExistingArtifact() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("existing".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let command = try CtrlxCLI.parseAsRoot(["simulator", "screenshot", "--device", UUID().uuidString, "--output", file.path])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(throws: ValidationError.self) { try action.run() }
        #expect(try Data(contentsOf: file) == Data("existing".utf8))
    }

    @Test(arguments: [
        ["tap", "--ref", "@old", "--x", "10", "--y", "20"],
        ["tap", "--ref", "@old", "--identifier", "submit"],
        ["wait", "--ref", "@old"],
        ["snapshot", "--profile", "balanced"],
        ["open", "--max-devices", "8"],
        ["tap", "--reset-measurements"],
        ["status", "--mode", "low-latency"],
        ["display-mode"],
        ["display-mode", "--mode", "automatic"],
        ["tap", "--via-menu"],
        ["tap", "--edge", "bottom"],
        ["drag", "--edge", "left"],
        ["status", "--edge", "top"],
        ["paste", "--via-menu", "--text", "test"],
        ["paste", "--via-menu", "--x", "10", "--text", "test"],
        ["paste", "--identifier", "field", "--text", "test"],
        ["paste", "--via-menu", "--identifier", "field", "--x", "10", "--y", "20", "--text", "test"],
        ["location"],
        ["location", "--latitude", "10"],
        ["location", "--clear", "--latitude", "10", "--longitude", "20"],
        ["status", "--latitude", "10", "--longitude", "20"],
        ["status", "--style", "dark"],
        ["status", "--action", "reset", "--service", "location"],
        ["privacy", "--action", "reset", "--service", "all"],
        ["push", "--bundle", "com.example.app"],
        ["status", "--payload", "/unused/payload.json"],
        ["status", "--last-seconds", "30"],
        ["status", "--max-bytes", "1024"],
        ["logs"],
        ["logs", "--bundle", "com.example.app", "--limit", "1"],
        ["crashes"],
    ]) func conflictingTargetsOrConfigurationAreRejectedBeforeSending(_ arguments: [String]) throws {
        let command = try CtrlxCLI.parseAsRoot(["simulator"] + arguments + ["--device", UUID().uuidString])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(throws: ValidationError.self) { try action.run() }
    }

    @Test(arguments: [
        ["appearance", "--style", "automatic"],
        ["privacy", "--action", "delete", "--service", "location"],
        ["privacy", "--action", "grant", "--service", "camera"],
    ]) func rejectsUnknownEnvironmentValues(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try CtrlxCLI.parseAsRoot(["simulator"] + arguments) }
    }

    @Test func oversizedPushIsRejectedBeforeSocketConnection() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(("{\"aps\":{},\"text\":\"" + String(repeating: "a", count: 4096) + "\"}").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let command = try CtrlxCLI.parseAsRoot(["simulator", "push", "--device", UUID().uuidString,
            "--bundle", "com.example.app", "--payload", file.path, "--socket", "/nonexistent-simulator-test.sock"])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(throws: SimulatorFailure.self) { try action.run() }
    }

    @Test(arguments: [
        ["logs", "--last-seconds", "301"], ["logs", "--max-bytes", "0"],
        ["crashes", "--last-seconds", "86401"], ["crashes", "--limit", "11"],
        ["crashes", "--max-bytes", "262145"],
    ]) func invalidDiagnosticBoundsAreRejectedBeforeConnection(_ arguments: [String]) throws {
        let command = try CtrlxCLI.parseAsRoot(["simulator"] + arguments + ["--device", UUID().uuidString,
            "--bundle", "com.example.app", "--socket", "/nonexistent-simulator-test.sock"])
        let action = try #require(command as? SimulatorActionCommand)
        #expect(throws: SimulatorFailure.self) { try action.run() }
    }
}
