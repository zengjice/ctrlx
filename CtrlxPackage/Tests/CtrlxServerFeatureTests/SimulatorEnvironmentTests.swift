#if os(macOS)
    import CtrlxCommon
    import CtrlxSimulatorProtocol
    import Foundation
    import Synchronization
    import Testing
    @testable import CtrlxServerFeature

    struct SimulatorEnvironmentCoordinatorTests {
        @Test(arguments: [false, true]) func pushPayloadIsRemovedAfterSuccessOrFailure(fail: Bool) async throws {
            let files = Mutex<[URL: Data]>([:])
            let calls = Mutex<[[String]]>([])
            let payload = Data("{\"aps\":{\"alert\":\"测试 🙂\"}}".utf8)
            var system = SimulatorSystemClient()
            system.createDirectory = { _ in }
            system.write = { data, url in files.withLock { $0[url] = data } }
            system.remove = { url in _ = files.withLock { $0.removeValue(forKey: url) } }
            let runner = ProcessRunner(run: { executable, arguments, _, _ in
                calls.withLock { $0.append(arguments) }
                #expect(executable == "/usr/bin/xcrun")
                let file = try #require(arguments.last)
                #expect(files.withLock { $0[URL(fileURLWithPath: file)] } == payload)
                return ProcessResult(exitCode: fail ? 1 : 0, stdout: Data(), stderr: Data("push rejected".utf8))
            })
            let root = URL(fileURLWithPath: "/unused-environment-test")
            let coordinator = SimulatorCoordinator(root: root, helper: root.appendingPathComponent("helper"), runner: runner, system: system)
            let handle = SimulatorDeviceHandle(id: UUID(), udid: UUID().uuidString, name: "Test", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            let notification = try SimulatorPushNotification(bundle: "com.example.app", payload: payload)
            if fail {
                await #expect(throws: SimulatorFailure.self) { try await coordinator.push(handle, notification: notification) }
            } else {
                try await coordinator.push(handle, notification: notification)
            }
            #expect(files.withLock { $0.isEmpty })
            let arguments = try #require(calls.withLock { $0.first })
            #expect(Array(arguments.prefix(6)) == ["simctl", "--set", root.appendingPathComponent("devices").path, "push", handle.udid, notification.bundle])
            #expect(calls.withLock { $0.count } == 1)
        }
    }
#endif
