import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import CtrlxCLI

@Suite("CLI socket deadlines", .timeLimit(.minutes(1)))
struct SocketDeadlineTests {
    private struct Listener: Sendable {
        let path = "/tmp/ctrlx-cli-deadline-\(UUID()).sock"
        let fd: Int32

        init() throws {
            self.fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EMFILE) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            path.withCString { pointer in
                withUnsafeMutablePointer(to: &address.sun_path) {
                    UnsafeMutableRawPointer($0).copyMemory(from: pointer, byteCount: path.utf8.count + 1)
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, listen(fd, 64) == 0 else {
                close(fd)
                unlink(path)
                throw POSIXError(.EINVAL)
            }
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    @Test(arguments: [false, true])
    func stalledReadOrWriteUsesFractionalDeadline(_ largeRequest: Bool) throws {
        let listener = try Listener()
        defer { listener.stop() }
        let request = JSONRPCRequest(id: "bounded", method: "system.ping", params: largeRequest ? ["payload": .string(String(repeating: "x", count: 2 * 1_024 * 1_024))] : [:])
        let start = ContinuousClock.now
        do {
            _ = try SocketClient.send(request, socketPath: listener.path, timeoutSeconds: 0.15)
            Issue.record("Silent peer should time out")
        } catch {
            guard case CLIError.responseTimeout = error else { throw error }
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test(arguments: ["ping", "identify"])
    func diagnosticCommandsBoundSilentServer(_ command: String) throws {
        let listener = try Listener()
        defer { listener.stop() }
        let start = ContinuousClock.now
        #expect(throws: CLIError.self) {
            if command == "ping" {
                try PingCommand.parse(["--socket", listener.path]).run()
            } else {
                try IdentifyCommand.parse(["--socket", listener.path, "--json"]).run()
            }
        }
        #expect(start.duration(to: .now) >= .seconds(4))
        #expect(start.duration(to: .now) < .seconds(8))
    }

    @Test(arguments: [false, true])
    func waitReadyHonorsTotalDeadlineWithSilentOrAbsentServer(_ silent: Bool) throws {
        let listener = try Listener()
        defer { listener.stop() }
        let command = try WaitReadyCommand.parse([
            "--socket", silent ? listener.path : listener.path + ".missing",
            "--timeout", "0.15", "--interval", "10",
        ])
        let start = ContinuousClock.now
        #expect(throws: ExitCode.self) { try command.run() }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test(arguments: ["0", "-1", "nan", "inf"])
    func invalidWaitOptionsFailBeforeConnecting(_ value: String) {
        for option in ["--timeout", "--interval"] {
            #expect(throws: (any Error).self) { _ = try WaitReadyCommand.parse([option, value]) }
        }
    }

    @Test
    func editorCanStillWaitForUserInput() async throws {
        let listener = try Listener()
        defer { listener.stop() }
        let responder = Task.detached {
            let fd = accept(listener.fd, nil, nil)
            guard fd >= 0 else { throw POSIXError(.ECONNABORTED) }
            defer { close(fd) }
            var byte: UInt8 = 0
            while read(fd, &byte, 1) == 1, byte != 10 { }
            try await Task.sleep(for: .seconds(5.2))
            let data = try JSONEncoder().encode(JSONRPCResponse.ok(id: "editor")) + Data([10])
            return data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        let response = try SocketClient.send(.init(id: "editor", method: "editor.open", params: [:]), socketPath: listener.path)
        #expect(response.ok)
        #expect(try await responder.value > 0)
    }
}
