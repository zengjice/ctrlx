import CtrlxCommon
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation
#if os(macOS)
    import Darwin
#endif

@DependencyClient
struct CodexAccountClient: Sendable {
    var read: @Sendable (_ command: String, _ configRoot: String?) async throws -> CodexAccountReply
}

struct CodexAccountReply: Sendable {
    var account: Data
    var limits: Data?
}

extension CodexAccountClient: DependencyKey {
    static let liveValue = Self(read: { command, configRoot in
        #if os(macOS)
            return try await CodexAccountProcess().read(command: command, configRoot: configRoot)
        #else
            throw CodexAccountError.unavailable
        #endif
    })
}

enum CodexAccountError: Error, LocalizedError {
    case unavailable
    case invalidResponse
    case timeout
    var errorDescription: String? {
        switch self {
        case .unavailable: "Codex account information is unavailable. Check CLI sign-in and version."
        case .invalidResponse: "Codex returned an unsupported account response."
        case .timeout: "Codex account lookup timed out."
        }
    }
}

#if os(macOS)
    /// A short-lived, read-only app-server session. No thread or turn is created.
    private actor CodexAccountProcess {
        private var buffer = Data()
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator?

        func read(command: String, configRoot: String?) async throws -> CodexAccountReply {
            let process = Process()
            let input = Pipe()
            // A closed child stdin must throw EPIPE instead of terminating the Host.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command, "app-server", "--stdio"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            @Dependency(LoginShellPath.self) var loginShellPath
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ProcessRunner.effectivePath(resolved: loginShellPath.resolve(), inherited: environment["PATH"])
            if let configRoot {
                environment["CODEX_HOME"] = configRoot
            }
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(64)) { continuation in
                output.fileHandleForReading.readabilityHandler = { handle in
                    let bytes = handle.availableData
                    if bytes.isEmpty {
                        handle.readabilityHandler = nil
                        continuation.finish()
                    } else if case .dropped = continuation.yield(bytes) {
                        continuation.finish(throwing: CodexAccountError.invalidResponse)
                    }
                }
                continuation.onTermination = { _ in output.fileHandleForReading.readabilityHandler = nil }
            }
            iterator = stream.makeAsyncIterator()
            let exit = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            // Register before launch so even an immediate exit is retained.
            process.terminationHandler = { _ in
                exit.continuation.yield(())
                exit.continuation.finish()
            }
            defer {
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.terminationHandler = nil
                exit.continuation.finish()
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                iterator = nil
            }
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()

            @Dependency(\.continuousClock) var clock
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: CodexAccountReply.self) { group in
                    group.addTask {
                        let result: Result<CodexAccountReply, Error>
                        do { result = try .success(await self.exchange(input.fileHandleForWriting)) }
                        catch { result = .failure(error) }
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        // Cleanup is part of the same deadline, not a blocking defer.
                        var exited = exit.stream.makeAsyncIterator()
                        _ = await exited.next()
                        try Task.checkCancellation()
                        return try result.get()
                    }
                    group.addTask { [clock] in
                        try await clock.sleep(for: .seconds(20))
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        throw CodexAccountError.timeout
                    }
                    defer { group.cancelAll() }
                    guard let value = try await group.next() else { throw CodexAccountError.unavailable }
                    return value
                }
            } onCancel: {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        private func exchange(_ input: FileHandle) async throws -> CodexAccountReply {
            _ = try await request(1, method: "initialize", params: ["clientInfo": ["name": "ctrlx_dashboard", "version": "1"]], input: input)
            try write(["method": "initialized"], to: input)
            let account = try await request(2, method: "account/read", params: ["refreshToken": false], input: input)
            let parsed = try JSONDecoder().decode(CodexAccountParser.AccountResponse.self, from: account)
            let limits = parsed.account?.type == "chatgpt"
                ? try await request(3, method: "account/rateLimits/read", params: [:], input: input) : nil
            return CodexAccountReply(account: account, limits: limits)
        }

        private func write(_ value: [String: Any], to handle: FileHandle) throws {
            var bytes = try JSONSerialization.data(withJSONObject: value)
            bytes.append(10)
            try handle.write(contentsOf: bytes)
        }

        private func request(_ id: Int, method: String, params: [String: Any], input: FileHandle) async throws -> Data {
            try write(["id": id, "method": method, "params": params], to: input)
            while true {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    guard message["id"] as? Int == id else { continue }
                    guard let result = message["result"], message["error"] == nil else { throw CodexAccountError.unavailable }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                guard var reader = iterator else { throw CodexAccountError.unavailable }
                let next = try await reader.next(isolation: self)
                iterator = reader
                guard let next else { throw CodexAccountError.unavailable }
                buffer.append(next)
                guard buffer.count <= 1_048_576 else { throw CodexAccountError.invalidResponse }
            }
        }
    }
#endif
