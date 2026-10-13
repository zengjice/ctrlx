#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import ImageIO
    import Testing
    @testable import CtrlxServerFeature

    /// Opt in with the freshly built helper. Uses a new private device set and deletes it after shutdown.
    @Suite(.serialized)
    struct SimulatorPreviewIntegrationTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_SIMULATOR_PREVIEW_HELPER"] != nil))
        func realHelperPreviewsHeadlessAndSubscribedDevices() async throws {
            try await withDependencies {
                $0.context = .live
            } operation: {
                try await runPreview()
            }
        }

        private func runPreview() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["CTRLX_SIMULATOR_PREVIEW_HELPER"])
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-preview-\(UUID().uuidString)")
            let coordinator = SimulatorCoordinator(
                root: root,
                helper: URL(fileURLWithPath: path),
                runner: .liveValue,
                system: .liveValue
            )
            var failure: (any Error)?
            var deviceID: String?
            do {
                let handle = try await coordinator.open(
                    runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                    deviceType: nil,
                    frames: { $0.finish() },
                    errors: { print("Preview helper: \($0)") }
                )
                deviceID = handle.udid
                for subscribed in [false, true] {
                    if subscribed {
                        _ = try await handle.worker.request(["command": .string("subscribe")])
                    }
                    for dimension in [512, 1_024, 2_560] {
                        let result = try await handle.worker.request([
                            "command": .string("preview"),
                            "maximumDimension": .int(dimension),
                            "timeoutSeconds": .int(5),
                            "readOnly": .bool(true),
                        ])
                        let encoded = try #require(result["data"]?.stringValue)
                        let data = try #require(Data(base64Encoded: encoded))
                        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                        #expect(data.count <= RemoteSimulatorFrame.maximumBytes)
                        #expect(max(image.width, image.height) <= dimension)
                        #expect(image.width == result["width"]?.intValue && image.height == result["height"]?.intValue)
                        print("Preview subscribed=\(subscribed) dimension=\(dimension) image=\(image.width)x\(image.height) bytes=\(data.count)")
                    }
                }
                let screenshot = try await coordinator.screenshot(handle)
                let encoded = try #require(screenshot["data"]?.stringValue)
                let png = try #require(Data(base64Encoded: encoded))
                #expect(png.starts(with: [137, 80, 78, 71]))
                _ = try await handle.worker.request(["command": .string("unsubscribe")])
            } catch { failure = error }
            await coordinator.shutdown()
            if let deviceID {
                let cleanup = try await ProcessRunner.liveValue.run(
                    "/usr/bin/xcrun",
                    ["simctl", "--set", root.appendingPathComponent("devices").path, "delete", deviceID],
                    nil,
                    60
                )
                #expect(cleanup.isSuccess, "Private test device cleanup failed: \(cleanup.stderrString)")
                if cleanup.isSuccess {
                    try FileManager.default.removeItem(at: root)
                }
            }
            if let failure {
                throw failure
            }
        }
    }
#endif
