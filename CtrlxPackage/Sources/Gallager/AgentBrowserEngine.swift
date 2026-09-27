import CryptoKit
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

enum AgentBrowserEngine: String, CaseIterable {
    case ctrlx, vercel

    static func resolve(_ explicit: String?, saved: String?) throws -> Self {
        let name = explicit ?? saved ?? "vercel"
        guard let engine = Self(rawValue: name) else { throw AgentBrowserTransport.Failure("Engine must be ctrlx or vercel.") }
        return engine
    }

    /// Stable CLI contract. Tab lifecycle, bounded reads/waits and scrolling
    /// remain host-owned; selecting vercel never launches/replaces a browser.
    static let shared = Set(["tabs", "open", "read", "wait", "scroll", "navigate", "show", "close"])

    static func upstreamArguments(_ action: [String: Any]) throws -> [String] {
        func string(_ key: String) throws -> String {
            guard let value = action[key] as? String, value.utf8.count <= 16000 else {
                throw AgentBrowserTransport.Failure("Missing or oversized \(key).")
            }
            return value
        }
        let command = try string("command")
        switch command {
        case "upstream":
            guard let words = action["words"] as? [String] else { throw AgentBrowserTransport.Failure("Missing page command.") }
            try AgentBrowserPageCommand.validate(words)
            return words
        case "snapshot": return ["snapshot", "-i"]
        case "click": return ["click", try string("selector")]
        case "fill", "type": return [command, try string("selector"), try string("text")]
        case "select": return ["select", try string("selector"), try string("value")]
        case "check":
            guard let checked = action["checked"] as? Bool else { throw AgentBrowserTransport.Failure("check requires checked.") }
            return [checked ? "check" : "uncheck", try string("selector")]
        case "press":
            guard action["selector"] == nil else {
                throw AgentBrowserTransport.Failure("vercel press uses page focus; omit --selector or use --engine ctrlx.")
            }
            let key = try string("key")
            let parts = key.split(separator: "+").map(String.init)
            let keys = Set(["Enter", "Tab", "Escape", "Space", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown", "Backspace", "Delete"])
            guard let last = parts.last, keys.contains(last) || key == "Meta+A",
                  parts.dropLast().allSatisfy({ ["Shift", "Control", "Alt", "Meta"].contains($0) }),
                  (!parts.contains("Meta") && !parts.contains("Control")) || key == "Meta+A" else {
                throw AgentBrowserTransport.Failure("Unsupported page key; browser/clipboard shortcuts are blocked.")
            }
            return ["press", key]
        default: throw AgentBrowserTransport.Failure("Operation is not implemented by the vercel adapter.")
        }
    }

    static func perform(_ action: [String: Any], explicit: String?) throws -> Any {
        let (directory, context) = try AgentBrowserTransport.registeredContext()
        let engine = try resolve(explicit, saved: context["engine"] as? String)
        let operation = action["command"] as? String ?? ""
        if operation == "snapshot", engine == .ctrlx {
            throw AgentBrowserTransport.Failure("snapshot requires --engine vercel; ctrlx read remains available.")
        }
        guard let tab = action["tab"] as? String else {
            return try AgentBrowserTransport.perform(action, context: context)
        }
        guard UUID(uuidString: tab) != nil else { throw AgentBrowserTransport.Failure("Invalid tab ID.") }
        // Serialize both engines for a tab, across concurrent CLI processes.
        // No automatic fallback or retry after a mutating command.
        let lock = Darwin.open(directory.appendingPathComponent("\(tab).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw AgentBrowserTransport.Failure("Cannot lock browser tab.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AgentBrowserTransport.Failure("Tab busy; no action sent.") }
        defer { flock(lock, LOCK_UN) }
        if engine == .ctrlx || shared.contains(operation) {
            return try AgentBrowserTransport.perform(action, context: context)
        }
        return try ManagedAgentBrowser.perform(action, tab: tab, directory: directory, context: context)
    }
}

/// Runs only our pinned bundled executable with generated, private config.
/// Never executes shell input, npm/npx, auto-discovery, user providers or Chrome.
enum ManagedAgentBrowser {
    static let version = "0.38.1"
    static let sha256 = "2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d"

    static func baseArguments(root: URL) -> [String] {
        // Keep provider/launch flags identical for bootstrap AND later calls.
        // Upstream may restart its daemon when launch settings differ; without
        // an explicit provider such a restart can launch its own blank Chrome.
        ["--config", root.appendingPathComponent("config.json").path,
         "--session", "page", "--json", "--provider", "ctrlx", "--no-webmcp"]
    }

    static func verifiedExecutable() throws -> URL {
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binary = cli.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentBrowserEngine/agent-browser")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AgentBrowserTransport.Failure("This CtrlX build has no bundled vercel engine. Use --engine ctrlx or rebuild with scripts/build-agent-browser.sh.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw AgentBrowserTransport.Failure("Bundled vercel engine checksum mismatch; not executed.") }
        return binary
    }

    static func environment(root: URL, provider: URL, cli: URL) throws -> [String: String] {
        // Allowlist, not a blacklist: no AGENT_BROWSER_*, LD_*, DYLD_*, NODE_*
        // or cloud-provider credentials can redirect the managed engine.
        var env = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                   "LANG": "en_US.UTF-8", "NO_PROXY": "127.0.0.1,localhost",
                   "AGENT_BROWSER_SOCKET_DIR": root.path,
                   "AGENT_BROWSER_CONFIG": root.appendingPathComponent("config.json").path,
                   "CTRLX_ENGINE_PROVIDER_FILE": provider.path,
                   "AGENT_BROWSER_IDLE_TIMEOUT_MS": "300000", "AGENT_BROWSER_AUTOSAVE_INTERVAL_MS": "0",
                   "AGENT_BROWSER_NO_AUTO_DIALOG": "1"]
        let plugins: [[String: Any]] = [["name": "ctrlx", "command": cli.path,
            "args": ["browser", "engine-provider"], "capabilities": ["browser.provider"]]]
        env["AGENT_BROWSER_PLUGINS"] = String(decoding: try JSONSerialization.data(withJSONObject: plugins), as: UTF8.self)
        return env
    }

    static func runProcess(binary: URL, words: [String], env: [String: String], root: URL, input: Data?) throws -> Data {
        let temporary = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdout = temporary.appendingPathComponent("stdout")
        let stderr = temporary.appendingPathComponent("stderr")
        for url in [stdout, stderr] { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let child = Process()
        child.executableURL = binary; child.arguments = words; child.environment = env
        child.currentDirectoryURL = root
        let inputPath = temporary.appendingPathComponent("stdin.json")
        var inputHandle: FileHandle?
        if let input {
            FileManager.default.createFile(atPath: inputPath.path, contents: input, attributes: [.posixPermissions: 0o600])
            inputHandle = try FileHandle(forReadingFrom: inputPath)
        }
        defer { try? inputHandle?.close() }
        child.standardInput = inputHandle ?? FileHandle.nullDevice
        child.standardOutput = output; child.standardError = errors
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let deadline = Date().addingTimeInterval(30)
        while child.isRunning {
            let size = (try stdout.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let errorSize = (try stderr.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard Date() < deadline, size < 9 * 1024 * 1024, errorSize < 1024 * 1024 else {
                child.terminate()
                let stopDeadline = Date().addingTimeInterval(1)
                while child.isRunning, Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                throw AgentBrowserTransport.Failure("vercel command timed out or exceeded output limit; outcome unknown. Inspect the page; not retried.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard child.terminationStatus == 0 else {
            throw AgentBrowserTransport.Failure("vercel command failed; outcome may be unknown. Inspect with read/snapshot; not retried. References expire after navigation or engine idle shutdown.")
        }
        let data = try Data(contentsOf: stdout)
        guard data.count < 9 * 1024 * 1024 else { throw AgentBrowserTransport.Failure("Engine output too large.") }
        return data
    }

    static func invoke(binary: URL, words: [String], env: [String: String], root: URL, input: Data? = nil) throws -> [String: Any] {
        @Dependency(AgentBrowserEngineProcessClient.self) var process
        let data = try process.run(binary, words, env, root, input)
        let decoded = try JSONSerialization.jsonObject(with: data)
        // Commands travel as JSON on stdin via upstream batch, never through
        // its global argv scanner (preserves empty strings and leading dashes).
        let batch = decoded as? [[String: Any]]
        let value = input == nil ? decoded as? [String: Any] : (batch?.count == 1 ? batch?.first : nil)
        // Never print upstream stderr or an unsanitized error (may contain URL tokens).
        guard data.count < 9 * 1024 * 1024,
              let value,
              value["success"] as? Bool == true else {
            throw AgentBrowserTransport.Failure("vercel command failed; outcome may be unknown. Inspect with read/snapshot; not retried. References expire after navigation or engine idle shutdown.")
        }
        return value[input == nil ? "data" : "result"] as? [String: Any] ?? [:]
    }

    static func perform(_ action: [String: Any], tab: String, directory: URL, context: [String: Any]) throws -> Any {
        let operation = action["command"] as? String
        var arguments = operation == "screenshot" ? ["screenshot"] : try AgentBrowserEngine.upstreamArguments(action)
        if arguments.first == "upload" {
            guard arguments.count >= 3 else { throw AgentBrowserTransport.Failure("upload requires a selector and files.") }
            for index in 2..<arguments.count {
                let file = URL(fileURLWithPath: arguments[index]).standardizedFileURL
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw AgentBrowserTransport.Failure("Upload requires regular files.") }
                arguments[index] = file.path
            }
        }
        @Dependency(AgentBrowserEngineProcessClient.self) var process
        let binary = try process.executable()
        // Check ownership before creating any engine files or starting a process.
        guard let attach = try AgentBrowserTransport.perform(["command": "engine.attach", "tab": tab], context: context) as? [String: Any],
              let url = attach["url"] as? String else { throw AgentBrowserTransport.Failure("Engine attach failed.") }
        let stateFile = directory.appendingPathComponent("\(tab).engine.json")
        let root: URL
        if FileManager.default.fileExists(atPath: stateFile.path) {
            let state = try AgentBrowserTransport.readPrivateJSON(stateFile)
            guard let path = state["directory"] as? String else { throw AgentBrowserTransport.Failure("Invalid engine state.") }
            root = URL(fileURLWithPath: path, isDirectory: true)
            try AgentBrowserTransport.privatePath(root.path, type: S_IFDIR)
        } else {
            var template = Array("/tmp/ctrlx-engine-XXXXXX".utf8CString)
            guard mkdtemp(&template) != nil else { throw AgentBrowserTransport.Failure("Cannot create private engine directory.") }
            root = URL(fileURLWithPath: String(decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
            try AgentBrowserTransport.writePrivateJSON(["directory": root.path], to: stateFile)
        }
        let provider = root.appendingPathComponent("provider.json")
        try AgentBrowserTransport.writePrivateJSON(["url": url], to: provider)
        try AgentBrowserTransport.writePrivateJSON([:], to: root.appendingPathComponent("config.json"))
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let env = try environment(root: root, provider: provider, cli: cli)
        let base = baseArguments(root: root)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("page.sock").path) {
            if (action["selector"] as? String)?.hasPrefix("@") == true || arguments.dropFirst().contains(where: { $0.hasPrefix("@") }) {
                throw AgentBrowserTransport.Failure("Engine reference state expired. Run snapshot again; no page action sent.")
            }
            // Disable the upstream preview listener before loading any page.
            _ = try invoke(binary: binary, words: base + ["stream", "disable"], env: env, root: root)
            _ = try invoke(binary: binary, words: base + ["snapshot", "-i"], env: env, root: root)
        }
        if let ext = AgentBrowserPageCommand.artifactExtension(arguments) {
            let path = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: path) }
            // annotate is an upstream global *output* option, not a command
            // argument. Only this fixed safe flag is lifted out of JSON stdin.
            let flags = arguments.first == "screenshot" && arguments.contains("--annotate") ? ["--annotate"] : []
            if !flags.isEmpty { arguments.removeAll { $0 == "--annotate" } }
            if arguments.first == "screenshot" { arguments.insert(path.path, at: 1) } else { arguments.append(path.path) }
            _ = try invoke(binary: binary, words: base + flags + ["batch"], env: env, root: root, input: JSONSerialization.data(withJSONObject: [arguments]))
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 6 * 1024 * 1024 else { throw AgentBrowserTransport.Failure("Artifact exceeds 6 MiB limit.") }
            return ["data": try Data(contentsOf: path).base64EncodedString()]
        }
        let result = try invoke(binary: binary, words: base + ["batch"], env: env, root: root, input: JSONSerialization.data(withJSONObject: [arguments]))
        return operation == "snapshot" || operation == "upstream" ? result : [:]
    }
}

@DependencyClient
struct AgentBrowserEngineProcessClient: DependencyKey {
    var executable: @Sendable () throws -> URL
    var run: @Sendable (URL, [String], [String: String], URL, Data?) throws -> Data

    static let liveValue = Self(
        executable: { try ManagedAgentBrowser.verifiedExecutable() },
        run: { try ManagedAgentBrowser.runProcess(binary: $0, words: $1, env: $2, root: $3, input: $4) }
    )
}
