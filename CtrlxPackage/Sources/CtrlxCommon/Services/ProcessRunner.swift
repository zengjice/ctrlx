import Dependencies
import DependenciesMacros
import Foundation
#if os(macOS)
    import Darwin
#endif

/// Result of a process execution
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let outputTruncated: Bool

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    public var isSuccess: Bool {
        exitCode == 0
    }

    public init(exitCode: Int32, stdout: Data, stderr: Data, outputTruncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputTruncated = outputTruncated
    }
}

/// Errors that can occur during process execution
public enum ProcessRunnerError: Error, LocalizedError {
    case executableNotFound(path: String)
    case executionFailed(exitCode: Int32, stderr: String)
    case timeout
    case invalidOutputLimit

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Executable not found at path: \(path)"
        case let .executionFailed(exitCode, stderr):
            return "Process exited with code \(exitCode): \(stderr)"
        case .timeout:
            return "Process execution timed out"
        case .invalidOutputLimit:
            return "Process output limit must be positive"
        }
    }
}

/// A dependency for running external processes asynchronously.
///
/// Wraps `Process` execution so it can be controlled in tests.
/// Use `@Dependency(ProcessRunner.self)` to access it.
@DependencyClient
public struct ProcessRunner: Sendable {
    /// Runs a command and returns the result.
    public var run: @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval?
    ) async throws -> ProcessResult

    /// Retains the most recent maximumBytes from each stream while draining the process.
    public var runBounded: @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval?,
        _ maximumBytes: Int
    ) async throws -> ProcessResult = { _, _, _, _, _ in
        throw ProcessRunnerError.executionFailed(exitCode: -1, stderr: "Bounded process execution is not configured")
    }

    /// Cancelling the task stops the owned command and its subprocesses, then waits for exit.
    public var runCancellable: @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval?
    ) async throws -> ProcessResult = { _, _, _, _ in
        throw ProcessRunnerError.executionFailed(exitCode: -1, stderr: "Cancellable process execution is not configured")
    }

    /// Runs a command with the supplied bytes on stdin. Used to hand secrets to
    /// a local helper without placing them in its process arguments.
    public var runWithInput: @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval?,
        _ input: Data
    ) async throws -> ProcessResult = { _, _, _, _, _ in
        throw ProcessRunnerError.executionFailed(exitCode: -1, stderr: "Process input is not configured")
    }
}

public extension ProcessRunner {
    init(
        run: @Sendable @escaping (String, [String], [String: String]?, TimeInterval?) async throws -> ProcessResult,
        runBounded: @Sendable @escaping (String, [String], [String: String]?, TimeInterval?, Int) async throws -> ProcessResult = { _, _, _, _, _ in
            throw ProcessRunnerError.executionFailed(exitCode: -1, stderr: "Bounded process execution is not configured")
        },
        runWithInput: @Sendable @escaping (String, [String], [String: String]?, TimeInterval?, Data) async throws -> ProcessResult = { _, _, _, _, _ in
            throw ProcessRunnerError.executionFailed(exitCode: -1, stderr: "Process input is not configured")
        }
    ) {
        self.init(run: run, runBounded: runBounded, runCancellable: run, runWithInput: runWithInput)
    }
}

// MARK: - PATH helpers

public extension ProcessRunner {
    /// The PATH to use for a subprocess: the resolved login-shell PATH when
    /// available, else the inherited PATH with common install dirs prepended
    /// (so the most common CLIs still resolve if shell resolution failed).
    static func effectivePath(resolved: String?, inherited: String?) -> String {
        if let resolved, !resolved.isEmpty {
            return resolved
        }
        let commonDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSString(string: "~/.local/bin").expandingTildeInPath,
            NSString(string: "~/.npm-global/bin").expandingTildeInPath,
        ]
        let inheritedParts = (inherited ?? "").split(separator: ":").map(String.init)
        let existing = Set(inheritedParts)
        let prefix = commonDirs.filter { !existing.contains($0) }
        return (prefix + inheritedParts).joined(separator: ":")
    }
}

// MARK: - Convenience

