#if os(macOS)
    import CtrlxCommon
    import CtrlxSimulatorProtocol
    import Foundation
    import Synchronization
    import Testing
    @testable import CtrlxServerFeature

    struct SimulatorCapacityTests {
        @Test func configurationPersistsAndRejectsInvalidUpdates() async throws {
            let contents = Mutex<Data?>(nil)
            var system = SimulatorSystemClient()
            system.createDirectory = { _ in }
            system.read = { _ in
                guard let data = contents.withLock({ $0 }) else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            }
            system.write = { data, _ in contents.withLock { $0 = data } }
            let root = URL(fileURLWithPath: "/unused-capacity-test")
            let helper = root.appendingPathComponent("helper")
            let first = SimulatorCoordinator(root: root, helper: helper, runner: .previewValue, system: system)
            #expect(try await first.configuration().maximumDevices == 2)
            #expect(try await first.configuration(maximumDevices: 12).maximumDevices == 12)
            await #expect(throws: SimulatorFailure.self) { try await first.configuration(maximumDevices: 33) }
            let second = SimulatorCoordinator(root: root, helper: helper, runner: .previewValue, system: system)
            #expect(try await second.configuration().maximumDevices == 12)
        }

        @Test func memoryPressureRejectsBeforeCreatingOrBootingADevice() async {
            let calls = Mutex(0)
            let runner = ProcessRunner(run: { _, _, _, _ in
                calls.withLock { $0 += 1 }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            })
            var system = SimulatorSystemClient()
            system.createDirectory = { _ in }
            system.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
            let resources = SimulatorResourceClient(read: { _ in
                SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 8 << 30, pressureLevel: 2,
                    swapUsedBytes: 0, freeDiskBytes: 8 << 30)
            })
            let coordinator = SimulatorCoordinator(root: URL(fileURLWithPath: "/unused-capacity-test"),
                helper: URL(fileURLWithPath: "/unused-helper"), runner: runner, system: system, resources: resources)
            await #expect(throws: SimulatorFailure.self) {
                try await coordinator.open(runtime: nil, deviceType: nil, frames: { $0.finish() }, errors: { _ in })
            }
            #expect(calls.withLock { $0 } == 0)
        }

        @Test func balancedProfileRetainsCoreServicesAndDeclaredFeatures() throws {
            let core = ["com.apple.apsd", "com.apple.storekitd", "com.apple.swcd", "com.apple.assetsd", "com.apple.corespeechd"]
            let categories = [
                SimulatorSlimCategory(id: "widgets", labels: ["com.apple.PosterBoard", "com.apple.chronod", "com.apple.liveactivitiesd"]),
                SimulatorSlimCategory(id: "other", labels: Array(SimulatorSlimProfile.balancedDisabled) + core),
            ]
            let features = [SimulatorSlimFeature(id: "widgets", labels: ["com.apple.chronod", "com.apple.liveactivitiesd"])]
            let balanced = try SimulatorSlimProfile(selection: .balanced, requires: [], categories: categories, features: features)
            #expect(Set(core).isSubset(of: Set(balanced.keep)))
            #expect(!balanced.keep.contains("com.apple.PosterBoard"))
            let widgets = try SimulatorSlimProfile(selection: .balanced, requires: ["widgets"], categories: categories, features: features)
            #expect(Set(categories[0].labels).isSubset(of: Set(widgets.keep)))
            #expect(throws: SimulatorFailure.self) {
                try SimulatorSlimProfile(selection: .balanced, requires: ["unknown"], categories: categories, features: features)
            }
            let standard = try SimulatorSlimProfile(selection: .standard, requires: [], categories: categories, features: features)
            #expect(Set(standard.keep) == Set(categories.flatMap(\.labels)))
        }

        @Test(arguments: ["open", "quit"], ["Booted", "Shutdown", "Shutting Down", "shutdown fails"])
        func failedShutdownRemainsOwnedUntilReconciled(action: String, recovery: String) async throws {
            let udid = UUID().uuidString
            let calls = Mutex<[[String]]>([])
            let state = Mutex("Shutdown")
            let shutdowns = Mutex(0)
            let resourceReads = Mutex(0)
            let recoveryFails = Mutex(false)
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                calls.withLock { $0.append(arguments) }
                let stdout: Data
                if arguments == ["version"] {
                    stdout = Data("simslim \(SimulatorCoordinator.simslimCommit)".utf8)
                } else if arguments.first == "profiles" {
                    stdout = Data("[{\"id\":\"core\",\"labels\":[\"com.apple.apsd\"]}]".utf8)
                } else if arguments.contains("--list") {
                    stdout = Data("[]".utf8)
                } else if arguments.contains("list") {
                    stdout = try JSONSerialization.data(withJSONObject: [
                        "runtimes": [["isAvailable": true, "platform": "iOS", "version": "27.0", "identifier": "runtime",
                            "supportedDeviceTypes": [["productFamily": "iPhone", "identifier": "iphone", "name": "iPhone"]]]],
                        "devices": ["runtime": [["isAvailable": true, "state": state.withLock { $0 }, "udid": udid,
                            "deviceTypeIdentifier": "iphone", "name": "CtrlX · iPhone"]]],
                    ])
                } else if arguments.first == "on" {
                    state.withLock { $0 = "Booted" }
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Preparation failed after boot".utf8))
                } else if arguments.suffix(2) == ["shutdown", udid] {
                    let attempt = shutdowns.withLock { $0 += 1; return $0 }
                    if attempt == 1 || recoveryFails.withLock({ $0 }) { throw ProcessRunnerError.timeout }
                    state.withLock { $0 = "Shutdown" }
                    stdout = Data()
                } else {
                    Issue.record("Unexpected command: \(arguments)")
                    stdout = Data()
                }
                return ProcessResult(exitCode: 0, stdout: stdout, stderr: Data())
            })
            var system = SimulatorSystemClient()
            system.createDirectory = { _ in }
            system.isExecutable = { _ in true }
            system.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
            system.write = { _, _ in }
            system.remove = { _ in }
            let resources = SimulatorResourceClient(read: { _ in
                let count = resourceReads.withLock { $0 += 1; return $0 }
                return SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 8 << 30,
                    pressureLevel: count == 1 ? 1 : 2, swapUsedBytes: 0, freeDiskBytes: 8 << 30)
            })
            let coordinator = SimulatorCoordinator(root: URL(fileURLWithPath: "/unused-capacity-test"),
                helper: URL(fileURLWithPath: "/unused-helper"), runner: runner, system: system, resources: resources)
            await #expect(throws: SimulatorFailure.self) {
                try await coordinator.open(runtime: nil, deviceType: nil, frames: { $0.finish() }, errors: { _ in })
            }
            #expect(shutdowns.withLock { $0 } == 1)
            state.withLock { $0 = recovery == "shutdown fails" ? "Booted" : recovery }
            recoveryFails.withLock { $0 = recovery == "shutdown fails" }
            if action == "open" {
                await #expect(throws: (any Error).self) {
                    try await coordinator.open(runtime: nil, deviceType: nil, frames: { $0.finish() }, errors: { _ in })
                }
            } else {
                await coordinator.shutdown()
            }
            #expect(calls.withLock { $0.filter { $0.contains("list") && !$0.contains("--list") }.count } == 2)
            #expect(calls.withLock { $0.filter { $0.first == "on" }.count } == 1)
            #expect(shutdowns.withLock { $0 } == (recovery == "Booted" || recovery == "shutdown fails" ? 2 : 1))
            if recovery == "Shutting Down" || recovery == "shutdown fails" {
                state.withLock { $0 = "Booted" }
                recoveryFails.withLock { $0 = false }
            }
            await coordinator.shutdown()
            #expect(state.withLock { $0 } == "Shutdown")
            #expect(shutdowns.withLock { $0 } == (recovery == "Shutdown" ? 1 : recovery == "shutdown fails" ? 3 : 2))
        }

        @Test(arguments: ["memory", "disk", "profile"]) func preparationFailureShutsDownNewDevice(failure: String) async throws {
            let udid = UUID().uuidString
            let calls = Mutex<[[String]]>([])
            let reads = Mutex(0)
            let inventory = try JSONSerialization.data(withJSONObject: [
                "runtimes": [["isAvailable": true, "platform": "iOS", "version": "18.5", "identifier": "runtime",
                    "supportedDeviceTypes": [["productFamily": "iPhone", "identifier": "iphone", "name": "iPhone"]]]],
                "devices": ["runtime": [["isAvailable": true, "state": "Shutdown", "udid": udid,
                    "deviceTypeIdentifier": "iphone", "name": "CtrlX · iPhone"]]],
            ])
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                calls.withLock { $0.append(arguments) }
                let stdout: Data
                if arguments == ["version"] {
                    stdout = Data("simslim \(SimulatorCoordinator.simslimCommit)".utf8)
                } else if arguments.first == "profiles" {
                    stdout = Data("[{\"id\":\"core\",\"labels\":[\"com.apple.apsd\"]}]".utf8)
                } else if arguments.contains("--list") {
                    stdout = Data("[]".utf8)
                } else if arguments.contains("list") {
                    stdout = inventory
                } else if arguments.first == "on", failure == "profile" {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Service overrides did not survive boot".utf8))
                } else {
                    stdout = Data()
                }
                return ProcessResult(exitCode: 0, stdout: stdout, stderr: Data())
            })
            var system = SimulatorSystemClient()
            system.createDirectory = { _ in }
            system.isExecutable = { _ in true }
            system.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
            system.write = { _, _ in }
            system.remove = { _ in }
            let resources = SimulatorResourceClient(read: { _ in
                let count = reads.withLock { $0 += 1; return $0 }
                return SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 8 << 30,
                    pressureLevel: count > 1 && failure == "memory" ? 2 : 1, swapUsedBytes: 0,
                    freeDiskBytes: count > 1 && failure == "disk" ? 512 << 20 : 8 << 30)
            })
            let coordinator = SimulatorCoordinator(root: URL(fileURLWithPath: "/unused-capacity-test"),
                helper: URL(fileURLWithPath: "/unused-helper"), runner: runner, system: system, resources: resources)
            await #expect(throws: SimulatorFailure.self) {
                try await coordinator.open(runtime: nil, deviceType: nil, frames: { $0.finish() }, errors: { _ in })
            }
            let commands = calls.withLock { $0 }
            #expect(reads.withLock { $0 } == (failure == "profile" ? 1 : 2))
            #expect(commands.contains { $0.first == "on" })
            #expect(commands.contains { $0.suffix(2) == ["shutdown", udid] })
            #expect(!commands.contains { $0.contains("bootstrap") || $0.contains("xcodebuild") })
        }
    }
#endif
