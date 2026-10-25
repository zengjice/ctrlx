#if os(macOS)
    import CtrlxNetworking
    import Darwin
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct APISocketWorkflowPeerTests {
        @Test(.timeLimit(.minutes(1)))
        func stoppedListenersCannotHandleNewServersRequests() async throws {
            for _ in 0..<24 {
                let stopped = LiveAPISocketServer()
                try await stopped.start(socketPath: "/tmp/ctrlx-old-listener-\(UUID()).sock")
                await Task.yield()
                await stopped.stop()
                let current = LiveAPISocketServer()
                let path = "/tmp/ctrlx-new-listener-\(UUID()).sock", token = UUID().uuidString
                await current.setRequestHandler { request, _ in .init(id: request.id, result: ["owner": .string(token)]) }
                try await current.start(socketPath: path)
                do {
                    let response = try await Task.detached { try send(.init(id: "new", method: "system.ping", params: [:]), socketPath: path) }.value
                    #expect(response.result?["owner"] == .string(token))
                } catch {
                    await current.stop()
                    throw error
                }
                await current.stop()
            }
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["workflow.finish", "workflow.attachments", "workflow.artifact"])
        func socketSuppliesKernelIdentitySeparatelyFromClaimedJSON(method: String) async throws {
            try await withDependencies {
                $0[PluginIngressPeerClient.self] = .liveValue
            } operation: {
                let server = LiveAPISocketServer()
                let path = "/tmp/ctrlx-workflow-peer-\(UUID()).sock"
                await server.setRequestHandler { request, peer in
                    .init(id: request.id, result: [
                        "peer": peer?.processes.first.map { .int(Int($0.processID)) } ?? .null,
                        "claimed": request.params["_peerPID"] ?? .null,
                    ])
                }
                try await server.start(socketPath: path)
                do {
                    let request = JSONRPCRequest(id: "identity", method: method, params: ["_peerPID": .int(1)])
                    let response = try await Task.detached { try send(request, socketPath: path) }.value
                    let detail = try String(decoding: JSONEncoder().encode(response), as: UTF8.self)
                    #expect(response.result?["peer"] == .int(Int(getpid())), "\(detail)")
                    #expect(response.result?["claimed"] == .int(1), "\(detail)")
                    let ordinary = JSONRPCRequest(id: "ordinary", method: "system.ping", params: [:])
                    let other = try await Task.detached { try send(ordinary, socketPath: path) }.value
                    #expect(other.result?["peer"] == .null)
                } catch {
                    await server.stop()
                    throw error
                }
                await server.stop()
            }
        }

        private func send(_ request: JSONRPCRequest, socketPath: String) throws -> JSONRPCResponse {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.ENFILE) }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                throw POSIXError(.EINVAL)
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { path in
                withUnsafeMutablePointer(to: &address.sun_path) { UnsafeMutableRawPointer($0).copyMemory(from: path, byteCount: socketPath.utf8.count + 1) }
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            var data = try JSONEncoder().encode(request)
            data.append(10)
            try LiveAPISocketServer.configureConnection(fd)
            try LiveAPISocketServer.writeResponse(data, to: fd)
            var result = Data()
            var byte: UInt8 = 0
            while result.count < 64 * 1_024 {
                guard read(fd, &byte, 1) == 1 else { throw POSIXError(.ETIMEDOUT) }
                if byte == 10 {
                    return try JSONDecoder().decode(JSONRPCResponse.self, from: result)
                }
                result.append(byte)
            }
            throw POSIXError(.EMSGSIZE)
        }
    }
#endif