public extension ProcessRunner {
    /// Runs a command and throws if it fails.
    func runOrThrow(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments, environment, timeout)

        if !result.isSuccess {
            throw ProcessRunnerError.executionFailed(
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }

        return result
    }
}

// MARK: - DependencyKey

extension ProcessRunner: DependencyKey {
    public static var previewValue: ProcessRunner {
        ProcessRunner(
            run: { _, _, _, _ in
                ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )
    }

    public static var liveValue: ProcessRunner {
        #if os(macOS)
            return ProcessRunner(
                run: { try await execute($0, $1, $2, $3, maximumBytes: nil) },
                runBounded: { executable, arguments, environment, timeout, maximumBytes in
                    guard maximumBytes > 0 else { throw ProcessRunnerError.invalidOutputLimit }
                    return try await execute(executable, arguments, environment, timeout, maximumBytes: maximumBytes)
                },
                runCancellable: { executable, arguments, environment, timeout in
                    try await execute(executable, arguments, environment, timeout, maximumBytes: nil, cancelOnTaskCancellation: true)
                },
                runWithInput: { executable, arguments, environment, timeout, input in
                    try await execute(executable, arguments, environment, timeout, maximumBytes: nil, input: input)
                }
            )
        #else
            // `Process` (NSTask) is macOS-only. `ProcessRunner` is only invoked on
            // macOS (plugin cores, tmux, installers); it is never used on iOS, so the
            // live value fails loudly if (unexpectedly) called there.
            return ProcessRunner(
                run: { executable, _, _, _ in
                    throw ProcessRunnerError.executableNotFound(path: executable)
                },
                runBounded: { executable, _, _, _, _ in
                    throw ProcessRunnerError.executableNotFound(path: executable)
                }
            )
        #endif
    }

    #if os(macOS)
        private static func execute(
            _ executable: String, _ arguments: [String], _ environment: [String: String]?,
            _ timeout: TimeInterval?, maximumBytes: Int?, cancelOnTaskCancellation: Bool = false,
            input: Data? = nil
        ) async throws -> ProcessResult {
            if cancelOnTaskCancellation {
                try Task.checkCancellation()
            }
            // Verify executable exists
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw ProcessRunnerError.executableNotFound(path: executable)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            // Set up environment. A GUI app inherits launchd's minimal PATH,
            // so inject the user's real login-shell PATH (resolved once,
            // cached) before the caller's overrides — otherwise `/usr/bin/env
            // <cmd>` can't find CLIs in ~/.local/bin, Homebrew, mise/nvm, etc.
            @Dependency(LoginShellPath.self) var loginShellPath
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = effectivePath(resolved: loginShellPath.resolve(), inherited: env["PATH"])
            if let additionalEnv = environment {
                for (key, value) in additionalEnv {
                    env[key] = value
                }
            }
            process.environment = env

            // Set up pipes for stdout and stderr
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let inputPipe = input.map { _ in Pipe() }
            if let inputPipe {
                process.standardInput = inputPipe
            }

            // Launch before entering the continuation so that ObjC exceptions
            // from NSTask (e.g. invalid launch path, already-launched task) are
            // caught by Swift's do/try/catch instead of crashing with SIGABRT.
            let outputCollector = OutputCollector(maximumBytes: maximumBytes)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                outputCollector.collectStdout(from: handle)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                outputCollector.collectStderr(from: handle)
            }

            try process.run()

            if let input, let inputPipe {
                do {
                    try inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try inputPipe.fileHandleForWriting.close()
                } catch {
                    process.terminate()
                    throw error
                }
            }

            // Set up timeout if specified.
            // Reads `\.continuousClock` from the surrounding dependency context
            // so a `TestClock` injected via `withDependencies` can drive timeout
            // behaviour deterministically without burning wall-clock seconds.
            // Read-and-capture must happen here, OUTSIDE the `Task`. Unstructured
            // tasks don't propagate `DependencyValues` task-locals, so reading
            // `@Dependency` inside the `Task` body would silently fall back to
            // the live clock. Any future dependency this closure needs must be
            // captured the same way (or routed through `withEscapedDependencies`).
            let timeoutTask: Task<Void, Never>?
            if let timeout {
                @Dependency(\.continuousClock) var clock
                timeoutTask = Task { [clock, outputCollector] in
                    try? await clock.sleep(for: .seconds(timeout))
                    if process.isRunning {
                        // Record that the kill was a timeout so the caller
                        // gets `.timeout`, not a generic non-zero failure.
                        outputCollector.markTimedOut()
                        process.terminate()
                    }
                }
            } else {
                timeoutTask = nil
            }

            let result: ProcessResult = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { [outputCollector, timeoutTask] _ in
                        // Cancel the timeout sleep eagerly so it doesn't sit on a
                        // virtual deadline after the process has already exited.
                        timeoutTask?.cancel()

                        // Clean up handlers
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        // Serialize the final drain with in-flight callbacks,
                        // including data already read but not yet appended.
                        outputCollector.collectStdout(from: stdoutPipe.fileHandleForReading, toEnd: true)
                        outputCollector.collectStderr(from: stderrPipe.fileHandleForReading, toEnd: true)

                        // A timed-out process was killed by us, so its non-zero
                        // termination status is meaningless — surface `.timeout`
                        // so callers can distinguish it from a real failure.
                        if outputCollector.timedOut {
                            continuation.resume(throwing: ProcessRunnerError.timeout)
                            return
                        }

                        let result = ProcessResult(
                            exitCode: process.terminationStatus,
                            stdout: outputCollector.stdout,
                            stderr: outputCollector.stderr, outputTruncated: outputCollector.outputTruncated
                        )
                        continuation.resume(returning: result)
                    }
                }
            } onCancel: {
                guard cancelOnTaskCancellation, process.isRunning else { return }
                let pid = process.processIdentifier
                // Foundation launches a private process group; stop xcrun children too.
                if getpgid(pid) == pid {
                    kill(-pid, SIGKILL)
                } else {
                    process.terminate()
                }
            }
            if cancelOnTaskCancellation {
                try Task.checkCancellation()
            }
            return result
        }
    #endif
}

