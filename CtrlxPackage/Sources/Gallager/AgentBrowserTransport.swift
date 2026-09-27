import Darwin
import Dependencies
import Foundation

/// Local-only protocol, independent of Relay and the existing WKWebView browser.
/// Same-UID software is trusted: this prevents accidental cross-instance routing,
/// not attacks by another process with access to this user's files/environment.
enum AgentBrowserTransport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static let stateDirectory: URL = {
        // Allows the existing isolated CtrlX E2E host to be exercised by real
        // CLI/Codex processes without touching production grants/profile.
        if let root = ProcessInfo.processInfo.environment["CTRLX_BROWSER_TEST_STATE_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("agent-browser", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ctrlx/agent-browser", isDirectory: true)
    }()

    static func privatePath(_ path: String, type: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == type, info.st_mode & 0o077 == 0 else {
            throw Failure("Browser control path is missing, not private, or a symlink: \(path)")
        }
    }

    static func request(_ object: [String: Any], socketPath: String) throws -> Any {
        try privatePath((socketPath as NSString).deletingLastPathComponent, type: S_IFDIR)
        try privatePath(socketPath, type: S_IFSOCK)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("Cannot create browser socket.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure("Browser socket path too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(socketPath.utf8) + [0])
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure("Agent Browser disconnected. Old grants are not renewed automatically; start a new Codex instance.") }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure("Unexpected browser socket owner.") }
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(10)
        guard bytes.count <= 65_536 else { throw Failure("Browser request exceeds 64 KB.") }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Browser write failed; not retried.") }
                offset += count
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !response.contains(10) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure("Browser response timed out or disconnected; action outcome unknown. Not retried.") }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 9 * 1_024 * 1_024 else { throw Failure("Browser response too large.") }
        }
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw Failure("Invalid browser response.")
        }
        guard json["ok"] as? Bool == true else { throw Failure(json["error"] as? String ?? "Browser operation failed.") }
        return json["result"] ?? [:]
    }

    static func readPrivateJSON(_ url: URL) throws -> [String: Any] {
        try privatePath(url.deletingLastPathComponent().path, type: S_IFDIR)
        try privatePath(url.path, type: S_IFREG)
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("Invalid browser context file.")
        }
        return result
    }

    static func writePrivateJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw Failure("Cannot protect browser context.") }
    }

    /// Serialize context creation and first registration across all tools of
    /// one live Codex. PID reuse gets a different directory and random secret.
    static func withRunContext<T>(
        for process: AgentBrowserProcess,
        root: URL = stateDirectory,
        operation: (URL, inout [String: Any]) throws -> T
    ) throws -> T {
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        let directory = runs.appendingPathComponent(process.runtimeKey, isDirectory: true)
        let parent = root.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for path in [root, runs, directory] {
            // Foundation can apply attributes after mkdir, exposing a transient
            // non-private directory to another first caller. Set mode atomically.
            guard mkdir(path.path, 0o700) == 0 || errno == EEXIST else {
                throw Failure("Cannot create private browser identity directory.")
            }
            try privatePath(path.path, type: S_IFDIR)
        }
        let lockPath = directory.appendingPathComponent("lock").path
        let lock = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure("Cannot lock browser context.") }
        defer { close(lock) }
        try privatePath(lockPath, type: S_IFREG)
        let deadline = Date().addingTimeInterval(15)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), Date() < deadline else {
                throw Failure("Browser identity is busy. No page action was sent; retry after the current registration finishes.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(lock, LOCK_UN) }
        let contextURL = directory.appendingPathComponent("context.json")
        var context: [String: Any]
        if FileManager.default.fileExists(atPath: contextURL.path) {
            context = try readPrivateJSON(contextURL)
            guard (context["pid"] as? NSNumber)?.int32Value == process.pid,
                  (context["startSeconds"] as? NSNumber)?.uint64Value == process.startSeconds,
                  (context["startMicros"] as? NSNumber)?.uint64Value == process.startMicros,
                  let run = context["run"] as? String, UUID(uuidString: run) != nil,
                  let secret = context["secret"] as? String, secret.count == 64 else {
                throw Failure("Saved browser identity does not match the calling Codex. Refusing to reuse it.")
            }
        } else {
            let run = UUID().uuidString
            let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
            let label = ProcessInfo.processInfo.environment["CTRLX_BROWSER_LABEL"] ?? "\(folder) / Codex"
            context = [
                "run": run,
                "secret": (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: ""),
                "label": String(label.prefix(150)) + " · " + run.prefix(6),
                "pid": process.pid, "startSeconds": process.startSeconds, "startMicros": process.startMicros,
            ]
            try writePrivateJSON(context, to: contextURL)
        }
        return try operation(contextURL, &context)
    }

    static func perform(_ arguments: [String: Any]) throws -> Any {
        @Dependency(AgentBrowserProcessClient.self) var processes
        let owner = try processes.callingCodex(from: getppid(), uid: getuid())
        let context = try withRunContext(for: owner) { contextURL, context in
            try processes.validate(owner)
            if context["socket"] == nil {
                let endpoint = stateDirectory.appendingPathComponent("endpoint.json")
                guard FileManager.default.fileExists(atPath: endpoint.path) else {
                    throw Failure("Open the source session in the current CtrlX app on this Mac first. Its embedded browser is not ready; no separate browser was launched.")
                }
                let discovery = try readPrivateJSON(endpoint)
                guard discovery["mode"] as? String == "embedded" else {
                    throw Failure("An older standalone Agent Browser is running. Quit it and open the updated CtrlX app before retrying.")
                }
                guard let socket = discovery["socket"] as? String else { throw Failure("Agent Browser endpoint unavailable.") }
                try processes.validate(owner)
                var registration = context
                registration["command"] = "register"
                guard let result = try request(registration, socketPath: socket) as? [String: Any], let epoch = result["epoch"] as? String else {
                    throw Failure("Invalid instance registration response.")
                }
                context["socket"] = socket
                context["epoch"] = epoch
                try writePrivateJSON(context, to: contextURL)
            }
            return context
        }
        try processes.validate(owner)
        guard let socket = context["socket"] as? String else { throw Failure("Missing browser endpoint.") }
        // Identity cannot be overridden by a CLI command or target flag.
        var request = arguments
        for key in ["run", "secret", "epoch"] { request[key] = context[key] }
        return try self.request(request, socketPath: socket)
    }
}
