#if os(macOS)
    import CtrlxCommon
    import Darwin
    import Dependencies
    import Foundation

    enum AgentCLIProcess {
        /// Regular-file output avoids a full pipe stalling installers or inherited pipe handles
        /// keeping cancellation alive. Only this operation's process group is stopped.
        static func run(
            executable: String, arguments: [String], environment: [String: String] = [:],
            timeout: TimeInterval, output: @Sendable (String) async -> Void
        ) async throws -> Int32 {
            try Task.checkCancellation()
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-cli-output-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AgentCLIError(message: "Cannot create installation log.")
            }
            defer { try? FileManager.default.removeItem(at: log) }
            let writer = try FileHandle(forWritingTo: log)
            defer { try? writer.close() }
            let reader = try FileHandle(forReadingFrom: log)
            defer { try? reader.close() }

            @Dependency(LoginShellPath.self) var loginPath
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ProcessRunner.effectivePath(resolved: loginPath.resolve(), inherited: env["PATH"])
            env.merge(environment) { _, new in new }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = writer
            process.standardError = writer
            try process.run()

            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            var bytesRead = 0
            do {
                repeat {
                    try Task.checkCancellation()
                    let data = try reader.read(upToCount: 64 * 1_024) ?? Data()
                    bytesRead += data.count
                    if !data.isEmpty {
                        await output(String(decoding: data, as: UTF8.self))
                    }
                    guard bytesRead <= 8 * 1_024 * 1_024 else { throw AgentCLIError(message: "Installer produced too much output; stopped.") }
                    if !process.isRunning, data.isEmpty {
                        break
                    }
                    guard ContinuousClock.now < deadline else { throw AgentCLIError(message: "Installation timed out. Check your connection and retry.") }
                    if data.isEmpty {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                } while true
            } catch {
                if process.isRunning {
                    let pid = process.processIdentifier
                    if getpgid(pid) == pid {
                        kill(-pid, SIGKILL)
                    } else {
                        kill(pid, SIGKILL)
                    }
                    // Reap before removing the temporary log. Sleep in an uncancelled task.
                    await Task.detached {
                        while process.isRunning {
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                    }.value
                }
                throw error
            }
            return process.terminationStatus
        }
    }
#endif
