#if os(macOS)
    import Clocks
    import CtrlxNetworking
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import DependenciesMacros
    import Foundation

    @DependencyClient
    struct SimulatorRecordingClient: Sendable {
        var make: @Sendable (URL, String, SimulatorRecordingOptions) throws -> SimulatorRecorder
    }

    extension SimulatorRecordingClient: DependencyKey {
        static let testValue = Self()
        static let liveValue = Self(make: { deviceSet, udid, options in
            SimulatorRecorder(options: options, arguments: [
                "simctl", "--set", deviceSet.path, "io", udid, "recordVideo", "--codec=h264", "--mask=black",
            ])
        })
    }

    /// One bounded recording. simctl owns encoding; this actor owns its process and final artifact.
    actor SimulatorRecorder {
        private let clock: AnyClock<Duration>
        private let options: SimulatorRecordingOptions
        private let executable: String
        private let arguments: [String]
        private var process: Process?
        private var monitor: Task<Void, Never>?
        private var state = "idle"
        private var reason: String?
        private var failure: String?
        private var bytes = 0
        private var stopAt: AnyClock<Duration>.Instant?
        private var directory: URL?

        init(options: SimulatorRecordingOptions, executable: String = "/usr/bin/xcrun", arguments: [String]) {
            self.options = options
            self.executable = executable
            self.arguments = arguments
            @Dependency(\.continuousClock) var clock
            self.clock = AnyClock(clock)
        }

        func status() -> [String: JSONValue] {
            var result: [String: JSONValue] = ["state": .string(state), "path": .string(options.output.path),
                "bytes": .int(bytes), "maximumSeconds": .int(options.seconds)]
            if let reason { result["reason"] = .string(reason) }
            if let failure { result["error"] = .string(failure) }
            return result
        }

        func start() async throws -> [String: JSONValue] {
            guard state == "idle" else { throw SimulatorFailure("Recording has already started or its device closed") }
            try Task.checkCancellation()
            state = "starting"
            do {
                let parent = options.output.deletingLastPathComponent()
                guard !FileManager.default.fileExists(atPath: options.output.path) else {
                    throw SimulatorFailure("Recording output already exists; choose a new path")
                }
                let directory = parent.appendingPathComponent(".ctrlx-recording-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                self.directory = directory
                let log = directory.appendingPathComponent("stderr")
                let fd = Darwin.open(log.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                guard fd >= 0 else { throw SimulatorFailure("Cannot create recording diagnostics") }
                let stderr = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? stderr.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments + [directory.appendingPathComponent("video.mp4").path]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderr
                try process.run()
                self.process = process
                monitor = Task { await self.watch(process, directory: directory, log: log) }
                return try await withTaskCancellationHandler {
                    while state == "starting" {
                        try await clock.sleep(for: .milliseconds(50))
                        try Task.checkCancellation()
                    }
                    guard state == "recording" else { throw SimulatorFailure(failure ?? "Recording stopped before it became ready") }
                    return status()
                } onCancel: {
                    Task { _ = await self.stop() }
                }
            } catch {
                if process == nil {
                    failure = error.localizedDescription
                    state = "failed"
                    cleanup()
                } else {
                    _ = await stop()
                }
                throw error
            }
        }

        func stop(closing: Bool = false) async -> [String: JSONValue] {
            if state == "idle" {
                state = "failed"
                failure = "Device closed before recording started"
            } else if state == "starting" || state == "recording" {
                requestStop(closing ? "device-closed" : "stopped")
            }
            await monitor?.value
            return status()
        }

        private func requestStop(_ reason: String) {
            guard stopAt == nil else { return }
            self.reason = reason
            stopAt = clock.now
            state = "stopping"
            if process?.isRunning == true { process?.interrupt() }
        }

        private func watch(_ process: Process, directory: URL, log: URL) async {
            let started = clock.now
            var readyAt: AnyClock<Duration>.Instant?
            var killed = false
            let movie = directory.appendingPathComponent("video.mp4")
            while process.isRunning {
                if readyAt == nil {
                    do {
                        let file = try FileHandle(forReadingFrom: log)
                        defer { try? file.close() }
                        let data = try file.read(upToCount: 16384) ?? Data()
                        if String(decoding: data, as: UTF8.self).contains("Recording started") {
                            readyAt = clock.now
                            if state == "starting" { state = "recording" }
                        }
                    } catch {
                        failure = "Cannot read recording readiness: \(error.localizedDescription)"
                        requestStop("failed")
                    }
                    if readyAt == nil, started.duration(to: clock.now) >= .seconds(10) {
                        failure = "Recording did not produce its first frame within 10 seconds"
                        requestStop("failed")
                    }
                }
                bytes = (try? fileSize(movie)) ?? 0
                if let readyAt, readyAt.duration(to: clock.now) >= .seconds(options.seconds) {
                    requestStop("duration-limit")
                }
                if bytes >= SimulatorRecordingOptions.maximumBytes { requestStop("size-limit") }
                // Native finalization can exceed five seconds even for a short clip.
                if let stopAt, stopAt.duration(to: clock.now) >= .seconds(15), !killed {
                    failure = "Recording did not finalize within 15 seconds; the incomplete movie was discarded"
                    killed = true
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                do { try await clock.sleep(for: .milliseconds(readyAt == nil ? 50 : 250)) } catch {
                    failure = "Recording monitor was cancelled"
                    requestStop("failed")
                }
            }
            do {
                guard failure == nil, readyAt != nil, process.terminationReason == .exit, process.terminationStatus == 0 else {
                    let file = try FileHandle(forReadingFrom: log)
                    defer { try? file.close() }
                    let data = (try? file.read(upToCount: 4096)) ?? Data()
                    throw SimulatorFailure(failure ?? "Recording failed (\(process.terminationStatus)): \(String(decoding: data.prefix(4096), as: UTF8.self))")
                }
                bytes = try fileSize(movie)
                guard bytes > 0, bytes <= SimulatorRecordingOptions.maximumBytes else {
                    throw SimulatorFailure("Recording is empty or exceeds 128 MiB; the movie was discarded")
                }
                guard chmod(movie.path, 0o600) == 0 else { throw SimulatorFailure("Cannot protect recording output") }
                // Same-directory staging keeps publication atomic and never overwrites a racing destination.
                guard Darwin.link(movie.path, options.output.path) == 0 else {
                    throw SimulatorFailure("Recording output exists or cannot be published; existing files were preserved")
                }
                state = "completed"
            } catch {
                failure = error.localizedDescription
                state = "failed"
            }
            cleanup()
            self.process = nil
        }

        private func cleanup() {
            guard let directory else { return }
            do { try FileManager.default.removeItem(at: directory) } catch {
                failure = "Recording temporary-file cleanup failed: \(error.localizedDescription)"
                state = "failed"
            }
            self.directory = nil
        }

        private func fileSize(_ url: URL) throws -> Int {
            // URL resource values cache the size while simctl is still writing.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
    }
#endif
