#if os(macOS)
    import AppKit
    import CtrlxCommon
    import CtrlxNetworking
    @preconcurrency import CtrlxSimulatorBridge
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import Foundation
    import Metal
    import QuartzCore
    import SwiftUI
    import Synchronization
    import Testing
    @testable import CtrlxServerFeature

    private final class TestSimulatorFrame: CXSimulatorFrame, @unchecked Sendable {
        private let data: Data
        private let finished = Mutex(0)

        init(geometry: SimulatorGeometry) throws {
            data = try JSONEncoder().encode(geometry)
            super.init()
        }

        override var metadataJSON: Data { data }
        override func finish() { finished.withLock { $0 += 1 } }
        var finishCount: Int { finished.withLock { $0 } }
    }

    private final class TestSimulatorConnection: CXSimulatorConnection, @unchecked Sendable {
        let commands = Mutex<[[String: JSONValue]]>([])

        override func invalidate() {}

        override func request(_ data: Data, reply: @escaping CXSimulatorDataReply) {
            do {
                let command = try JSONDecoder().decode([String: JSONValue].self, from: data)
                commands.withLock { $0.append(command) }
                reply(Data("{}".utf8), nil)
            } catch {
                reply(nil, error as NSError)
            }
        }
    }

    @MainActor
    private final class TestVisibleSimulatorWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState { .visible }
    }

    private struct TestSimulatorPlacement: View {
        let state: SimulatorTabState
        let trailing: Bool

        var body: some View {
            HStack {
                if !trailing { SimulatorTabContentView(state: state, workspaceID: state.workspaceID) }
                Text("Other pane")
                if trailing { SimulatorTabContentView(state: state, workspaceID: state.workspaceID) }
            }
        }
    }

    @Suite("Agent Simulator", .serialized)
    @MainActor
    struct AgentSimulatorTests {
        @Test func queuedFramesReleaseSupersededLeasesAndDeliverTheNewest() async throws {
            let geometry = SimulatorGeometry(width: 1179, height: 2556, scale: 3,
                orientation: 1, geometryVersion: 1, epoch: UUID().uuidString)
            let frames = try (0..<4).map { _ in try TestSimulatorFrame(geometry: geometry) }
            let (stream, continuation) = AsyncStream<CXSimulatorFrame>.makeStream()
            defer { continuation.finish() }
            let mailbox = SimulatorFrameMailbox { continuation.yield($0) }
            mailbox.receive(frames[0])
            mailbox.receive(frames[1])
            mailbox.receive(frames[2])
            #expect(frames[0].finishCount == 1)
            #expect(frames[1].finishCount == 1)
            #expect(frames[2].finishCount == 0)

            var received = stream.makeAsyncIterator()
            let newest = await received.next()
            #expect(newest === frames[2])
            newest?.finish()
            mailbox.receive(frames[3])
            let next = await received.next()
            #expect(next === frames[3])
            next?.finish()
            #expect(frames.allSatisfy { $0.finishCount == 1 })
        }

        @Test func queuedFrameIsReleasedWhenItsViewClosesBeforeDelivery() async throws {
            let metal = try #require(MTLCreateSystemDefaultDevice())
            let view = try SimulatorMetalView(metal: metal)
            let frame = try TestSimulatorFrame(geometry: SimulatorGeometry(width: 1179, height: 2556,
                scale: 3, orientation: 1, geometryVersion: 1, epoch: UUID().uuidString))
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let mailbox = SimulatorFrameMailbox { frame in
                    view.receive(frame)
                    done.resume()
                }
                mailbox.receive(frame)
                view.close()
                #expect(frame.finishCount == 0)
            }
            #expect(frame.finishCount == 1)
        }

        nonisolated private func process(_ pid: Int32, parent: Int32 = 1, name: String, start: UInt64 = 100, uid: UInt32 = getuid())
            -> SimulatorProcess
        {
            SimulatorProcess(
                owner: SimulatorOwner(pid: pid, uid: uid, startSeconds: start, startMicros: 42), parentPID: parent,
                executable: "/fixture/\(name)")
        }

        private func identity(peer: Int32, system: SimulatorSystemClient) async -> JSONRPCResponse {
            await withDependencies {
                $0[SimulatorSystemClient.self] = system
                $0[ProcessRunner.self] = .previewValue
            } operation: {
                let service = AgentSimulatorService()
                service.start(
                    root: URL(fileURLWithPath: "/unused-simulator-test"),
                    resolveRoute: { _ in throw SimulatorFailure("Not used by identity") }
                )
                let result = await service.handle(
                    JSONRPCRequest(
                        id: "test", method: "simulator.action", params: ["command": .string("identity"), "_peerPID": .int(Int(peer))]))
                await service.shutdown()
                return result
            }
        }

        private func batch(_ actions: [JSONValue], system: SimulatorSystemClient) async -> JSONRPCResponse {
            await withDependencies {
                $0[SimulatorSystemClient.self] = system
                $0[ProcessRunner.self] = .previewValue
            } operation: {
                let service = AgentSimulatorService()
                service.start(
                    root: URL(fileURLWithPath: "/unused-simulator-batch"),
                    resolveRoute: { _ in throw SimulatorFailure("Not used by batch identity") }
                )
                let result = await service.handle(JSONRPCRequest(id: "batch-test", method: "simulator.action",
                    params: ["command": .string("batch"), "actions": .array(actions), "_peerPID": .int(11)]))
                await service.shutdown()
                return result
            }
        }

        @Test func batchStopsAfterTheFirstFailureAndRetainsEarlierResults() async throws {
            var system = SimulatorSystemClient()
            system.inspect = { pid in process(pid, parent: pid == 11 ? 10 : 1, name: pid == 10 ? "codex" : "sh") }
            let response = await batch([
                .object(["command": .string("identity")]),
                .object(["command": .string("tap"), "device": .string(UUID().uuidString)]),
                .object(["command": .string("identity")]),
            ], system: system)
            #expect(response.ok)
            #expect(response.result?["success"]?.boolValue == false)
            #expect(response.result?["completed"]?.intValue == 1)
            #expect(response.result?["stoppedAt"]?.intValue == 1)
            guard case let .array(rows)? = response.result?["results"] else { Issue.record("Missing batch results"); return }
            #expect(rows.count == 2)
            #expect(rows[0].objectValue?["result"]?.objectValue?["owner"]?.objectValue?["pid"]?.intValue == 10)
            #expect(rows[1].objectValue?["ok"]?.boolValue == false)
        }

        @Test func batchRevalidatesProcessIdentityBeforeTheNextAction() async throws {
            let inspected = Mutex(0)
            var system = SimulatorSystemClient()
            system.inspect = { pid in
                let count = pid == 10 ? inspected.withLock { $0 += 1; return $0 } : 0
                return process(pid, parent: pid == 11 ? 10 : 1, name: pid == 10 ? "codex" : "sh", start: count >= 5 ? 101 : 100)
            }
            let response = await batch(Array(repeating: .object(["command": .string("identity")]), count: 3), system: system)
            #expect(response.result?["completed"]?.intValue == 1)
            #expect(response.result?["stoppedAt"]?.intValue == 1)
            #expect(inspected.withLock { $0 } == 5)
            guard case let .array(rows)? = response.result?["results"] else { Issue.record("Missing batch results"); return }
            #expect(rows.count == 2)
            #expect(rows[1].objectValue?["error"]?.objectValue?["message"]?.stringValue == "The owning agent process exited or changed identity")
        }

        @Test func batchRetainsAllSuccessfulActionsInOrder() async {
            var system = SimulatorSystemClient()
            system.inspect = { pid in process(pid, parent: pid == 11 ? 10 : 1, name: pid == 10 ? "codex" : "sh") }
            let response = await batch([
                .object(["command": .string("identity")]), .object(["command": .string("devices")]), .object(["command": .string("identity")]),
            ], system: system)
            #expect(response.ok)
            #expect(response.result?["success"]?.boolValue == true)
            #expect(response.result?["planned"]?.intValue == 3)
            #expect(response.result?["completed"]?.intValue == 3)
            #expect(response.result?["stoppedAt"] == nil)
            guard case let .array(rows)? = response.result?["results"] else { Issue.record("Missing batch results"); return }
            #expect(rows.count == 3)
            #expect(rows.map { $0.objectValue?["index"]?.intValue } == [0, 1, 2])
            #expect(rows.allSatisfy { $0.objectValue?["ok"]?.boolValue == true })
        }

        @Test(arguments: ["empty", "too-many", "nested", "spoofed-peer", "screenshot-first"])
        func invalidBatchIsRejectedBeforeAnyAction(_ scenario: String) async {
            let inspected = Mutex(0)
            var system = SimulatorSystemClient()
            system.inspect = { pid in
                inspected.withLock { $0 += 1 }
                return process(pid, name: "codex")
            }
            let first: JSONValue = .object(["command": .string("identity")])
            let actions: [JSONValue]
            switch scenario {
            case "empty": actions = []
            case "too-many": actions = Array(repeating: first, count: 17)
            case "nested": actions = [first, .object(["command": .string("batch")])]
            case "spoofed-peer": actions = [first, .object(["command": .string("identity"), "_peerPID": .int(999)])]
            default: actions = [.object(["command": .string("screenshot")]), first]
            }
            let response = await batch(actions, system: system)
            #expect(!response.ok)
            #expect(inspected.withLock { $0 } == 0)
        }

        @Test func launchProcessIdentifierMatchesTheRequestedApplication() throws {
            #expect(try SimulatorCoordinator.launchedProcessID(Data("com.example.app: 12345\n".utf8), bundle: "com.example.app") == 12345)
            #expect(try SimulatorCoordinator.launchedProcessID(Data("com.example.app: 2147483647\n".utf8), bundle: "com.example.app") == Int32.max)
        }

        @Test func frameTraceKeepsFailuresAndReportsBoundedHistoryLoss() throws {
            let trace = SimulatorFrameTrace(limit: 2)
            trace.record(metadata: [
                "sourceReadyAt": 3.0, "capturedAt": 2.0,
                "sourceFrameTrace": ["wordHex": "fedcba9876543210", "copiedWordHex": "0123456789abcdef"],
            ], receivedAt: 4.0, deliveryTiming: [
                "workerSendingAt": 3.5, "clientReceivedAt": 3.75, "clientDecodedAt": 4.25,
            ])
            trace.record(metadata: [:], receivedAt: 5.0)
            trace.record(metadata: [:], receivedAt: 6.0)
            let sample = trace.read()
            #expect(sample.receivedFrames == 3)
            #expect(sample.rows.count == 2)
            #expect(sample.droppedRows == 1)
            #expect(sample.rows[0].sourceAt == 3)
            #expect(sample.rows[0].capturedAt == 2)
            #expect(sample.rows[0].workerSendingAt == 3.5)
            #expect(sample.rows[0].clientReceivedAt == 3.75)
            #expect(sample.rows[0].clientDecodedAt == 4.25)
            #expect(sample.rows[0].wordHex == "fedcba9876543210")
            #expect(sample.rows[0].copiedWordHex == "0123456789abcdef")
            #expect(sample.rows[1].sourceAt == nil)
            #expect(sample.rows[1].workerSendingAt == nil)
            #expect(sample.rows[1].clientReceivedAt == nil)
            #expect(sample.rows[1].clientDecodedAt == nil)
            #expect(sample.rows[1].wordHex == nil)
            let encoded = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
            #expect(encoded.contains("fedcba9876543210"))
            trace.reset()
            #expect(trace.read().rows.isEmpty)
            #expect(trace.read().receivedFrames == 0)
            #expect(trace.read().droppedRows == 0)
        }

        private func activationFixture(system: SimulatorSystemClient) -> (SimulatorCoordinator, SimulatorDeviceHandle) {
            let root = URL(fileURLWithPath: "/unused-activation-test")
            let coordinator = SimulatorCoordinator(root: root, helper: root.appendingPathComponent("helper"),
                runner: .previewValue, system: system)
            let handle = SimulatorDeviceHandle(id: UUID(), udid: UUID().uuidString, name: "Test", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            return (coordinator, handle)
        }

        @Test func expiredActivationWaitDoesNotInspectTheProcess() async {
            let inspections = Mutex(0)
            var system = SimulatorSystemClient()
            system.inspect = { pid in
                inspections.withLock { $0 += 1 }
                return process(pid, name: "codex")
            }
            let (coordinator, handle) = activationFixture(system: system)
            do {
                try await coordinator.waitForApplicationActive(handle, processID: 20, owner: process(10, name: "codex").owner,
                    deadline: .now.advanced(by: .seconds(-1)))
                Issue.record("Expired activation wait succeeded")
            } catch {
                #expect(error.localizedDescription == "Application launched but its Scene did not become active before the deadline")
            }
            #expect(inspections.withLock { $0 } == 0)
        }

        @Test func cancelledActivationWaitDoesNotInspectTheProcess() async {
            let inspections = Mutex(0)
            var system = SimulatorSystemClient()
            system.inspect = { pid in
                inspections.withLock { $0 += 1 }
                return process(pid, name: "codex")
            }
            let (coordinator, handle) = activationFixture(system: system)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await coordinator.waitForApplicationActive(handle, processID: 20, owner: process(10, name: "codex").owner,
                    deadline: .now.advanced(by: .seconds(3)))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(inspections.withLock { $0 } == 0)
        }

        @Test func changedOwnerStopsActivationWaitBeforeStartingAnInspector() async {
            var system = SimulatorSystemClient()
            system.inspect = { pid in process(pid, name: "codex", start: 101) }
            let (coordinator, handle) = activationFixture(system: system)
            do {
                try await coordinator.waitForApplicationActive(handle, processID: 20, owner: process(10, name: "codex").owner,
                    deadline: .now.advanced(by: .seconds(3)))
                Issue.record("Changed owner was accepted")
            } catch {
                #expect(error.localizedDescription == "The owning agent process exited or changed identity")
            }
        }

        @Test(arguments: ["com.other.app: 12345", "com.example.app: 0", "com.example.app: 1", "com.example.app: -2",
            "com.example.app: 2147483648", "com.example.app: 12.5", "com.example.app: 12\ncom.example.app: 34", ""])
        func malformedLaunchOutputCannotSelectAnotherProcess(_ output: String) {
            #expect(throws: SimulatorFailure.self) {
                try SimulatorCoordinator.launchedProcessID(Data(output.utf8), bundle: "com.example.app")
            }
        }

        @Test(arguments: ["claude", "home/.local/share/claude/versions/2.1.276", "Caskroom/claude-code/2.1.276/claude"])
        func nearestAgentOwnsToolCalls(_ claudeExecutable: String) async {
            let entries = [
                process(10, name: "codex"), process(11, parent: 10, name: "sh"), process(20, parent: 11, name: claudeExecutable),
                process(21, parent: 20, name: "python3"),
            ]
            let table = Dictionary(uniqueKeysWithValues: entries.map { ($0.owner.pid, $0) })
            var system = SimulatorSystemClient()
            system.inspect = { pid in
                guard let entry = table[pid] else { throw SimulatorFailure("Exited") }
                return entry
            }
            let outer = await identity(peer: 11, system: system)
            let inner = await identity(peer: 21, system: system)
            #expect(outer.result?["owner"]?.objectValue?["pid"]?.intValue == 10)
            #expect(inner.result?["owner"]?.objectValue?["pid"]?.intValue == 20)
        }

        @Test(arguments: ["other/versions/2.1.276", "claude/versions/helper", "claude/versions/2.1.276/helper", "claude/versions/2x1x276"])
        func unrelatedVersionedExecutableCannotOwnSimulator(_ executable: String) async {
            var system = SimulatorSystemClient()
            system.inspect = { pid in process(pid, name: executable) }
            #expect(!(await identity(peer: 10, system: system)).ok)
        }

        @Test(arguments: ["codex", "home/.local/share/claude/versions/2.1.276"])
        func foreignOrReusedProcessFailsClosed(_ executable: String) async {
            var foreign = SimulatorSystemClient()
            foreign.inspect = { pid in process(pid, name: executable, uid: getuid() + 1) }
            #expect(!(await identity(peer: 10, system: foreign)).ok)
            let count = Mutex(0)
            var reused = SimulatorSystemClient()
            reused.inspect = { pid in
                let call = count.withLock { value in
                    value += 1
                    return value
                }
                return process(pid, name: executable, start: call == 1 ? 100 : 101)
            }
            #expect(!(await identity(peer: 10, system: reused)).ok)
        }

        @Test(arguments: [false, true], [false, true])
        func shutdownDuringBootWaitsForStartupBeforeFinalShutdown(reuse: Bool, cancelCaller: Bool) async throws {
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            defer {
                entered.continuation.finish()
                release.continuation.finish()
            }
            let calls = Mutex<[[String]]>([])
            let preparing = Mutex(false)
            let booted = Mutex(false)
            let shutDownWhilePreparing = Mutex(false)
            let udid = UUID().uuidString
            let inventory = try JSONSerialization.data(withJSONObject: [
                "runtimes": [["isAvailable": true, "platform": "iOS", "version": "27.0", "identifier": "runtime",
                    "supportedDeviceTypes": [["productFamily": "iPhone", "identifier": "iphone", "name": "iPhone"]]]],
                "devices": ["runtime": reuse ? [["isAvailable": true, "state": "Shutdown", "udid": udid,
                    "deviceTypeIdentifier": "iphone", "name": "CtrlX · iPhone"]] : []],
            ])
            let runner = ProcessRunner(run: { executable, arguments, _, _ in
                calls.withLock { $0.append(arguments) }
                if arguments == ["version"] {
                    return ProcessResult(exitCode: 0, stdout: Data("simslim \(SimulatorCoordinator.simslimCommit)".utf8), stderr: Data())
                }
                if executable.hasSuffix("simslim"), arguments.first == "profiles" {
                    return ProcessResult(exitCode: 0, stdout: Data("[{\"id\":\"core\",\"labels\":[\"com.apple.apsd\"]}]".utf8), stderr: Data())
                }
                if arguments.contains("--list") { return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data()) }
                if arguments.contains("list") { return ProcessResult(exitCode: 0, stdout: inventory, stderr: Data()) }
                if arguments.contains("create") { return ProcessResult(exitCode: 0, stdout: Data(udid.utf8), stderr: Data()) }
                if arguments.first == "on" {
                    preparing.withLock { $0 = true }
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                    // A startup command can still boot while its cancellation is settling.
                    booted.withLock { $0 = true }
                    preparing.withLock { $0 = false }
                    try Task.checkCancellation()
                }
                if arguments.suffix(2) == ["shutdown", udid] {
                    if preparing.withLock({ $0 }) { shutDownWhilePreparing.withLock { $0 = true } }
                    booted.withLock { $0 = false }
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            })
            var system = SimulatorSystemClient()
            system.createDirectory = { _ in }
            system.isExecutable = { _ in true }
            system.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
            system.write = { _, _ in }
            system.remove = { _ in }
            let coordinator = SimulatorCoordinator(
                root: URL(fileURLWithPath: "/unused-simulator-test"), helper: URL(fileURLWithPath: "/unused-helper"), runner: runner,
                system: system, resources: SimulatorResourceClient(read: { _ in
                    SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 16 << 30, pressureLevel: 1,
                        swapUsedBytes: 0, freeDiskBytes: 16 << 30)
                }))
            let opening = Task {
                try await coordinator.open(runtime: nil, deviceType: nil, frames: { $0.finish() }, errors: { _ in })
            }
            for await _ in entered.stream { break }
            if cancelCaller {
                opening.cancel()
            } else {
                await coordinator.shutdown()
                #expect(!preparing.withLock { $0 })
                #expect(!booted.withLock { $0 })
            }
            release.continuation.yield(())
            await #expect(throws: CancellationError.self) { try await opening.value }
            #expect(!preparing.withLock { $0 })
            #expect(!booted.withLock { $0 })
            #expect(!shutDownWhilePreparing.withLock { $0 })
            let commands = calls.withLock { $0 }
            #expect(commands.contains { $0.suffix(2) == ["shutdown", udid] })
            #expect(commands.contains { $0.contains("create") } == !reuse)
            #expect(!commands.contains { $0.contains("bootstatus") || $0.contains("bootstrap") })
            await coordinator.shutdown()
            await #expect(throws: SimulatorFailure.self) {
                try await coordinator.open(runtime: nil, deviceType: nil, frames: { $0.finish() }, errors: { _ in })
            }
        }

        enum ClaimControlChange: CaseIterable, Sendable {
            case unchanged, home, touchDown, keyDown, keyUp, modifierDown, modifierUp, close, ownerEnded, competingClaim, cancellationFailed
        }

        private func inputState(
            service: AgentSimulatorService, owner: SimulatorOwner, connection: TestSimulatorConnection
        ) throws -> SimulatorTabState {
            _ = NSApplication.shared
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            view.receive(try TestSimulatorFrame(geometry: SimulatorGeometry(
                width: 320, height: 640, scale: 1, orientation: 1, geometryVersion: 1, epoch: UUID().uuidString)))
            return SimulatorTabState(
                handle: SimulatorDeviceHandle(
                    id: UUID(), udid: UUID().uuidString, name: "Test iPhone", runtime: "fixture", deviceType: "fixture",
                    worker: SimulatorTransport(connection: connection)),
                owner: owner,
                sourcePane: PaneInfo(paneId: "%1", target: "test:0.0", sessionName: "test", windowIndex: 0,
                                     paneIndex: 0, command: "codex", currentPath: "/tmp", width: 80, height: 24, isActive: true),
                workspaceID: UUID(), view: view, service: service)
        }

        @Test(arguments: [false, true])
        func queuedClicksPreserveEveryDownAndUp(_ alreadyManual: Bool) async throws {
            let service = withDependencies {
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: { AgentSimulatorService() }
            let connection = TestSimulatorConnection()
            let state = try inputState(service: service, owner: process(10, name: "codex").owner, connection: connection)
            if alreadyManual { state.writer = nil }
            let gate = AsyncStream<Void>.makeStream()
            state.manualInput = Task { for await _ in gate.stream { break } }
            for x in [10.0, 30.0] {
                service.manualTouch(state, point: SimulatorPoint(x: x, y: 10), phase: 0, receivedAt: 0)
                service.manualTouch(state, point: SimulatorPoint(x: x, y: 10), phase: 2, receivedAt: 0)
            }
            gate.continuation.yield(())
            await state.manualInput?.value
            let commands = connection.commands.withLock { $0 }
            #expect(commands.compactMap { $0["phase"]?.intValue } == [0, 2, 0, 2])
            #expect(commands.compactMap { $0["cancelBeforeTouch"]?.boolValue } == [!alreadyManual, false, false, false])
            let points = try commands.compactMap { try $0["points"]?.decode([SimulatorPoint].self).first }
            let expectedX = [10.0, 10, 30, 30].map { $0 / 320 }
            #expect(points.map(\.x) == expectedX)
            #expect(state.error == nil)
            service.close(state)
            await service.shutdown()
        }

        @Test func queuedDragsCoalesceOnlyBetweenInputBoundaries() async throws {
            let service = withDependencies {
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: { AgentSimulatorService() }
            let connection = TestSimulatorConnection()
            let state = try inputState(service: service, owner: process(10, name: "codex").owner, connection: connection)
            let gate = AsyncStream<Void>.makeStream()
            state.manualInput = Task { for await _ in gate.stream { break } }
            for offset in [0.0, 100.0] {
                service.manualTouch(state, point: SimulatorPoint(x: offset + 10, y: 10), phase: 0, receivedAt: 0)
                service.manualTouch(state, point: SimulatorPoint(x: offset + 20, y: 10), phase: 1, receivedAt: 0)
                service.manualTouch(state, point: SimulatorPoint(x: offset + 30, y: 10), phase: 1, receivedAt: 0)
                service.manualKey(state, usage: 4, down: true)
                service.manualTouch(state, point: SimulatorPoint(x: offset + 40, y: 10), phase: 1, receivedAt: 0)
                service.manualTouch(state, point: SimulatorPoint(x: offset + 50, y: 10), phase: 2, receivedAt: 0)
                service.manualKey(state, usage: 4, down: false)
            }
            gate.continuation.yield(())
            await state.manualInput?.value
            let commands = connection.commands.withLock { $0 }
            #expect(commands.compactMap { $0["command"]?.stringValue }
                == ["touch", "touch", "key", "touch", "touch", "key", "touch", "touch", "key", "touch", "touch", "key"])
            #expect(commands.compactMap { $0["phase"]?.intValue } == [0, 1, 1, 2, 0, 1, 1, 2])
            let points = try commands.compactMap { try $0["points"]?.decode([SimulatorPoint].self).first }
            let expectedX = [10.0, 30, 40, 50, 110, 130, 140, 150].map { $0 / 320 }
            #expect(points.map(\.x) == expectedX)
            #expect(state.pendingMove == nil)
            #expect(state.error == nil)
            service.close(state)
            await service.shutdown()
        }

        @Test(arguments: [UInt16(56), UInt16(60)], [false, true])
        func manualPointerReleasePreservesHeldShiftForFollowingKeys(_ shiftKeyCode: UInt16, releaseOutside: Bool) async throws {
            let service = withDependencies {
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: { AgentSimulatorService() }
            let connection = TestSimulatorConnection()
            let state = try inputState(service: service, owner: process(10, name: "codex").owner, connection: connection)
            state.view.onKey = { [weak state] usage, down in
                guard let state else { return }
                service.manualKey(state, usage: usage, down: down)
            }
            let gate = AsyncStream<Void>.makeStream()
            state.manualInput = Task { for await _ in gate.stream { break } }
            state.view.flagsChanged(with: try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 1, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: shiftKeyCode)))
            service.manualTouch(state, point: SimulatorPoint(x: 10, y: 10), phase: 0, receivedAt: 0)
            if releaseOutside {
                service.manualTouch(state, point: SimulatorPoint(x: 20, y: 20), phase: 1, receivedAt: 0)
            }
            let releasePoint = releaseOutside ? SimulatorPoint(x: -1, y: -1) : SimulatorPoint(x: 10, y: 10)
            service.manualTouch(state, point: releasePoint, phase: 2, receivedAt: 0)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: .shift, timestamp: 2, windowNumber: 0, context: nil,
                    characters: "B", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
                if type == .keyDown { state.view.keyDown(with: event) } else { state.view.keyUp(with: event) }
            }
            state.view.flagsChanged(with: try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 3, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: shiftKeyCode)))
            gate.continuation.yield(())
            await state.manualInput?.value
            let commands = connection.commands.withLock { $0 }
            let shiftUsage = shiftKeyCode == 56 ? 225 : 229
            let pointerCommands = releaseOutside ? ["touch", "touch", "release-touch"] : ["touch", "touch"]
            let expectedCommands = ["cancel", "key"] + pointerCommands + ["key", "key", "key"]
            #expect(commands.compactMap { $0["command"]?.stringValue } == expectedCommands)
            #expect(commands.compactMap { $0["phase"]?.intValue } == (releaseOutside ? [0, 1] : [0, 2]))
            #expect(commands.compactMap { $0["cancelBeforeTouch"]?.boolValue } == [false, false])
            #expect(commands.compactMap { $0["usage"]?.intValue } == [shiftUsage, 5, 5, shiftUsage])
            #expect(commands.compactMap { $0["down"]?.boolValue } == [true, true, false, false])
            #expect(state.error == nil)
            service.close(state)
            await service.shutdown()
        }

        @Test(arguments: [4, 225])
        func keyboardPreservesQueuedDragAndRelease(_ usage: Int) async throws {
            let service = withDependencies {
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: { AgentSimulatorService() }
            let connection = TestSimulatorConnection()
            let state = try inputState(service: service, owner: process(10, name: "codex").owner, connection: connection)
            service.manualTouch(state, point: SimulatorPoint(x: 10, y: 10), phase: 0, receivedAt: 0)
            await state.manualInput?.value

            let moveGate = AsyncStream<Void>.makeStream()
            state.manualInput = Task { for await _ in moveGate.stream { break } }
            service.manualTouch(state, point: SimulatorPoint(x: 20, y: 20), phase: 1, receivedAt: 0)
            service.manualTouch(state, point: SimulatorPoint(x: 30, y: 30), phase: 1, receivedAt: 0)
            service.manualKey(state, usage: usage, down: true)
            moveGate.continuation.yield(())
            await state.manualInput?.value
            #expect(state.pendingMove == nil)
            #expect(connection.commands.withLock { $0.compactMap { $0["phase"]?.intValue } } == [0, 1])

            service.manualTouch(state, point: SimulatorPoint(x: 40, y: 40), phase: 1, receivedAt: 0)
            await state.manualInput?.value
            #expect(connection.commands.withLock { $0.compactMap { $0["phase"]?.intValue } } == [0, 1, 1])

            let releaseGate = AsyncStream<Void>.makeStream()
            state.manualInput = Task { for await _ in releaseGate.stream { break } }
            service.manualTouch(state, point: SimulatorPoint(x: 50, y: 50), phase: 2, receivedAt: 0)
            service.manualKey(state, usage: usage, down: false)
            releaseGate.continuation.yield(())
            await state.manualInput?.value
            let commands = connection.commands.withLock { $0 }
            #expect(commands.compactMap { $0["command"]?.stringValue } == ["touch", "touch", "key", "touch", "touch", "key"])
            #expect(commands.compactMap { $0["phase"]?.intValue } == [0, 1, 1, 2])
            #expect(commands.compactMap { $0["down"]?.boolValue } == [true, false])
            #expect(state.writer == nil)
            #expect(state.error == nil)
            service.close(state)
            await service.shutdown()
        }

        @Test(arguments: [false, true])
        func claimDrainsManualInputBeforeGrantingControl(_ newerInput: Bool) async throws {
            let owner = process(10, name: "codex").owner
            let service = withDependencies {
                var system = SimulatorSystemClient()
                system.inspect = { _ in SimulatorProcess(owner: owner, parentPID: 1, executable: "/fixture/codex") }
                $0[SimulatorSystemClient.self] = system
            } operation: { AgentSimulatorService() }
            let connection = TestSimulatorConnection()
            let state = try inputState(service: service, owner: owner, connection: connection)
            state.writer = nil
            let manualGate = AsyncStream<Void>.makeStream()
            state.manualInput = Task { for await _ in manualGate.stream { break } }
            service.manualKey(state, usage: 4, down: true)
            service.manualHome(state)
            service.manualKey(state, usage: 4, down: false)
            let started = AsyncStream<Void>.makeStream()
            let claim = Task {
                started.continuation.yield(())
                try await service.claimWriter(state) {
                    #expect(!newerInput)
                    #expect(connection.commands.withLock { $0.compactMap { $0["command"]?.stringValue } }
                        == ["key", "cancel", "button", "button", "key"])
                    _ = try await state.handle.worker.request(["command": .string("cancel")])
                }
                #expect(state.writer == owner)
                _ = try await state.handle.worker.request(["command": .string("key"), "usage": .int(5), "down": .bool(true)])
            }
            for await _ in started.stream { break }
            if newerInput { service.manualKey(state, usage: 225, down: true) }
            let tail = state.manualInput
            manualGate.continuation.yield(())
            if newerInput {
                await #expect(throws: SimulatorFailure.self) { try await claim.value }
                #expect(state.writer == nil)
            } else {
                try await claim.value
                #expect(state.writer == owner)
            }
            await tail?.value
            let commands = connection.commands.withLock { $0 }
            #expect(commands.compactMap { $0["command"]?.stringValue }
                == (newerInput ? ["key", "cancel", "button", "button", "key", "key"]
                    : ["key", "cancel", "button", "button", "key", "cancel", "key"]))
            #expect(commands.last?["usage"] == .int(newerInput ? 225 : 5))
            #expect(!state.writing)
            #expect(state.error == nil)
            service.close(state)
            await service.shutdown()
        }

        @Test(arguments: ClaimControlChange.allCases)
        func pendingClaimPreservesNewerControl(_ change: ClaimControlChange) async throws {
            let owner = process(10, name: "codex").owner
            let inspectedOwner = Mutex(owner)
            let service = withDependencies {
                var system = SimulatorSystemClient()
                system.inspect = { _ in
                    SimulatorProcess(owner: inspectedOwner.withLock { $0 }, parentPID: 1, executable: "/fixture/codex")
                }
                $0[SimulatorSystemClient.self] = system
            } operation: { AgentSimulatorService() }
            let state = try inputState(service: service, owner: owner, connection: TestSimulatorConnection())
            state.writer = nil
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let claim = Task {
                try await service.claimWriter(state) {
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                    if change == .cancellationFailed { throw SimulatorFailure("Input cancellation failed") }
                }
            }
            for await _ in entered.stream { break }
            #expect(state.writing)
            switch change {
            case .home: service.manualHome(state)
            case .touchDown: service.manualTouch(state, point: SimulatorPoint(x: 10, y: 10), phase: 0, receivedAt: 0)
            case .keyDown: service.manualKey(state, usage: 4, down: true)
            case .keyUp: service.manualKey(state, usage: 4, down: false)
            case .modifierDown: service.manualKey(state, usage: 225, down: true)
            case .modifierUp: service.manualKey(state, usage: 225, down: false)
            case .close: service.close(state)
            case .ownerEnded:
                inspectedOwner.withLock {
                    $0 = SimulatorOwner(pid: owner.pid, uid: owner.uid, startSeconds: owner.startSeconds + 1,
                                        startMicros: owner.startMicros)
                }
            case .competingClaim:
                await #expect(throws: SimulatorFailure.self) {
                    try await service.claimWriter(state) { Issue.record("A second claim sent input cancellation") }
                }
            case .unchanged, .cancellationFailed: break
            }
            release.continuation.yield(())
            if change == .unchanged || change == .competingClaim {
                try await claim.value
                #expect(state.writer == owner)
                #expect(state.generation == 1)
            } else {
                await #expect(throws: SimulatorFailure.self) { try await claim.value }
                if [.home, .touchDown, .keyDown, .keyUp, .modifierDown, .modifierUp, .close].contains(change) {
                    #expect(state.writer == nil)
                }
            }
            #expect(!state.writing)
            if let manualInput = state.manualInput { await manualInput.value }
            service.close(state)
            await service.shutdown()
        }

        @Test func nativeViewFillsTabContentWithoutSimulatorRuntime() throws {
            _ = NSApplication.shared
            let metal = try #require(MTLCreateSystemDefaultDevice())
            let view = try SimulatorMetalView(metal: metal)
            let handle = SimulatorDeviceHandle(
                id: UUID(), udid: UUID().uuidString, name: "Test iPhone", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            let service = withDependencies {
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: {
                AgentSimulatorService()
            }
            let state = SimulatorTabState(
                handle: handle, owner: SimulatorOwner(pid: 10, uid: getuid(), startSeconds: 100, startMicros: 42),
                sourcePane: PaneInfo(paneId: "%1", target: "test:0.0", sessionName: "test", windowIndex: 0,
                                     paneIndex: 0, command: "codex", currentPath: "/tmp", width: 80, height: 24, isActive: true),
                workspaceID: UUID(), view: view, service: service)
            let window = NSWindow(
                contentRect: CGRect(x: -10000, y: -10000, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SimulatorTabContentView(state: state, workspaceID: state.workspaceID))
            window.contentView?.layoutSubtreeIfNeeded()
            defer {
                view.close()
                window.close()
            }
            #expect(view.window === window)
            #expect(view.bounds.width > 500)
            #expect(view.bounds.height > 350)
        }

        @Test func nativeViewMovesBetweenSwiftUIHostsWithoutSimulatorRuntime() throws {
            _ = NSApplication.shared
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            let handle = SimulatorDeviceHandle(
                id: UUID(), udid: UUID().uuidString, name: "Test iPhone", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            let service = withDependencies {
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: {
                AgentSimulatorService()
            }
            let state = SimulatorTabState(
                handle: handle, owner: SimulatorOwner(pid: 10, uid: getuid(), startSeconds: 100, startMicros: 42),
                sourcePane: PaneInfo(paneId: "%1", target: "test:0.0", sessionName: "test", windowIndex: 0,
                                     paneIndex: 0, command: "codex", currentPath: "/tmp", width: 80, height: 24, isActive: true),
                workspaceID: UUID(), view: view, service: service)
            let window = TestVisibleSimulatorWindow(
                contentRect: CGRect(x: -10000, y: -10000, width: 600, height: 500),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: TestSimulatorPlacement(state: state, trailing: false))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            defer {
                view.close()
                window.close()
            }
            let originalParent = try #require(view.superview)
            #expect(view.window === window)
            for trailing in [true, false, true] {
                host.rootView = TestSimulatorPlacement(state: state, trailing: trailing)
                host.layoutSubtreeIfNeeded()
                #expect(view.window === window)
                #expect(view.superview !== originalParent)
                #expect(view.bounds.width > 0 && view.bounds.height > 0)
            }
        }

        @Test func drawableTracksPhoneViewportAcrossRotationAndResize() throws {
            _ = NSApplication.shared
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            let window = NSWindow(
                contentRect: CGRect(x: -10000, y: -10000, width: 1200, height: 800),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer {
                view.close()
                window.close()
            }
            let epoch = UUID().uuidString
            let cases: [(CGSize, Int, CGRect)] = [
                (CGSize(width: 1200, height: 800), 1, CGRect(x: 400, y: 0, width: 400, height: 800)),
                (CGSize(width: 1200, height: 800), 2, CGRect(x: 400, y: 0, width: 400, height: 800)),
                (CGSize(width: 1200, height: 800), 3, CGRect(x: 0, y: 100, width: 1200, height: 600)),
                (CGSize(width: 1200, height: 800), 4, CGRect(x: 0, y: 100, width: 1200, height: 600)),
                (CGSize(width: 600, height: 500), 1, CGRect(x: 175, y: 0, width: 250, height: 500)),
                (CGSize(width: 600, height: 500), 3, CGRect(x: 0, y: 100, width: 600, height: 300)),
            ]
            for (size, orientation, expectedFrame) in cases {
                window.setContentSize(size)
                let frame = try TestSimulatorFrame(geometry: SimulatorGeometry(
                    width: 320, height: 640, scale: 1, orientation: orientation, geometryVersion: 1, epoch: epoch))
                view.receive(frame)
                view.layout()
                let display = try #require(view.layer?.sublayers?.compactMap { $0 as? CAMetalLayer }.first)
                #expect(view.bounds.size == size)
                #expect(display.frame == expectedFrame)
                #expect(view.renderState.drawableSize == CGSize(
                    width: expectedFrame.width * window.backingScaleFactor,
                    height: expectedFrame.height * window.backingScaleFactor))
                #expect(view.displaySyncEnabled)
                #expect(frame.finishCount == 1)
            }
        }

        @Test(arguments: [false, true])
        func closedRendererIgnoresLateFramesAndLayout(_ malformed: Bool) throws {
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            let geometry = SimulatorGeometry(
                width: 320, height: 640, scale: 1, orientation: 1, geometryVersion: 1, epoch: UUID().uuidString)
            let initial = try TestSimulatorFrame(geometry: geometry)
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            view.receive(initial)
            #expect(initial.finishCount == 1)
            #expect(view.geometry == geometry)
            var errors: [String] = []
            var inputCancellations = 0
            view.onError = { errors.append($0) }
            view.onCancelInput = { inputCancellations += 1 }
            view.close()
            let closedGeneration = view.renderState.generation
            let closedDrawableSize = view.renderState.drawableSize
            let closedCancellations = inputCancellations

            let late = try TestSimulatorFrame(geometry: SimulatorGeometry(
                width: malformed ? 0 : 320, height: 640, scale: 1, orientation: 4,
                geometryVersion: 2, epoch: geometry.epoch))
            view.receive(late)
            view.setFrameSize(CGSize(width: 800, height: 400))
            view.layout()
            view.viewDidChangeBackingProperties()
            view.viewDidMoveToWindow()
            view.setDisplayMode(.lowLatency)
            view.close()

            #expect(late.finishCount == 1)
            #expect(view.geometry == geometry)
            #expect(view.renderState.generation == closedGeneration)
            #expect(view.renderState.drawableSize == closedDrawableSize)
            #expect(view.displaySyncEnabled)
            #expect(!view.inputReady)
            #expect(inputCancellations == closedCancellations)
            #expect(errors.isEmpty)
        }

        @Test func keyboardModifiersAreRecoveredFromKeyEvents() throws {
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            defer { view.close() }
            var events: [(Int, Bool)] = []
            view.onKey = { events.append(($0, $1)) }
            let down = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 1, windowNumber: 0, context: nil,
                characters: "B", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
            let up = try #require(NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil,
                characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
            view.keyDown(with: down)
            view.keyUp(with: up)
            #expect(events.map(\.0) == [225, 5, 225, 5])
            #expect(events.map(\.1) == [true, true, false, false])
        }

        @Test
        func annotationSuppressesNativeKeyboardAndReleasesFocus() throws {
            _ = NSApplication.shared
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { view.close()
                window.close()
            }
            #expect(window.makeFirstResponder(view))
            var events: [Int] = []
            var cancellations = 0
            view.onKey = { usage, _ in events.append(usage) }
            view.onCancelInput = { cancellations += 1 }
            let down = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 1, windowNumber: window.windowNumber, context: nil,
                characters: "B", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
            ))
            let up = try #require(NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil,
                characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
            ))
            let modifier = try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 3, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
            ))
            view.keyDown(with: down)
            events.removeAll()
            let generation = view.renderState.generation
            view.setInputSuppressed(true)
            #expect(window.firstResponder !== view && view.isInputSuppressed)
            #expect(cancellations == 1)
            view.keyUp(with: up)
            view.keyDown(with: down)
            view.flagsChanged(with: modifier)
            view.setInputSuppressed(true)
            #expect(events.isEmpty && cancellations == 1)
            #expect(view.renderState.generation == generation)
            #expect(view.window === window)
            view.setInputSuppressed(false)
            view.keyDown(with: down)
            view.keyUp(with: up)
            #expect(events == [225, 5, 225, 5])
        }

        @Test func initialUnknownOrientationWaitsForValidGeometry() throws {
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            defer { view.close() }
            var errors: [String] = []
            view.onError = { errors.append($0) }
            let epoch = UUID().uuidString
            let initial = try TestSimulatorFrame(geometry: SimulatorGeometry(
                width: 1179, height: 2556, scale: 3, orientation: 0, geometryVersion: 3, epoch: epoch))
            view.receive(initial)
            #expect(initial.finishCount == 1)
            #expect(view.geometry == nil)
            #expect(!view.inputReady)
            #expect(errors.isEmpty)

            let geometry = SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: 1, geometryVersion: 4, epoch: epoch)
            let ready = try TestSimulatorFrame(geometry: geometry)
            view.receive(ready)
            #expect(ready.finishCount == 1)
            #expect(view.geometry == geometry)
            #expect(errors.isEmpty)

            view.receive(initial)
            #expect(initial.finishCount == 2)
            #expect(errors == ["Invalid simulator display geometry"])
        }

        @Test func initialUnknownOrientationDoesNotHideMalformedGeometry() throws {
            let view = try SimulatorMetalView(metal: #require(MTLCreateSystemDefaultDevice()))
            defer { view.close() }
            var errors: [String] = []
            view.onError = { errors.append($0) }
            let frame = try TestSimulatorFrame(geometry: SimulatorGeometry(
                width: 0, height: 2556, scale: 3, orientation: 0, geometryVersion: 3, epoch: UUID().uuidString))
            view.receive(frame)
            #expect(frame.finishCount == 1)
            #expect(view.geometry == nil)
            #expect(!view.inputReady)
            #expect(errors == ["Invalid simulator display geometry"])
        }

        @Test func presentationRecoveryWaitsForBothCompletedCommands() {
            var gate = SimulatorPresentationGate()
            let first = gate.submit()
            let second = gate.submit()
            gate.completed(first, generation: 0, at: 10)
            #expect(!gate.needsRecovery(at: 100))
            gate.completed(second, generation: 0, at: 10.1)
            #expect(!gate.needsRecovery(at: 10.34))
            #expect(gate.needsRecovery(at: 10.36))
        }

        @Test func contentsLayoutMatchesInputCoordinatesAcrossOrientations() throws {
            for orientation in 1...4 {
                let geometry = SimulatorGeometry(width: 1170, height: 2532, scale: 3,
                    orientation: orientation, geometryVersion: 1, epoch: UUID().uuidString)
                for bounds in [CGRect(x: 0, y: 0, width: 401, height: 930),
                    CGRect(x: 0, y: 0, width: 1100, height: 650),
                    CGRect(x: 20, y: 10, width: 320, height: 480)] {
                    let layout = SimulatorContentsLayout(bounds: bounds, geometry: geometry)
                    let centered = CGRect(x: -layout.contentsSize.width / 2, y: -layout.contentsSize.height / 2,
                        width: layout.contentsSize.width, height: layout.contentsSize.height).applying(layout.transform)
                    #expect(abs(centered.width - layout.viewport.width) < 0.000001)
                    #expect(abs(centered.height - layout.viewport.height) < 0.000001)
                    #expect(layout.viewport.midX == bounds.midX && layout.viewport.midY == bounds.midY)
                    for source in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.5, y: 0.5)] {
                        let offset = CGPoint(x: (source.x - 0.5) * layout.contentsSize.width,
                            y: (source.y - 0.5) * layout.contentsSize.height).applying(layout.transform)
                        let displayed = SimulatorPoint(x: (offset.x / layout.viewport.width + 0.5) * geometry.displayWidth,
                            y: (offset.y / layout.viewport.height + 0.5) * geometry.displayHeight)
                        let restored = try geometry.normalizedDevicePoint(displayed)
                        #expect(abs(restored.x - source.x) < 0.000001 && abs(restored.y - source.y) < 0.000001)
                    }
                }
            }
        }

        @Test func presentationRecoveryIncludesThreeDrawables() {
            var gate = SimulatorPresentationGate()
            let first = gate.submit()
            let second = gate.submit()
            let third = gate.submit()
            gate.completed(first, generation: 0, at: 10)
            gate.completed(second, generation: 0, at: 10.1)
            #expect(!gate.allGPUCompleted)
            #expect(!gate.needsRecovery(at: 100))
            gate.completed(third, generation: 0, at: 10.2)
            #expect(gate.allGPUCompleted)
            #expect(!gate.needsRecovery(at: 10.44))
            #expect(gate.needsRecovery(at: 10.46))
        }

        @Test func ordinaryPresentationKeepsAdmissionAvailable() {
            var gate = SimulatorPresentationGate()
            let first = gate.submit()
            let second = gate.submit()
            gate.completed(first, generation: 0, at: 10)
            gate.completed(second, generation: 0, at: 10)
            let firstPresented = gate.presented(first, generation: 0)
            #expect(firstPresented)
            #expect(gate.inFlight == 1)
            #expect(!gate.needsRecovery(at: 100))
            let next = gate.submit()
            #expect(!gate.needsRecovery(at: 100))
            let nextPresented = gate.presented(next, generation: 0)
            #expect(nextPresented)
            let duplicatePresented = gate.presented(next, generation: 0)
            #expect(!duplicatePresented)
            #expect(gate.inFlight == 1)
        }

        @Test func stalePresentationDoesNotRetireNewGeneration() {
            var gate = SimulatorPresentationGate()
            let old = gate.submit()
            gate.invalidate()
            let current = gate.submit()
            #expect(gate.generation == 1)
            let oldPresented = gate.presented(old, generation: 0)
            #expect(!oldPresented)
            #expect(gate.inFlight == 1)
            let currentPresented = gate.presented(current, generation: 1)
            #expect(currentPresented)
            #expect(gate.inFlight == 0)
        }

        @Test func staleGPUCompletionDoesNotTriggerRecovery() {
            var gate = SimulatorPresentationGate()
            let old = gate.submit()
            gate.invalidate()
            let first = gate.submit()
            let second = gate.submit()
            gate.completed(old, generation: 0, at: 1)
            gate.completed(first, generation: 0, at: 1)
            gate.completed(second, generation: 1, at: 1)
            #expect(!gate.needsRecovery(at: 100))
            gate.completed(first, generation: 1, at: 2)
            #expect(gate.needsRecovery(at: 100))
        }

        @Test func renderLifecycleKeepsTransportAndSourceIdentitiesDistinct() throws {
            let lifecycle = SimulatorRenderLifecycle()
            let first = lifecycle.submit(drawableID: 1, generation: 1, at: 1,
                metadata: ["sequence": NSNumber(value: 25156), "sourceSequence": NSNumber(value: 25270)])
            let second = lifecycle.submit(drawableID: 2, generation: 1, at: 2,
                metadata: ["sequence": NSNumber(value: 25157), "sourceSequence": NSNumber(value: 25270)])
            let unknown = lifecycle.submit(drawableID: 3, generation: 1, at: 3, metadata: [:])
            lifecycle.presented(second, at: 2.01, callbackAt: 2.02)
            lifecycle.presented(first, at: 1.01, callbackAt: 2.03)
            let rows = lifecycle.read().rows
            #expect(rows.map(\.sequence) == [25156, 25157, nil])
            #expect(rows.map(\.sourceSequence) == [25270, 25270, nil])
            #expect(try #require(rows.first { $0.id == first }).presentedAt == 1.01)
            #expect(try #require(rows.first { $0.id == second }).presentedAt == 2.01)
            #expect(try #require(rows.first { $0.id == unknown }).presentedAt == 0)
        }

        @Test func renderLifecyclePreservesPerFrameDisplayChanges() throws {
            let lifecycle = SimulatorRenderLifecycle()
            let firstDisplay = SimulatorDisplayCondition(
                displayID: 1, maximumFPS: 120, contentsScale: 2, drawableSize: CGSize(width: 764, height: 1658))
            let secondDisplay = SimulatorDisplayCondition(
                displayID: 2, maximumFPS: 60, contentsScale: 2, drawableSize: CGSize(width: 764, height: 1658))
            let first = lifecycle.submit(drawableID: 1, generation: 1, at: 1, metadata: [:], displayCondition: firstDisplay)
            let second = lifecycle.submit(drawableID: 2, generation: 1, at: 2, metadata: [:], displayCondition: secondDisplay)
            _ = lifecycle.submit(drawableID: 3, generation: 1, at: 3, metadata: [:], displayCondition: firstDisplay)
            _ = lifecycle.submit(drawableID: 4, generation: 1, at: 4, metadata: [:])
            lifecycle.presented(second, at: 2.1, callbackAt: 2.2)
            lifecycle.presented(first, at: 1.1, callbackAt: 2.3)
            #expect(lifecycle.read().rows.map(\.displayCondition) == [firstDisplay, secondDisplay, firstDisplay, nil])
        }

        @Test func renderLifecycleRejectsLateCallbacksAfterHistoryWraps() throws {
            let lifecycle = SimulatorRenderLifecycle(historyLimit: 3)
            for index in 1...10 {
                _ = lifecycle.submit(drawableID: index, generation: 1, at: Double(index), metadata: [:])
            }
            let before = lifecycle.read()
            #expect(before.rows.map(\.id) == [8, 9, 10])
            #expect(before.historyLimit == 3 && before.overwrittenRows == 7)
            lifecycle.committed(8, at: 8.01)
            lifecycle.completed(8, start: 8.02, end: 8.03, status: 4, error: nil, callbackAt: 8.04)
            lifecycle.completionMainActor(8, at: 8.05)
            lifecycle.presented(8, at: 8.06, callbackAt: 8.07)
            lifecycle.presentationMainActor(8, at: 8.08)
            // ID 5 occupied the same slot before ID 8; its delayed callbacks cannot overwrite ID 8.
            lifecycle.committed(5, at: 50)
            lifecycle.completed(5, start: 50, end: 51, status: 5, error: "old", callbackAt: 52)
            lifecycle.completionMainActor(5, at: 53)
            lifecycle.presented(5, at: 54, callbackAt: 55)
            lifecycle.presentationMainActor(5, at: 56)
            let after = lifecycle.read()
            let row = try #require(after.rows.first { $0.id == 8 })
            #expect(row.commitReturnedAt == 8.01 && row.gpuStartedAt == 8.02 && row.gpuEndedAt == 8.03)
            #expect(row.gpuCallbackAt == 8.04 && row.gpuMainActorAt == 8.05 && row.gpuStatus == 4 && row.error == nil)
            #expect(row.presentedAt == 8.06 && row.presentationCallbackAt == 8.07 && row.presentationMainActorAt == 8.08)
            #expect(after.rows.map(\.id) == [8, 9, 10])
            #expect(before.rows.allSatisfy { $0.presentedAt == 0 })
            #expect(after.completed == 2 && after.failed == 1 && after.presentationCallbacks == 2)
        }

        @Test func displayMeasurementsRemainCurrentDuringLongRuns() {
            let measurements = SimulatorDisplayMeasurements()
            for index in 1...6100 {
                let source = Double(index)
                let delay = index <= 100 ? 0.2 : 0.01
                measurements.recordRenderTimes([
                    source, source + 0.001, source + 0.002, source + delay, source + delay + 0.001, source + delay + 0.002,
                ])
                measurements.record(sequence: UInt64(index), sourceSequence: UInt64(index),
                    times: [source, source, source, source, source, source + delay],
                    copyStages: [delay * 1000, 1, 2, 3])
            }
            let sample = measurements.read()
            #expect(sample.frames == 6100)
            #expect(sample.milliseconds.count == 6000)
            #expect(sample.milliseconds.allSatisfy { abs($0 - 10) < 0.001 })
            #expect(sample.copyRecords == 6100)
            #expect(sample.copyStages.allSatisfy { $0.count == 6000 })
            #expect(sample.copyStages[0].allSatisfy { abs($0 - 10) < 0.001 })
            #expect(sample.renderRecords == 6100)
            #expect(sample.renderStages.allSatisfy { $0.count == 6000 })
            #expect(sample.renderStages[2].allSatisfy { abs($0 - 8) < 0.001 })
            measurements.reset()
            let reset = measurements.read()
            measurements.record(sequence: 6101, sourceSequence: 6101,
                times: Array(repeating: reset.startedAt - 1, count: 6))
            #expect(measurements.read().frames == 0)
            #expect(measurements.read().sourceSequence == 6100)
        }

        @Test func displayFPSIncludesTimeAfterPresentationsStop() {
            let sample = SimulatorDisplayMeasurements.Sample(
                frames: 60, firstTime: 100.01, lastTime: 101, startedAt: 100)
            #expect(sample.uniqueFPS(at: 101) == 60)
            #expect(sample.elapsed(at: 110) == 10)
            #expect(sample.uniqueFPS(at: 110) == 6)
        }

        @Test func displayFPSWithoutResetIncludesIdleTime() {
            let sample = SimulatorDisplayMeasurements.Sample(frames: 61, firstTime: 100, lastTime: 101)
            #expect(sample.uniqueFPS(at: 101) == 60)
            #expect(sample.uniqueFPS(at: 110) == 6)
            #expect(sample.uniqueFPS(at: 100) == 0)
            #expect(SimulatorDisplayMeasurements.Sample().uniqueFPS(at: 110) == 0)
        }
    }
#endif
