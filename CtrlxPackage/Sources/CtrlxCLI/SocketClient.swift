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
    static func send(_ request: JSONRPCRequest, socketPath: String? = nil, timeoutSeconds: Int? = nil, responseLimit: Int? = nil) throws -> JSONRPCResponse {
        let path = socketPath ?? self.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.socketCreationFailed
        }
        defer { close(fd) }
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout.size(ofValue: noSIGPIPE)))
        if let timeoutSeconds {
            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
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
        guard connected == 0 else {
            throw CLIError.connectionFailed
        }

        // Encode and send request
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(UInt8(ascii: "\n"))

        let written = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
        guard written == data.count else {
            throw CLIError.writeFailed
        }

        // Read response (newline-delimited JSON)
        var responseData = Data()
        if let responseLimit {
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CLIError.responseTimeout }
                if let end = buffer.prefix(count).firstIndex(of: 10) {
                    responseData.append(contentsOf: buffer.prefix(end))
                    break
                }
                responseData.append(contentsOf: buffer.prefix(count))
                guard responseData.count <= responseLimit else { throw CLIError.responseTooLarge }
            }
            guard responseData.count <= responseLimit else { throw CLIError.responseTooLarge }
        } else {
            var byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1 {
                if byte == UInt8(ascii: "\n") { break }
                responseData.append(byte)
            }
        }

        guard !responseData.isEmpty else {
            throw CLIError.emptyResponse
        }

        return try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
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
