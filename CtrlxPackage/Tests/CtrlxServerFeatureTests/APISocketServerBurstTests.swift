#if os(macOS)
    import Darwin
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    private extension LiveAPISocketServer {
        func startWithPendingClients(path: String, count: Int) throws -> [(fd: Int32, error: Int32)] {
            try start(socketPath: path)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            path.withCString { string in
                withUnsafeMutablePointer(to: &address.sun_path) {
                    UnsafeMutableRawPointer($0).copyMemory(from: string, byteCount: path.utf8.count + 1)
                }
            }
            // Keep the actor occupied until the burst is queued, before acceptLoop can run.
            return (0..<count).map { _ in
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { return (fd, errno) }
                guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return (fd, errno) }
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                return (fd, result == 0 ? 0 : errno)
            }
        }
    }

    @Suite("API socket burst", .serialized)
    struct APISocketServerBurstTests {
        @Test func simultaneousClientsCanConnectBeforeTheAcceptLoopRuns() async throws {
            let server = LiveAPISocketServer()
            let path = "/tmp/ctrlx-api-burst-\(UUID().uuidString).sock"
            let connections = try await server.startWithPendingClients(path: path, count: 32)
            for connection in connections where connection.fd >= 0 { close(connection.fd) }
            await server.stop()
            #expect(connections.map { $0.error } == Array(repeating: Int32(0), count: 32))
        }
    }
#endif
