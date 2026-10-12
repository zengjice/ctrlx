#if os(macOS)
    import Clocks
    import CtrlxSimulatorProtocol
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct SimulatorRecordingTests {
        // A small owned subprocess exercises signals, reaping and atomic publication without a simulator.
        private let script = """
        import os, signal, sys, time
        path = sys.argv[-1]
        def finish(*_):
            with open(path, 'ab') as f: f.write(b'finalized')
            sys.exit(0)
        signal.signal(signal.SIGINT, finish)
        with open(path, 'wb') as f: f.write(b'frames')
        print('Recording started', file=sys.stderr, flush=True)
        while True: time.sleep(.02)
        """

        private func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-record-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }

        @Test(arguments: [false, true])
        func stopFinalizesBeforePublishingAndRemovesTemporaryFiles(_ closing: Bool) async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appendingPathComponent("capture.mp4")
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: output.path), executable: "/usr/bin/python3", arguments: ["-c", script])
                let started = try await recorder.start()
                #expect(started["state"]?.stringValue == "recording")
                #expect(!FileManager.default.fileExists(atPath: output.path))
                let stopped = await recorder.stop(closing: closing)
                #expect(stopped["state"]?.stringValue == "completed")
                #expect(stopped["bytes"]?.intValue == Data("framesfinalized".utf8).count)
                #expect(stopped["reason"]?.stringValue == (closing ? "device-closed" : "stopped"))
                #expect(try Data(contentsOf: output) == Data("framesfinalized".utf8))
                #expect(await recorder.stop() == stopped)
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["capture.mp4"])
            }
        }

        @Test func slowFinalizationPreservesCompletedMovie() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appendingPathComponent("slow.mp4")
            let slow = script.replacingOccurrences(of: "def finish(*_):", with: "def finish(*_):\n    time.sleep(6)")
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: output.path),
                    executable: "/usr/bin/python3", arguments: ["-c", slow])
                _ = try await recorder.start()
                let result = await recorder.stop()
                #expect(result["state"]?.stringValue == "completed")
                #expect(try Data(contentsOf: output) == Data("framesfinalized".utf8))
            }
        }

        @Test func durationLimitStopsWithoutASecondCommand() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: root.appendingPathComponent("limit.mp4").path, seconds: 1),
                    executable: "/usr/bin/python3", arguments: ["-c", script])
                _ = try await recorder.start()
                try await Task.sleep(for: .milliseconds(1500))
                let result = await recorder.stop()
                #expect(result["state"]?.stringValue == "completed")
                #expect(result["reason"]?.stringValue == "duration-limit")
            }
        }

        @Test(arguments: [false, true])
        func existingOrRacingDestinationIsPreserved(_ racing: Bool) async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appendingPathComponent("existing.mp4")
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: output.path), executable: "/usr/bin/python3", arguments: ["-c", script])
                if racing { _ = try await recorder.start() }
                try Data("keep".utf8).write(to: output)
                if !racing { await #expect(throws: SimulatorFailure.self) { try await recorder.start() } }
                let result = await recorder.stop()
                #expect(result["state"]?.stringValue == "failed")
                #expect(try Data(contentsOf: output) == Data("keep".utf8))
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing.mp4"])
            }
        }

        @Test func earlyExitReportsFailureAndDoesNotPublish() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: root.appendingPathComponent("failed.mp4").path),
                    executable: "/usr/bin/false", arguments: [])
                await #expect(throws: SimulatorFailure.self) { try await recorder.start() }
                #expect(await recorder.status()["state"]?.stringValue == "failed")
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            }
        }

        @Test func closeBeforeStartCannotLaunchAProcess() async throws {
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: "/unused.mp4"), executable: "/usr/bin/false", arguments: [])
                _ = await recorder.stop(closing: true)
                await #expect(throws: SimulatorFailure.self) { try await recorder.start() }
            }
        }

        @Test func unresponsiveRecorderIsReapedAndPartialMovieDiscarded() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let ignored = script.replacingOccurrences(of: "signal.signal(signal.SIGINT, finish)",
                with: "signal.signal(signal.SIGINT, signal.SIG_IGN)")
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: root.appendingPathComponent("partial.mp4").path),
                    executable: "/usr/bin/python3", arguments: ["-c", ignored])
                _ = try await recorder.start()
                let result = await recorder.stop(closing: true)
                #expect(result["state"]?.stringValue == "failed")
                #expect(result["error"]?.stringValue?.contains("did not finalize") == true)
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            }
        }

        @Test func cancellationWhileWaitingForFirstFrameStopsTheProcess() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let silent = script.replacingOccurrences(of: "print('Recording started', file=sys.stderr, flush=True)", with: "pass")
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: root.appendingPathComponent("silent.mp4").path),
                    executable: "/usr/bin/python3", arguments: ["-c", silent])
                let start = Task { try await recorder.start() }
                try await Task.sleep(for: .milliseconds(300))
                #expect(await recorder.status()["state"]?.stringValue == "starting")
                start.cancel()
                await #expect(throws: CancellationError.self) { try await start.value }
                #expect(await recorder.status()["state"]?.stringValue == "failed")
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            }
        }

        @Test func growingFileStopsAtSizeLimitAndIsNotPublished() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let growing = script.replacingOccurrences(of: "while True: time.sleep(.02)", with: """
            time.sleep(.5)
            with open(path, 'r+b') as f: f.truncate(129 * 1024 * 1024)
            while True: time.sleep(.02)
            """)
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                let recorder = SimulatorRecorder(options: try .init(output: root.appendingPathComponent("large.mp4").path),
                    executable: "/usr/bin/python3", arguments: ["-c", growing])
                _ = try await recorder.start()
                try await Task.sleep(for: .milliseconds(1200))
                let result = await recorder.stop()
                #expect(result["state"]?.stringValue == "failed")
                #expect(result["reason"]?.stringValue == "size-limit")
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            }
        }
    }
#endif
