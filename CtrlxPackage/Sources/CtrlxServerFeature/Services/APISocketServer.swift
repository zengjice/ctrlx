#if os(macOS)
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import CtrlxSimulatorProtocol
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// Handler type for incoming JSON-RPC requests.
    /// Returns a response for normal requests.
    /// For editor.open, the handler should block until editing completes, then return.
    public typealias APIRequestHandler = @Sendable (JSONRPCRequest, PluginIngressPeer?) async -> JSONRPCResponse

    /// Unix domain socket server that accepts JSON-RPC connections.
    public struct APISocketServer: Sendable {
        public var start: @Sendable (_ socketPath: String) async throws -> Void = { _ in }
        public var stop: @Sendable () async -> Void = { }
        public var setRequestHandler: @Sendable (_ handler: @escaping APIRequestHandler) async -> Void = { _ in }
        public var getSocketPath: @Sendable () async -> String? = { nil }
    }

    extension APISocketServer: DependencyKey {
        public static var previewValue: APISocketServer {
            APISocketServer()
        }

        public static var liveValue: APISocketServer {
            let server = LiveAPISocketServer()
            return APISocketServer(
                start: { socketPath in
                    try await server.start(socketPath: socketPath)
                },
                stop: {
                    await server.stop()
                },
                setRequestHandler: { handler in
                    await server.setRequestHandler(handler)
                },
                getSocketPath: {
                    await server.socketPath
                }
            )
        }

        public static var testValue: APISocketServer {
            APISocketServer()
        }
    }

    /// Actor-based live implementation of the API socket server.
    actor LiveAPISocketServer {
        private let logger = Logger(label: "com.jicezeng.ctrlx.apisocket")
        private(set) var socketPath: String?
        private var serverFd: Int32 = -1
        private var isRunning = false
        private var acceptTask: Task<Void, Never>?
        private var requestHandler: APIRequestHandler?

        func setRequestHandler(_ handler: @escaping APIRequestHandler) {
            requestHandler = handler
        }

        func start(socketPath: String) throws {
            guard !isRunning else { return }

            if isSocketActive(path: socketPath) {
                logger.info("Another instance already owns the API socket, skipping")
                return
            }
            unlink(socketPath)

            serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else {
                throw APISocketError.socketCreationFailed
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                throw APISocketError.pathTooLong
            }
            socketPath.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: socketPath.utf8.count + 1)
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(serverFd, sockPtr, addrLen)
                }
            }
            guard bindResult == 0 else {
                close(serverFd)
                serverFd = -1
                throw APISocketError.bindFailed
            }

            guard listen(serverFd, 64) == 0 else {
                close(serverFd)
                serverFd = -1
                throw APISocketError.listenFailed
            }

            self.socketPath = socketPath
            isRunning = true
            logger.info("API socket server listening at \(socketPath)")

            acceptTask = Task {
                await acceptLoop()
            }
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            acceptTask?.cancel()
            acceptTask = nil

            if serverFd >= 0 {
                shutdown(serverFd, SHUT_RDWR)
                close(serverFd)
                serverFd = -1
            }
            if let path = socketPath {
                unlink(path)
            }
            logger.info("API socket server stopped")
        }

        // MARK: - Private

        private func isSocketActive(path: String) -> Bool {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            path.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: path.utf8.count + 1)
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, addrLen)
                }
            }
            return connected == 0
        }

        private func acceptLoop() async {
            while !Task.isCancelled && isRunning {
                // Keep this listener alive while the blocking accept is queued.
                // stop() may close serverFd and another server may reuse its
                // number before the worker starts. shutdown still wakes the dup.
                let listener = fcntl(serverFd, F_DUPFD_CLOEXEC, 0)
                guard listener >= 0 else {
                    logger.error("Could not retain API socket listener")
                    break
                }
                let clientFd = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        let fd = accept(listener, nil, nil)
                        close(listener)
                        continuation.resume(returning: fd)
                    }
                }

                guard !Task.isCancelled, isRunning else {
                    if clientFd >= 0 {
                        close(clientFd)
                    }
                    break
                }

                guard clientFd >= 0 else {
                    if isRunning {
                        logger.error("accept() failed, stopping server")
                    }
                    break
                }

                // Handle each connection in its own task so multiple clients
                // can be served concurrently (important for editor.open which blocks)
                let handler = requestHandler
                let logger = logger
                Task {
                    await Self.handleConnection(clientFd, handler: handler, logger: logger)
                }
            }
        }

        /// Handles a single client connection. Reads newline-delimited JSON-RPC
        /// requests and sends responses until the client disconnects.
        private static func handleConnection(
            _ fd: Int32,
            handler: APIRequestHandler?,
            logger: Logger
        ) async {
            defer { close(fd) }
            do {
                try configureConnection(fd)
            } catch {
                logger.error("Failed to configure API connection: \(error)")
                return
            }

            // Read messages in a loop (persistent connection)
            while true {
                let data = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        var data = Data()
                        var byte: UInt8 = 0
                        while Darwin.read(fd, &byte, 1) == 1 {
                            if byte == UInt8(ascii: "\n") {
                                break
                            }
                            data.append(byte)
                        }
                        continuation.resume(returning: data)
                    }
                }

                guard !data.isEmpty else {
                    // Client disconnected
                    break
                }

                // Decode JSON-RPC request
                let response: JSONRPCResponse
                do {
                    var request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
                    if request.method == "simulator.action" {
                        var peerPID: Int32 = 0
                        var size = socklen_t(MemoryLayout.size(ofValue: peerPID))
                        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0, peerPID > 0 else {
                            throw SimulatorFailure("Cannot identify the simulator socket caller")
                        }
                        var params = request.params
                        params["_peerPID"] = .int(Int(peerPID))
                        request = JSONRPCRequest(id: request.id, method: request.method, params: params)
                    }
                    // Evidence stays outside JSON, so a caller cannot forge it
                    // through _peerPID, TMUX_PANE or a claimed instance UUID.
                    @Dependency(PluginIngressPeerClient.self) var peers
                    let peer = ["workflow.finish", "workflow.attachments", "workflow.artifact"].contains(request.method) ? peers.capture(fd) : nil
                    if let handler {
                        response = await handler(request, peer)
                    } else {
                        response = .internalError(id: request.id, "No request handler configured")
                    }
                } catch {
                    // Can't decode request — send error with empty ID
                    response = .internalError(id: "", "Invalid JSON-RPC request: \(error.localizedDescription)")
                }

                // Send response
                do {
                    var responseData = try JSONEncoder().encode(response)
                    responseData.append(UInt8(ascii: "\n"))
                    try writeResponse(responseData, to: fd)
                } catch {
                    logger.error("Failed to send response: \(error)")
                    break
                }
            }
        }

        nonisolated static func configureConnection(_ fd: Int32) throws {
            // A client may close after reaching its response limit or cancelling a request.
            var noSIGPIPE: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout.size(ofValue: noSIGPIPE))) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        nonisolated static func writeResponse(_ data: Data, to fd: Int32) throws {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR {
                        continue
                    }
                    guard written > 0 else {
                        throw POSIXError(written == 0 ? .EIO : POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
        }
    }

    enum APISocketError: Error, LocalizedError {
        case socketCreationFailed
        case bindFailed
        case listenFailed
        case pathTooLong

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed: "Failed to create Unix domain socket"
            case .bindFailed: "Failed to bind API socket"
            case .listenFailed: "Failed to listen on socket"
            case .pathTooLong: "Socket path exceeds maximum length"
            }
        }
    }
#endif