#if os(macOS)
    /// Thread-safe output collector for process output
    final private class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let stdoutLock = NSLock()
        private let stderrLock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()
        private var _timedOut = false
        private let maximumBytes: Int?
        private var stdoutTruncated = false
        private var stderrTruncated = false

        init(maximumBytes: Int?) {
            self.maximumBytes = maximumBytes
        }

        var outputTruncated: Bool {
            stdoutLock.withLock { stdoutTruncated } || stderrLock.withLock { stderrTruncated }
        }

        var stdout: Data {
            stdoutLock.withLock { _stdout }
        }

        var stderr: Data {
            stderrLock.withLock { _stderr }
        }

        /// Set when the timeout task terminated the process, so the termination
        /// handler can distinguish a timeout from a genuine non-zero exit.
        var timedOut: Bool {
            lock.withLock { _timedOut }
        }

        func collectStdout(from handle: FileHandle, toEnd: Bool = false) {
            stdoutLock.withLock {
                collect(from: handle, toEnd: toEnd, into: &_stdout, truncated: &stdoutTruncated)
            }
        }

        func collectStderr(from handle: FileHandle, toEnd: Bool = false) {
            stderrLock.withLock {
                collect(from: handle, toEnd: toEnd, into: &_stderr, truncated: &stderrTruncated)
            }
        }

        private func collect(from handle: FileHandle, toEnd: Bool, into output: inout Data, truncated: inout Bool) {
            guard let maximumBytes else {
                output.append(toEnd ? handle.readDataToEndOfFile() : handle.availableData)
                return
            }
            repeat {
                let chunk = toEnd ? handle.readData(ofLength: 64 * 1_024) : handle.availableData
                guard !chunk.isEmpty else { return }
                output.append(chunk)
                if output.count > maximumBytes {
                    output = Data(output.suffix(maximumBytes))
                    truncated = true
                }
            } while toEnd
        }

        func markTimedOut() {
            lock.withLock { _timedOut = true }
        }
    }
#endif
