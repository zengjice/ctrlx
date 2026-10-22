#if os(macOS)
    import AppKit
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
                system: .liveValue,
            )
            var failure: (any Error)?
            var deviceID: String?
            do {
                let handle = try await coordinator.open(
                    runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                    deviceType: nil,
                    frames: { $0.finish() },
                    errors: { print("Preview helper: \($0)") },
                )
                deviceID = handle.udid
                let hostClipboardRevision = NSPasteboard.general.changeCount
                let initial = try await handle.worker.request(["command": .string("clipboard-read"), "revisionOnly": .bool(true)])
                let initialRevision = try #require(initial["revision"]?.stringValue)
                let seed = root.appendingPathComponent("large-clipboard.txt")
                try Data(repeating: 120, count: 400 * 1_024).write(to: seed)
                let seeded = try await ProcessRunner.liveValue.run(
                    "/bin/sh",
                    [
                        "-c",
                        "exec /usr/bin/xcrun simctl --set \"$1\" pbcopy \"$2\" < \"$3\"",
                        "clipboard-seed",
                        root.appendingPathComponent("devices").path,
                        handle.udid,
                        seed.path,
                    ],
                    nil, 15,
                )
                try #require(seeded.isSuccess, "Private device clipboard seed failed: \(seeded.stderrString)")
                var revision = initialRevision
                for _ in 0..<10 {
                    let baseline = try await handle.worker.request(["command": .string("clipboard-read"), "revisionOnly": .bool(true)])
                    revision = try #require(baseline["revision"]?.stringValue)
                    #expect(baseline["content"] == nil)
                    if revision != initialRevision {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try #require(!revision.isEmpty && revision != initialRevision)
                let unchanged = try await handle.worker.request(["command": .string("clipboard-read"), "afterRevision": .string(revision)])
                #expect(unchanged["revision"]?.stringValue == revision && unchanged["content"] == nil)
                do {
                    _ = try await handle.worker.request(["command": .string("clipboard-read")])
                    Issue.record("Direct retrieval of a 400 KiB clipboard must still fail")
                } catch {
                    #expect(error.localizedDescription.contains("exceeds 384 KiB"))
                }
                print("Simulator 400 KiB clipboard: revision-only/unchanged reads passed; direct read rejected")
                let samples: [(String, Data)] = [
                    ("text", Data("CtrlX clipboard 中文\nsecond line".utf8)),
                    ("png", Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQaPjQAMIMMAYARzIIQdQEEEMAAAAASUVORK5CYII=")!),
                ]
                // Alternate types so an old snapshot cannot accidentally match the next write.
                for iteration in 0..<10 {
                    for (kind, original) in samples {
                        let bytes = kind == "text" ? original + Data("\(iteration)".utf8) : original
                        _ = try await handle.worker.request(["command": .string("clipboard-write"), "content": .object([
                            "kind": .string(kind), "data": .string(bytes.base64EncodedString()),
                        ])])
                        let result = try await handle.worker.request(["command": .string("clipboard-read"), "afterRevision": .string(revision)])
                        let content = try #require(result["content"]?.objectValue)
                        #expect(content["kind"]?.stringValue == kind)
                        #expect(content["data"]?.stringValue == bytes.base64EncodedString())
                        let nextRevision = try #require(result["revision"]?.stringValue)
                        #expect(!nextRevision.isEmpty && nextRevision != revision)
                        revision = nextRevision
                        print("Simulator clipboard round-trip \(iteration): \(kind)")
                    }
                }
                #expect(NSPasteboard.general.changeCount == hostClipboardRevision, "Device clipboard transfer must not alter the Host clipboard")
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
                    60,
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
