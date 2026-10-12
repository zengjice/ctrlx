#if os(macOS)
    import Clocks
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxNetworking
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import Foundation
    import Synchronization
    import Testing
    @testable import CtrlxServerFeature

    struct SimulatorStorageTests {
        private let root = URL(fileURLWithPath: "/unused storage test")
        private let udid = "00000000-0000-0000-0000-000000000001"
        private let owner = SimulatorOwner(pid: 10, uid: getuid(), startSeconds: 100, startMicros: 1)

        private func inventory(state: String = "Shutdown", present: Bool = true) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "runtimes": [["isAvailable": true, "platform": "iOS", "version": "27.0", "identifier": "runtime",
                    "supportedDeviceTypes": [["productFamily": "iPhone", "identifier": "iphone", "name": "iPhone"]]]],
                "devices": ["runtime": present ? [["udid": udid, "name": "CtrlX · iPhone", "state": state,
                    "deviceTypeIdentifier": "iphone", "isAvailable": true]] : []],
            ])
        }

        private func system() -> SimulatorSystemClient {
            var value = SimulatorSystemClient()
            value.createDirectory = { _ in }
            value.inspect = { _ in SimulatorProcess(owner: owner, parentPID: 1, executable: "/fixture/codex") }
            value.isExecutable = { _ in true }
            value.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
            return value
        }

        private func coordinator(_ runner: ProcessRunner, system supplied: SimulatorSystemClient? = nil) -> SimulatorCoordinator {
            SimulatorCoordinator(root: root, helper: root.appendingPathComponent("helper"), runner: runner,
                system: supplied ?? system(), resources: SimulatorResourceClient(read: { _ in
                    SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 16 << 30, pressureLevel: 1,
                        swapUsedBytes: 0, freeDiskBytes: 16 << 30)
                }))
        }

        @Test(arguments: ["ok", "failure", "truncated"])
        func storageReportsAllocatedBytesWithoutTreatingFailedMeasurementAsZero(_ outcome: String) async throws {
            let data = try inventory()
            let path = root.appendingPathComponent("devices").appendingPathComponent(udid).path
            let runner = ProcessRunner(run: { executable, arguments, _, _ in
                #expect(executable == "/usr/bin/xcrun")
                #expect(arguments == ["simctl", "--set", root.appendingPathComponent("devices").path, "list", "-j"])
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            }, runBounded: { executable, arguments, _, timeout, maximumBytes in
                #expect(executable == "/usr/bin/du")
                #expect(arguments == ["-sk", path])
                #expect(timeout == 15)
                #expect(maximumBytes == 65536)
                return ProcessResult(exitCode: outcome == "failure" ? 1 : 0, stdout: Data("2048\t\(path)\n".utf8),
                    stderr: Data(), outputTruncated: outcome == "truncated")
            })
            let response = try await coordinator(runner).storage()
            let rows = try #require(try response["devices"]?.decode([[String: JSONValue]].self))
            #expect(rows.count == 1)
            #expect(rows[0]["canModify"] == .bool(true))
            #expect(rows[0]["inUse"] == .bool(false))
            #expect(rows[0]["allocatedBytes"] == (outcome == "ok" ? .int(2048 * 1024) : .null))
            #expect((response["diskUsageError"] == nil) == (outcome == "ok"))
        }

        @Test(arguments: [SimulatorOperation.erase, .delete])
        func changesOnlyTheNamedPrivateDevice(_ operation: SimulatorOperation) async throws {
            let data = try inventory()
            let calls = Mutex<[[String]]>([])
            let runner = ProcessRunner(run: { executable, arguments, _, _ in
                #expect(executable == "/usr/bin/xcrun")
                calls.withLock { $0.append(arguments) }
                return ProcessResult(exitCode: 0, stdout: arguments.contains("list") ? data : Data(), stderr: Data())
            })
            let result = try await coordinator(runner).modifyStorage(operation, udid: udid.lowercased(), owner: owner)
            #expect(result[operation == .erase ? "erased" : "deleted"] == .bool(true))
            #expect(calls.withLock { $0 } == [
                ["simctl", "--set", root.appendingPathComponent("devices").path, "list", "-j"],
                ["simctl", "--set", root.appendingPathComponent("devices").path, operation.rawValue, udid],
            ])
        }

        @Test(arguments: ["missing", "Booted", "Shutting Down", "all", "../outside", "owner-exited"], [SimulatorOperation.erase, .delete])
        func rejectsUnownedBusyAndBroadTargets(_ scenario: String, _ operation: SimulatorOperation) async throws {
            let data = try inventory(state: scenario == "Booted" || scenario == "Shutting Down" ? scenario : "Shutdown", present: scenario != "missing")
            let writes = Mutex(0)
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                if !arguments.contains("list") { writes.withLock { $0 += 1 } }
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            })
            var client = system()
            if scenario == "owner-exited" { client.inspect = { _ in throw SimulatorFailure("Owner exited") } }
            let target = scenario == "all" || scenario == "../outside" ? scenario : udid
            await #expect(throws: SimulatorFailure.self) {
                _ = try await coordinator(runner, system: client).modifyStorage(operation, udid: target, owner: owner)
            }
            #expect(writes.withLock { $0 } == 0)
        }

        @Test(arguments: [SimulatorOperation.erase, .delete])
        func failedWritesAreNotRetriedAndReleaseTheReservation(_ operation: SimulatorOperation) async throws {
            let data = try inventory()
            let writes = Mutex(0)
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                if arguments.contains(operation.rawValue) {
                    writes.withLock { $0 += 1 }
                    throw ProcessRunnerError.timeout
                }
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            })
            let coordinator = coordinator(runner)
            await #expect(throws: ProcessRunnerError.self) {
                _ = try await coordinator.modifyStorage(operation, udid: udid, owner: owner)
            }
            #expect(writes.withLock { $0 } == 1)
            let rows = try #require(try await coordinator.storage()["devices"]?.decode([[String: JSONValue]].self))
            #expect(rows[0]["inUse"] == .bool(false))
        }

        @Test func deletionCompletesBeforeReopenCanSelectTheDevice() async throws {
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let present = Mutex(true)
            let deleting = Mutex(false)
            let readDuringDelete = Mutex(false)
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                if arguments.contains("delete") {
                    deleting.withLock { $0 = true }
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                    present.withLock { $0 = false }
                    deleting.withLock { $0 = false }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                #expect(arguments.contains("list"))
                if deleting.withLock({ $0 }) { readDuringDelete.withLock { $0 = true } }
                return ProcessResult(exitCode: 0, stdout: try inventory(present: present.withLock { $0 }), stderr: Data())
            })
            let coordinator = coordinator(runner)
            let deletion = Task { try await coordinator.modifyStorage(.delete, udid: udid, owner: owner) }
            for await _ in entered.stream { break }
            let opening = Task { try await coordinator.open(runtime: nil, deviceType: nil, udid: udid, frames: { $0.finish() }, errors: { _ in }) }
            for _ in 0..<20 { await Task.yield() }
            release.continuation.yield(())
            _ = try await deletion.value
            await #expect(throws: SimulatorFailure.self) { _ = try await opening.value }
            #expect(!readDuringDelete.withLock { $0 })
            await coordinator.shutdown()
        }

        @Test func explicitReopenSelectsTheRequestedDeviceInsteadOfTheFirstReusableOne() async throws {
            var data = try #require(try JSONSerialization.jsonObject(with: inventory()) as? [String: Any])
            var groups = try #require(data["devices"] as? [String: [[String: Any]]])
            var decoy = try #require(groups["runtime"]?.first)
            decoy["udid"] = UUID().uuidString
            groups["runtime"]?.insert(decoy, at: 0)
            data["devices"] = groups
            let listing = try JSONSerialization.data(withJSONObject: data)
            let calls = Mutex<[[String]]>([])
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                calls.withLock { $0.append(arguments) }
                let stdout: Data
                if arguments.contains("list") { stdout = listing }
                else if arguments == ["version"] { stdout = Data("simslim \(SimulatorCoordinator.simslimCommit)".utf8) }
                else if arguments.first == "profiles" { stdout = Data("[{\"id\":\"core\",\"labels\":[\"com.apple.apsd\"]}]".utf8) }
                else if arguments.contains("--list") { stdout = Data("[]".utf8) }
                else if arguments.first == "on" {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Stop before worker launch".utf8))
                } else { stdout = Data() }
                return ProcessResult(exitCode: 0, stdout: stdout, stderr: Data())
            })
            var client = system()
            client.write = { _, _ in }
            client.remove = { _ in }
            let coordinator = coordinator(runner, system: client)
            await #expect(throws: SimulatorFailure.self) {
                _ = try await coordinator.open(runtime: nil, deviceType: nil, udid: udid, frames: { $0.finish() }, errors: { _ in })
            }
            let commands = calls.withLock { $0 }
            #expect(commands.first { $0.first == "on" }?[1] == udid)
            #expect(!commands.contains { $0.contains("create") })
            #expect(commands.contains { $0.suffix(2) == ["shutdown", udid] })
        }

        @Test func shutdownWaitsForStorageChangesAndRejectsLaterOnes() async throws {
            let data = try inventory()
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let finished = Mutex(false)
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                if arguments.contains("erase") {
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                    finished.withLock { $0 = true }
                }
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            })
            let coordinator = coordinator(runner)
            let erase = Task { try await coordinator.modifyStorage(.erase, udid: udid, owner: owner) }
            for await _ in entered.stream { break }
            let shutdown = Task {
                await coordinator.shutdown()
                #expect(finished.withLock { $0 })
            }
            for _ in 0..<20 { await Task.yield() }
            release.continuation.yield(())
            _ = try await erase.value
            await shutdown.value
            await #expect(throws: SimulatorFailure.self) {
                _ = try await coordinator.modifyStorage(.delete, udid: udid, owner: owner)
            }
        }

        @Test(arguments: [SimulatorOperation.erase, .delete])
        func shutdownCancelsActiveAndQueuedStorageBeforeWaiting(_ operation: SimulatorOperation) async throws {
            try await withMainSerialExecutor {
                let data = try inventory()
                let clock = TestClock()
                let entered = AsyncStream<Void>.makeStream()
                let release = AsyncStream<Void>.makeStream()
                let reap = Task { for await _ in release.stream { break } }
                let cancelled = LockIsolated(false)
                let completed = LockIsolated(false)
                let writes = LockIsolated(0)
                let runner = ProcessRunner(run: { _, arguments, _, _ in
                    if arguments.contains(operation.rawValue) {
                        writes.withValue { $0 += 1 }
                        entered.continuation.yield(())
                        do {
                            try await clock.sleep(for: .seconds(120))
                        } catch {
                            cancelled.setValue(true)
                            await reap.value
                            throw error
                        }
                    }
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                })
                let coordinator = coordinator(runner)
                let first = Task { try await coordinator.modifyStorage(operation, udid: udid, owner: owner) }
                for await _ in entered.stream { break }
                let queued = Task { try await coordinator.modifyStorage(operation, udid: udid, owner: owner) }
                await Task.megaYield()
                let shutdown = Task {
                    await coordinator.shutdown()
                    completed.setValue(true)
                }
                await Task.megaYield()
                #expect(cancelled.value)
                #expect(!completed.value)
                release.continuation.yield(())
                await clock.advance(by: .seconds(120))
                await #expect(throws: CancellationError.self) { _ = try await first.value }
                await #expect(throws: (any Error).self) { _ = try await queued.value }
                await shutdown.value
                #expect(writes.value == 1)
                await #expect(throws: SimulatorFailure.self) {
                    _ = try await coordinator.modifyStorage(operation, udid: udid, owner: owner)
                }
            }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_SIMULATOR_STORAGE_FIXTURE"] != nil))
        func nativeUninstallEraseAndDeleteRoundTrip() async throws {
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
            } operation: { try await runNativeStorageRoundTrip() }
        }

        private func runNativeStorageRoundTrip() async throws {
            let app = try #require(ProcessInfo.processInfo.environment["CTRLX_SIMULATOR_STORAGE_FIXTURE"])
            let plist = try #require(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: URL(fileURLWithPath: app).appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
            let bundle = try #require(plist["CFBundleIdentifier"] as? String)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-storage-smoke-\(UUID().uuidString)")
            print("Simulator storage smoke root: \(root.path)")
            let coordinator = SimulatorCoordinator(root: root, helper: root.appendingPathComponent("unused-helper"),
                runner: .liveValue, system: .liveValue)
            let owner = try SimulatorSystemClient.liveValue.inspect(getpid()).owner
            let inventory = try await coordinator.inventory()
            let runtimes = try #require(try inventory["runtimes"]?.decode([[String: JSONValue]].self))
            let runtime = try #require(runtimes.first { $0["version"]?.stringValue == "27.0" && $0["isAvailable"] == .bool(true) })
            let runtimeID = try #require(runtime["identifier"]?.stringValue)
            let types = try #require(try runtime["supportedDeviceTypes"]?.decode([[String: JSONValue]].self))
            let typeID = try #require(types.first { $0["name"] == .string("iPhone 16") }?["identifier"]?.stringValue)
            let udid = try await coordinator.simctl(["create", "CtrlX Storage Smoke", typeID, runtimeID]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let handle = SimulatorDeviceHandle(id: UUID(), udid: udid, name: "Storage smoke", runtime: runtimeID, deviceType: typeID,
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.unused", frames: { $0.finish() }))
            var failure: (any Error)?
            do {
                _ = try await coordinator.simctl(["boot", udid])
                _ = try await coordinator.simctl(["bootstatus", udid, "-b"], timeout: 180)
                try await coordinator.install(handle, app: app)
                _ = try await coordinator.simctl(["get_app_container", udid, bundle, "app"])
                try await coordinator.uninstall(handle, bundle: bundle)
                await #expect(throws: SimulatorFailure.self) {
                    _ = try await coordinator.simctl(["get_app_container", udid, bundle, "app"])
                }
                try await coordinator.install(handle, app: app)
                let container = try await coordinator.simctl(["get_app_container", udid, bundle, "data"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                let marker = URL(fileURLWithPath: container).appendingPathComponent("Documents/storage-smoke.txt")
                try Data("erase me".utf8).write(to: marker)
                await #expect(throws: SimulatorFailure.self) {
                    _ = try await coordinator.modifyStorage(.delete, udid: udid, owner: owner)
                }
                _ = try await coordinator.simctl(["shutdown", udid])
                let rows = try #require(try await coordinator.storage()["devices"]?.decode([[String: JSONValue]].self))
                #expect(rows.count == 1)
                #expect((rows[0]["allocatedBytes"]?.intValue ?? 0) > 0)
                #expect(rows[0]["canModify"] == .bool(true))
                _ = try await coordinator.modifyStorage(.erase, udid: udid, owner: owner)
                #expect(!FileManager.default.fileExists(atPath: marker.path))
                _ = try await coordinator.simctl(["boot", udid])
                _ = try await coordinator.simctl(["bootstatus", udid, "-b"], timeout: 180)
                await #expect(throws: SimulatorFailure.self) {
                    _ = try await coordinator.simctl(["get_app_container", udid, bundle, "app"])
                }
                _ = try await coordinator.simctl(["shutdown", udid])
                _ = try await coordinator.modifyStorage(.delete, udid: udid, owner: owner)
                let finalRows = try #require(try await coordinator.storage()["devices"]?.decode([[String: JSONValue]].self))
                #expect(finalRows.isEmpty)
            } catch { failure = error }
            let remaining = try await coordinator.inventory()["devices"]?.objectValue?.values.flatMap { value -> [JSONValue] in
                guard case let .array(rows) = value else { return [] }
                return rows
            }.first { $0.objectValue?["udid"] == .string(udid) }
            if let remaining {
                if remaining.objectValue?["state"] != .string("Shutdown") { _ = try await coordinator.simctl(["shutdown", udid]) }
                _ = try await coordinator.modifyStorage(.delete, udid: udid, owner: owner)
            }
            try FileManager.default.removeItem(at: root)
            if let failure { throw failure }
        }
    }
#endif
