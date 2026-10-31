import Foundation

/// Connects to the CtrlX app's Unix domain socket and sends JSON-RPC requests.
enum SocketClient {
    /// Resolves the socket path from environment or default.
    static var socketPath: String {
        ProcessInfo.processInfo.environment["CTRLX_SOCKET"]
            ?? NSTemporaryDirectory() + "ctrlx.sock"
    }

    /// Sends a JSON-RPC request and returns the response.
    ///
    /// For most commands this is a simple request-response. For blocking commands
    /// like `editor.open`, the server delays its response until the user finishes,
    /// so the socket read naturally blocks until completion.
    /// An explicit timeout covers connect, writes and the complete response,
    /// including peers that send partial data without finishing a frame.
    static func send(_ request: JSONRPCRequest, socketPath: String? = nil, timeoutSeconds: TimeInterval? = nil, responseLimit: Int? = nil) throws -> JSONRPCResponse {
        let deadline = timeoutSeconds.map { ContinuousClock.now.advanced(by: .seconds($0)) }
        let path = socketPath ?? self.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.socketCreationFailed
        }
        defer { close(fd) }
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout.size(ofValue: noSIGPIPE)))
        if deadline != nil {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw CLIError.connectionFailed
            }
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw CLIError.pathTooLong
        }
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
        if connected != 0 {
            guard errno == EINPROGRESS, let deadline else { throw CLIError.connectionFailed }
            try waitForSocket(fd, events: Int16(POLLOUT), deadline: deadline)
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: failure))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else {
                throw CLIError.connectionFailed
            }
        }

        // Encode and send request
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(UInt8(ascii: "\n"))

        try writeAll(data) { bytes in
            while true {
                if let deadline {
                    try waitForSocket(fd, events: Int16(POLLOUT), deadline: deadline)
                }
                let count = Darwin.write(fd, bytes.baseAddress, bytes.count)
                if count < 0, deadline != nil, errno == EAGAIN {
                    continue
                }
                return count
            }
        }

        // Read response (newline-delimited JSON)
        var responseData = Data()
        if responseLimit != nil || deadline != nil {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                if let deadline {
                    try waitForSocket(fd, events: Int16(POLLIN), deadline: deadline)
                }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR || (deadline != nil && errno == EAGAIN) {
                    continue
                }
                guard count > 0 else { throw CLIError.responseTimeout }
                if let end = buffer.prefix(count).firstIndex(of: 10) {
                    responseData.append(contentsOf: buffer.prefix(end))
                    break
                }
                responseData.append(contentsOf: buffer.prefix(count))
                if let responseLimit, responseData.count > responseLimit {
                    throw CLIError.responseTooLarge
                }
            }
            if let responseLimit, responseData.count > responseLimit {
                throw CLIError.responseTooLarge
            }
        } else {
            var byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1 {
                if byte == UInt8(ascii: "\n") {
                    break
                }
                responseData.append(byte)
            }
        }

        guard !responseData.isEmpty else {
            throw CLIError.emptyResponse
        }

        return try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
    }

    private static func waitForSocket(_ fd: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw CLIError.responseTimeout }
            let components = remaining.components
            let milliseconds = ceil(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1E15)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(milliseconds, Double(Int32.max))))
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else { throw CLIError.responseTimeout }
            return
        }
    }

    /// Large artifact chunks may require multiple writes on the same connection.
    /// Continue only the remaining bytes; never retry the whole request.
    static func writeAll(_ data: Data, write: (UnsafeRawBufferPointer) throws -> Int) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let remaining = UnsafeRawBufferPointer(rebasing: bytes[offset...])
                let count = try write(remaining)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0, count <= remaining.count else { throw CLIError.writeFailed }
                offset += count
            }
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case socketCreationFailed
    case connectionFailed
    case writeFailed
    case emptyResponse
    case pathTooLong
    case responseTimeout
    case responseTooLarge

    var description: String {
        switch self {
        case .socketCreationFailed: "Failed to create socket"
        case .connectionFailed: "Failed to connect to CtrlX (is it running?)"
        case .writeFailed: "Failed to send request"
        case .emptyResponse: "Empty response from server"
        case .pathTooLong: "Socket path exceeds maximum length"
        case .responseTimeout: "Response timed out or disconnected. Action outcome is unknown; no retry was performed"
        case .responseTooLarge: "Response exceeds the command's size limit"
        }
    }
}
