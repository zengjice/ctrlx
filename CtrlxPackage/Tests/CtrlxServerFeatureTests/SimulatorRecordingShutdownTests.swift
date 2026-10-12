#if os(macOS)
    import AppKit
    import Clocks
    import CtrlxCommon
    import CtrlxNetworking
    @preconcurrency import CtrlxSimulatorBridge
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    private final class RecordingShutdownConnection: CXSimulatorConnection, @unchecked Sendable {
        override func invalidate() {}
        override func request(_: Data, reply: @escaping CXSimulatorDataReply) { reply(Data("{}".utf8), nil) }
    }

    @Suite(.serialized)
    @MainActor
    struct SimulatorRecordingShutdownTests {
        @Test(arguments: ["recording", "shutdown"])
        func existingCloseDoesNotDelayOtherRecorders(_ blockedPhase: String) async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-record-shutdown-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let first = UUID().uuidString
            let second = UUID().uuidString
            let release = root.appendingPathComponent("release")
            let blocked = root.appendingPathComponent("blocked")
            let inventory = try JSONSerialization.data(withJSONObject: [
                "runtimes": [["isAvailable": true, "platform": "iOS", "version": "27.0", "identifier": "runtime",
                    "supportedDeviceTypes": [["productFamily": "iPhone", "identifier": "iphone", "name": "iPhone"]]]],
                "devices": ["runtime": [first, second].map { udid in
                    ["isAvailable": true, "state": "Shutdown", "udid": udid,
                        "deviceTypeIdentifier": "iphone", "name": "CtrlX · iPhone"] as [String: Any]
                }],
            ])
            let runner = ProcessRunner(run: { _, arguments, _, _ in
                let output: Data
                if arguments == ["version"] { output = Data("simslim \(SimulatorCoordinator.simslimCommit)".utf8) }
                else if arguments.first == "profiles" { output = Data("[{\"id\":\"core\",\"labels\":[\"com.apple.apsd\"]}]".utf8) }
                else if arguments.contains("--list") { output = Data("[]".utf8) }
                else if arguments.contains("list") { output = inventory }
                else if arguments == ["--find", "xcodebuild"] { output = Data("/fixture/Xcode.app/Contents/Developer/usr/bin/xcodebuild".utf8) }
                else { output = Data() }
                if blockedPhase == "shutdown", arguments.suffix(2) == ["shutdown", first] {
                    try Data().write(to: blocked)
                    while !FileManager.default.fileExists(atPath: release.path) { try await Task.sleep(for: .milliseconds(20)) }
                }
                return ProcessResult(exitCode: 0, stdout: output, stderr: Data())
            })
            var system = SimulatorSystemClient()
            system.createDirectory = { _ in }
            system.isExecutable = { _ in true }
            system.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
            system.write = { _, _ in }
            system.remove = { _ in }
            system.inspect = { pid in
                SimulatorProcess(owner: SimulatorOwner(pid: pid, uid: getuid(), startSeconds: 100, startMicros: 1),
                    parentPID: 1, executable: "/fixture/codex")
            }
            system.connect = { _, _, _ in SimulatorTransport(connection: RecordingShutdownConnection()) }
            let script = """
            import os, signal, sys, time
            stopped, blocked, release, wait, path = sys.argv[1:]
            def finish(*_):
                open(stopped, 'w').close()
                if wait == 'yes':
                    open(blocked, 'w').close()
                    while not os.path.exists(release): time.sleep(.02)
                with open(path, 'ab') as f: f.write(b'finalized')
                sys.exit(0)
            signal.signal(signal.SIGINT, finish)
            with open(path, 'wb') as f: f.write(b'frames')
            print('Recording started', file=sys.stderr, flush=True)
            while True: time.sleep(.02)
            """
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
                $0[ProcessRunner.self] = runner
                $0[SimulatorSystemClient.self] = system
                $0[SimulatorResourceClient.self] = SimulatorResourceClient(read: { _ in
                    SimulatorResources(physicalBytes: 32 << 30, reclaimableBytes: 16 << 30, pressureLevel: 1,
                        swapUsedBytes: 0, freeDiskBytes: 16 << 30)
                })
                $0[SimulatorRecordingClient.self] = SimulatorRecordingClient(make: { _, udid, options in
                    SimulatorRecorder(options: options, executable: "/usr/bin/python3", arguments: ["-c", script,
                        root.appendingPathComponent(udid + ".stopped").path, blocked.path, release.path,
                        udid == first && blockedPhase == "recording" ? "yes" : "no"])
                })
            } operation: {
                let service = AgentSimulatorService()
                let pane = PaneInfo(paneId: "%1", target: "record:0.0", sessionName: "record", windowIndex: 0,
                    paneIndex: 0, command: "codex", currentPath: root.path, width: 80, height: 24, isActive: true)
                service.start(root: root, resolvePane: { _ in pane })
                let workspace = SimulatorWorkspace()
                workspace.acceptsPane = { _ in true }
                var tabs: [SimulatorTabState] = []
                workspace.onCreate = { tabs.append($0) }
                service.register(workspace)
                func action(_ command: String, _ parameters: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
                    var params = parameters
                    params["command"] = .string(command)
                    params["_peerPID"] = .int(10)
                    let result = await service.handle(JSONRPCRequest(id: UUID().uuidString, method: "simulator.action", params: params))
                    try #require(result.ok, "\(result.error?.message ?? "Simulator request failed")")
                    return result.result ?? [:]
                }
                func waitFor(_ path: URL) async throws -> Bool {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while !FileManager.default.fileExists(atPath: path.path), ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    return FileManager.default.fileExists(atPath: path.path)
                }
                do {
                    for udid in [first, second] {
                        let opened = try await action("open", ["udid": .string(udid)])
                        let id = try #require(opened["device"])
                        _ = try await action("record-start", ["device": id,
                            "output": .string(root.appendingPathComponent(udid + ".mp4").path)])
                    }
                    let firstTab = try #require(tabs.first)
                    service.close(firstTab)
                    #expect(try await waitFor(blocked))
                    let shutdown = Task { await service.shutdown() }
                    let secondMovie = root.appendingPathComponent(second + ".mp4")
                    #expect(try await waitFor(secondMovie), "The other recorder must finish while the existing close remains blocked")
                    #expect(!FileManager.default.fileExists(atPath: release.path))
                    try Data().write(to: release)
                    await shutdown.value
                    for udid in [first, second] {
                        #expect(try Data(contentsOf: root.appendingPathComponent(udid + ".mp4")) == Data("framesfinalized".utf8))
                    }
                } catch {
                    try Data().write(to: release)
                    await service.shutdown()
                    throw error
                }
            }
        }
    }
#endif
