#if os(macOS)
    import CtrlxNetworking
    import Darwin
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("API socket recovery", .serialized)
    struct APISocketRecoveryTests {
        @Test(arguments: [EINTR, ECONNABORTED, EAGAIN, EMFILE, ENFILE, ENOBUFS, ENOMEM])
        func transientErrorsKeepServing(_ failure: Int32) async throws {
            let server = LiveAPISocketServer()
            let path = "/tmp/ctrlx-api-recovery-\(UUID()).sock"
            await server.setRequestHandler { request, _ in .init(id: request.id, result: ["pong": .bool(true)]) }
            try await server.start(socketPath: path)
            #expect(await server.recoverListenerError(failure, operation: "accept"))
            #expect(await server.socketPath == path)
            do {
                try await ping(path)
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }

        @Test
        func fatalErrorRemovesListenerAndAllowsSameServerToRestart() async throws {
            let server = LiveAPISocketServer()
            let path = "/tmp/ctrlx-api-fatal-\(UUID()).sock"
            await server.setRequestHandler { request, _ in .init(id: request.id, result: ["pong": .bool(true)]) }
            try await server.start(socketPath: path)
            #expect(await !server.recoverListenerError(EBADF, operation: "retain listener"))
            #expect(await server.socketPath == nil)
            #expect(!FileManager.default.fileExists(atPath: path))
            try await server.start(socketPath: path)
            do {
                try await ping(path)
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }

        @Test
        func stoppingDuringBackoffCannotRemoveAReplacementListener() async throws {
            let server = LiveAPISocketServer()
            let path = "/tmp/ctrlx-api-backoff-\(UUID()).sock"
            await server.setRequestHandler { request, _ in .init(id: request.id, result: ["pong": .bool(true)]) }
            try await server.start(socketPath: path)
            let recovery = Task { await server.recoverListenerError(EMFILE, operation: "retain listener") }
            try await Task.sleep(for: .milliseconds(20))
            await server.stop()
            recovery.cancel()
            try await server.start(socketPath: path)
            #expect(await !recovery.value)
            do {
                try await ping(path)
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()
        }

        private func ping(_ path: String) async throws {
            // The fixture's blocking client must not occupy the server actor.
            let response = try await Task.detached {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.EMFILE) }
                defer { close(fd) }
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                    throw POSIXError(.EINVAL)
                }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                path.withCString { pointer in
                    withUnsafeMutablePointer(to: &address.sun_path) {
                        UnsafeMutableRawPointer($0).copyMemory(from: pointer, byteCount: path.utf8.count + 1)
                    }
                }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
                try LiveAPISocketServer.configureConnection(fd)
                let request = JSONRPCRequest(id: "ping", method: "system.ping", params: [:])
                try LiveAPISocketServer.writeResponse(JSONEncoder().encode(request) + Data([10]), to: fd)
                var result = Data(), byte: UInt8 = 0
                while read(fd, &byte, 1) == 1 {
                    if byte == 10 {
                        return try JSONDecoder().decode(JSONRPCResponse.self, from: result)
                    }
                    result.append(byte)
                }
                throw POSIXError(.ETIMEDOUT)
            }.value
            #expect(response.result?["pong"] == .bool(true))
        }
    }
#endif
