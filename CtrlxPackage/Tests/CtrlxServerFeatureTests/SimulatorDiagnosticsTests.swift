#if os(macOS)
    import CtrlxCommon
    import CtrlxSimulatorProtocol
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct SimulatorDiagnosticsTests {
        @Test(arguments: [false, true])
        func logsFilterByInstalledApplicationAndBoundRetention(privatePath: Bool) async throws {
            let root = URL(fileURLWithPath: privatePath ? "/tmp/ctrlx-diagnostics-\(UUID().uuidString)" : "/unused-diagnostics")
            let logRoot = privatePath ? URL(fileURLWithPath: "/private" + root.path) : root
            let app = logRoot.appendingPathComponent("devices/device/data/Test App.app")
            if privatePath { try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true) }
            defer { if privatePath { try? FileManager.default.removeItem(at: root) } }
            let imageID = "27546B46-5476-3EE0-8BD4-552D302C13DE"
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.example.test", "CFBundleExecutable": "Test App",
            ], format: .xml, options: 0)
            var system = SimulatorSystemClient()
            system.readPrefix = { url, limit in
                #expect(url == app.appendingPathComponent("Info.plist"))
                #expect(limit == 128 * 1024)
                return plist
            }
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                #expect(arguments.suffix(4) == ["get_app_container", "device", "com.example.test", "app"])
                return ProcessResult(exitCode: 0, stdout: Data((app.path + "\n").utf8), stderr: Data())
            }, runBounded: { executable, arguments, _, timeout, limit in
                if executable == "/usr/bin/dwarfdump" {
                    #expect(arguments == ["--uuid", app.appendingPathComponent("Test App").path])
                    #expect(timeout == 5 && limit == 16384)
                    return ProcessResult(exitCode: 0, stdout: Data("UUID: \(imageID) (arm64) \(app.path)\n".utf8), stderr: Data())
                }
                #expect(executable == "/usr/bin/xcrun")
                #expect(arguments.prefix(5) == ["simctl", "--set", root.appendingPathComponent("devices").path, "spawn", "device"])
                #expect(arguments.contains("30s"))
                #expect(arguments.contains("ndjson"))
                let predicate = NSPredicate(format: try #require(arguments.last))
                let oldPath = logRoot.appendingPathComponent("devices/device/data/Old Container/Test App.app/Test App").path
                #expect(predicate.evaluate(with: ["processImagePath": oldPath,
                                                  "processImageUUID": imageID]))
                #expect(!predicate.evaluate(with: ["processImagePath": logRoot.appendingPathComponent("devices/other/data/Test App.app/Test App").path,
                                                   "processImageUUID": imageID]))
                #expect(timeout == 15 && limit == 1024)
                let own = try JSONSerialization.data(withJSONObject: ["processImagePath": oldPath, "processImageUUID": imageID,
                                                                      "eventMessage": "测试 🙂", "timestamp": "2026-10-07", "processID": 123])
                let other = try JSONSerialization.data(withJSONObject: ["processImagePath": oldPath, "processImageUUID": UUID().uuidString,
                                                                        "eventMessage": "other app secret", "processID": 456])
                return ProcessResult(exitCode: 0, stdout: (own + Data([10]) + other + Data([10])).prefix(limit), stderr: Data(), outputTruncated: true)
            })
            let coordinator = SimulatorCoordinator(root: root, helper: root.appendingPathComponent("helper"), runner: runner, system: system)
            let handle = SimulatorDeviceHandle(id: UUID(), udid: "device", name: "Test", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            let result = try await coordinator.logs(handle, request: SimulatorLogRequest(bundle: "com.example.test", maximumBytes: 1024))
            #expect(result["text"]?.stringValue?.contains("测试 🙂") == true)
            #expect(result["text"]?.stringValue?.contains("secret") == false)
            #expect((result["text"]?.stringValue?.utf8.count ?? 0) <= 1024)
            #expect(result["truncated"] == .bool(true))
        }

        @Test func crashReportsAreDeviceAndBundleScopedAndShareOneByteBudget() async throws {
            let root = URL(fileURLWithPath: "/unused-diagnostics")
            let directory = root.appendingPathComponent("devices/device/data/Library/Logs/CrashReporter")
            let host = root.appendingPathComponent("host")
            let now = Date()
            let own = directory.appendingPathComponent("Test.ips")
            let other = directory.appendingPathComponent("Other.ips")
            var system = SimulatorSystemClient()
            system.diagnosticFiles = { url in
                if url.path == host.path { return [] }
                #expect(url.path == directory.path)
                return [SimulatorDiagnosticFile(url: other, modifiedAt: now), SimulatorDiagnosticFile(url: own, modifiedAt: now.addingTimeInterval(-1))]
            }
            system.readPrefix = { url, limit in
                let text = url == own ? "{\"bundleID\":\"com.example.test\"}\n" + String(repeating: "diagnostic", count: 1000)
                    : "{\"bundleID\":\"com.example.other\"}\nother app secret"
                #expect(limit <= 16384)
                return Data(text.utf8).prefix(limit)
            }
            let coordinator = SimulatorCoordinator(root: root, helper: root.appendingPathComponent("helper"), runner: ProcessRunner(), system: system,
                                                   hostDiagnostics: host)
            let handle = SimulatorDeviceHandle(id: UUID(), udid: "device", name: "Test", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            let result = try await coordinator.crashes(handle, request: SimulatorCrashRequest(bundle: "com.example.test", maximumBytes: 100))
            guard case let .array(reports) = result["reports"] else {
                Issue.record("Missing report array")
                return
            }
            #expect(reports.count == 1)
            let report = try #require(reports.first?.objectValue)
            #expect(report["file"] == .string("Test.ips"))
            #expect(report["text"]?.stringValue?.utf8.count == 100)
            #expect(report["truncated"] == .bool(true))
            #expect(result["truncated"] == .bool(true))
        }

        @Test func hostCrashReportsRequireBundleAndExactSimulatorCoalition() async throws {
            let root = URL(fileURLWithPath: "/unused-diagnostics")
            let host = root.appendingPathComponent("host")
            let now = Date()
            let fixtures: [(String, String, String, Int)] = [
                ("own", "com.example.test", "com.apple.CoreSimulator.SimDevice.device", 7),
                ("other-device", "com.example.test", "com.apple.CoreSimulator.SimDevice.other-device", 7),
                ("prefix-device", "com.example.test", "com.apple.CoreSimulator.SimDevice.device-extra", 7),
                ("other-bundle", "com.example.other", "com.apple.CoreSimulator.SimDevice.device", 7),
                ("native", "com.example.test", "com.apple.CoreSimulator.SimDevice.device", 1),
            ]
            let data = try Dictionary(uniqueKeysWithValues: fixtures.map { name, bundle, coalition, platform in
                let header = try JSONSerialization.data(withJSONObject: ["bundleID": bundle, "platform": platform])
                let body = try JSONSerialization.data(withJSONObject: ["coalitionName": coalition, "procPath": "/private/tmp/*/Test.app/Test",
                                                                       "exception": ["signal": "SIGABRT"]])
                return (host.appendingPathComponent(name + ".ips"), header + Data([10]) + body)
            })
            var system = SimulatorSystemClient()
            system.diagnosticFiles = { url in
                url.path == host.path ? data.keys.map { SimulatorDiagnosticFile(url: $0, modifiedAt: now) } : []
            }
            system.readPrefix = { url, limit in
                try #require(data[url]).prefix(limit)
            }
            let coordinator = SimulatorCoordinator(root: root, helper: root.appendingPathComponent("helper"), runner: ProcessRunner(), system: system,
                                                   hostDiagnostics: host)
            let handle = SimulatorDeviceHandle(id: UUID(), udid: "device", name: "Test", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            let result = try await coordinator.crashes(handle, request: SimulatorCrashRequest(bundle: "com.example.test", maximumBytes: 100))
            guard case let .array(reports) = result["reports"] else {
                Issue.record("Missing report array")
                return
            }
            #expect(reports.count == 1)
            #expect(reports.first?.objectValue?["file"] == .string("own.ips"))
            #expect(reports.first?.objectValue?["text"]?.stringValue?.utf8.count == 100)
            #expect(result["truncated"] == .bool(true))
        }

        @Test func oversizedHostCrashScopeIsNotReturnedAndIsMarkedIncomplete() async throws {
            let root = URL(fileURLWithPath: "/unused-diagnostics")
            let host = root.appendingPathComponent("host")
            let file = host.appendingPathComponent("large.ips")
            let data = Data(("{\"bundleID\":\"com.example.test\",\"platform\":7}\n" + String(repeating: "x", count: 1024 * 1024)).utf8)
            var system = SimulatorSystemClient()
            system.diagnosticFiles = { url in
                url.path == host.path ? [SimulatorDiagnosticFile(url: file, modifiedAt: Date())] : []
            }
            system.readPrefix = { _, limit in
                #expect(limit <= 1024 * 1024 + 1)
                return data.prefix(limit)
            }
            let coordinator = SimulatorCoordinator(root: root, helper: root.appendingPathComponent("helper"), runner: ProcessRunner(), system: system,
                                                   hostDiagnostics: host)
            let handle = SimulatorDeviceHandle(id: UUID(), udid: "device", name: "Test", runtime: "fixture", deviceType: "fixture",
                worker: SimulatorTransport(serviceName: "com.ctrlx.test.absent", frames: { $0.finish() }))
            let result = try await coordinator.crashes(handle, request: SimulatorCrashRequest(bundle: "com.example.test"))
            #expect(result["reports"] == .array([]))
            #expect(result["truncated"] == .bool(true))
        }
    }
#endif
