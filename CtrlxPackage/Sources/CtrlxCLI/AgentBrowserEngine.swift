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
        var batch: [AgentBrowserBatchStep]?
        if action["command"] as? String == "batch" {
            guard let rows = action["steps"] else { throw AgentBrowserTransport.Failure("Invalid batch.") }
            batch = try AgentBrowserBatch.decode(JSONSerialization.data(withJSONObject: rows))
        }
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
        if let batch {
            return try AgentBrowserBatch.execute(batch, continueOnError: action["continueOnError"] as? Bool ?? false) { words in
                try ManagedAgentBrowser.perform(["command": "upstream", "words": words], tab: tab, directory: directory, context: context)
            }
        }
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

    static func readBaseline(_ path: String, image: Bool) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AgentBrowserTransport.Failure("Baseline must be a readable regular file, not a symlink.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let limit = image ? 6 * 1024 * 1024 : 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw AgentBrowserTransport.Failure("Baseline is not a bounded regular file.")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AgentBrowserTransport.Failure("Baseline exceeds the size limit.") }
        if image {
            guard data.count >= 24, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw AgentBrowserTransport.Failure("Screenshot baseline must be PNG.") }
            let width = data[16..<20].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let height = data[20..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 16000000 else { throw AgentBrowserTransport.Failure("Screenshot baseline exceeds 16 megapixels.") }
        } else if String(data: data, encoding: .utf8) == nil {
            throw AgentBrowserTransport.Failure("Snapshot baseline must be UTF-8 text.")
        }
        return data
    }

    static func baseArguments(root: URL) throws -> [String] {
        // Keep provider/launch flags identical for bootstrap AND later calls.
        // Upstream may restart its daemon when launch settings differ; without
        // an explicit provider such a restart can launch its own blank Chrome.
        var words = ["--config", root.appendingPathComponent("config.json").path,
         "--session", "page", "--json", "--provider", "ctrlx", "--no-webmcp"]
        let setup = root.appendingPathComponent("setup.json")
        if FileManager.default.fileExists(atPath: setup.path) {
            let value = try AgentBrowserTransport.readPrivateJSON(setup)
            if value["react"] as? Bool == true { words += ["--enable", "react-devtools"] }
            for name in value["scripts"] as? [String] ?? [] {
                guard name.hasSuffix(".js"), UUID(uuidString: String(name.dropLast(3))) != nil else { throw AgentBrowserTransport.Failure("Invalid init setup.") }
                words += ["--init-script", root.appendingPathComponent(name).path]
            }
        }
        return words
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
        var env = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
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
        let result = try performPage(action, tab: tab, directory: directory, context: context)
        let operation = action["command"] as? String
        let words = action["words"] as? [String] ?? []
        guard operation == "snapshot" || (operation == "upstream" && !["webmcp", "init"].contains(words.first)) else { return result }
        // The pinned CLI discards its preliminary launch response (including
        // one-shot availability). Read the same page's catalog explicitly after
        // the requested operation, without launching a second CLI or tool.
        let file = directory.appendingPathComponent("\(tab).engine.json")
        do {
            let state = try AgentBrowserTransport.readPrivateJSON(file)
            guard let path = state["directory"] as? String else { return result }
            return AgentBrowserPageMetadata.discover(after: result, root: URL(fileURLWithPath: path))
        } catch {
            if var body = result as? [String: Any] {
                body["webmcp"] = ["status": "unavailable", "untrusted": true]
                return body
            }
            return result
        }
    }

    private static func performPage(_ action: [String: Any], tab: String, directory: URL, context: [String: Any]) throws -> Any {
        let operation = action["command"] as? String
        let recordingFormat = action["format"] as? String ?? "webm"
        let recordingFPS = action["fps"] as? Int ?? 10
        let contactThreshold = action["contactSheetThreshold"] as? Double ?? 0.05
        if operation == "record" {
            try AgentBrowserPageCommand.validateRecording(format: recordingFormat, fps: recordingFPS)
            guard contactThreshold.isFinite, (0...1).contains(contactThreshold) else { throw AgentBrowserTransport.Failure("Contact sheet threshold must be 0...1.") }
        }
        var arguments = ["setup", "record"].contains(operation) ? ["snapshot", "-i"] : operation == "screenshot" ? ["screenshot"] : try AgentBrowserEngine.upstreamArguments(action)
        var baselines: [(index: Int, data: Data)] = []
        if arguments.first == "diff" {
            for (index, word) in arguments.enumerated() where ["--baseline", "-b"].contains(word) {
                baselines.append((index + 1, try readBaseline(arguments[index + 1], image: arguments[1] == "screenshot")))
            }
        }
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
        if operation == "setup" {
            guard let sources = action["sources"] as? [String], sources.count <= 4, sources.allSatisfy({ $0.utf8.count <= 48000 }) else {
                throw AgentBrowserTransport.Failure("Invalid init setup.")
            }
            // Relaunching an already connected provider can race the old
            // lease's WebSocket teardown. Explicitly stop our per-tab daemon
            // with its OLD launch configuration before replacing that setup.
            // Upstream disconnects an attached provider; it does not close CEF.
            let socket = root.appendingPathComponent("page.sock")
            if FileManager.default.fileExists(atPath: socket.path) {
                _ = try invoke(binary: binary, words: try baseArguments(root: root) + ["close"], env: env, root: root)
                let deadline = Date().addingTimeInterval(2)
                while FileManager.default.fileExists(atPath: socket.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                guard !FileManager.default.fileExists(atPath: socket.path) else { throw AgentBrowserTransport.Failure("Previous tab engine has not disconnected; setup not replaced.") }
            }
            let setupFile = root.appendingPathComponent("setup.json")
            if FileManager.default.fileExists(atPath: setupFile.path) {
                let old = try AgentBrowserTransport.readPrivateJSON(setupFile)
                for name in old["scripts"] as? [String] ?? [] where name.hasSuffix(".js") && UUID(uuidString: String(name.dropLast(3))) != nil {
                    try FileManager.default.removeItem(at: root.appendingPathComponent(name))
                }
            }
            var names: [String] = []
            for source in sources {
                let name = UUID().uuidString + ".js"
                try Data(source.utf8).write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
                names.append(name)
            }
            try AgentBrowserTransport.writePrivateJSON(["react": action["react"] as? Bool ?? false, "scripts": names], to: root.appendingPathComponent("setup.json"))
        }
        let base = try baseArguments(root: root)
        var temporaryInputs: [URL] = []
        defer { for file in temporaryInputs { try? FileManager.default.removeItem(at: file) } }
        for baseline in baselines {
            let file = root.appendingPathComponent(UUID().uuidString + ".baseline")
            try baseline.data.write(to: file, options: .withoutOverwriting)
            temporaryInputs.append(file)
            arguments[baseline.index] = file.path
        }
        if operation == "setup" || !FileManager.default.fileExists(atPath: root.appendingPathComponent("page.sock").path) {
            if (action["selector"] as? String)?.hasPrefix("@") == true || arguments.dropFirst().contains(where: { $0.hasPrefix("@") }) {
                throw AgentBrowserTransport.Failure("Engine reference state expired. Run snapshot again; no page action sent.")
            }
            // Disable the upstream preview listener before loading any page.
            _ = try invoke(binary: binary, words: base + ["stream", "disable"], env: env, root: root)
            _ = try invoke(binary: binary, words: base + ["snapshot", "-i"], env: env, root: root)
        }
        if arguments.first == "frame", arguments.count == 3, ["--name", "--url"].contains(arguments[1]) {
            // 0.38.1's daemon implements name/URL selection, but its CLI
            // parser treats these flags as CSS selectors. Use that existing
            // typed action, never a general raw-protocol escape hatch.
            return try AgentBrowserTransport.request([
                "id": UUID().uuidString, "action": "frame",
                arguments[1] == "--name" ? "name" : "url": arguments[2],
            ], socketPath: root.appendingPathComponent("page.sock").path, upstream: true)
        }
        if arguments.first == "init" { return try AgentBrowserPageMetadata.initCommand(arguments, root: root) }
        if Array(arguments.prefix(2)) == ["diff", "url"], arguments.contains("--screenshot") {
            let plan = try AgentBrowserPageCommand.urlScreenshotPlan(arguments)
            let firstImage = root.appendingPathComponent(UUID().uuidString + ".png")
            let firstText = root.appendingPathComponent(UUID().uuidString + ".txt")
            let output = root.appendingPathComponent(UUID().uuidString + ".png")
            defer { for path in [firstImage, firstText, output] { try? FileManager.default.removeItem(at: path) } }
            func step(_ words: [String]) throws -> [String: Any] {
                try invoke(binary: binary, words: base + ["batch"], env: env, root: root, input: JSONSerialization.data(withJSONObject: [words]))
            }
            // One existing tab, under its outer CLI lock; no new targets and no
            // retry if navigation or capture fails partway through the sequence.
            _ = try step(["open", arguments[2], "--wait-until", plan.wait])
            let snapshot = try step(plan.snapshot)
            guard let text = snapshot["snapshot"] as? String, text.utf8.count <= 1024 * 1024 else {
                throw AgentBrowserTransport.Failure("URL diff snapshot exceeds the baseline limit.")
            }
            try Data(text.utf8).write(to: firstText, options: .withoutOverwriting)
            let capture = try AgentBrowserPageCommand.screenshotPlan(plan.screenshot)
            _ = try step(capture.arguments + [firstImage.path])
            _ = try readBaseline(firstImage.path, image: true)
            _ = try step(["open", arguments[3], "--wait-until", plan.wait])
            let textDiff = try step(["diff", "snapshot", "--baseline", firstText.path] + plan.snapshot.dropFirst())
            var imageDiff = try step(plan.diff + ["--baseline", firstImage.path, "--output", output.path])
            imageDiff.removeValue(forKey: "diffPath"); imageDiff.removeValue(forKey: "path")
            var result: [String: Any] = ["url1": arguments[2], "url2": arguments[3], "snapshotDiff": textDiff, "screenshotDiff": imageDiff]
            if imageDiff["match"] as? Bool == true || imageDiff["dimensionMismatch"] is [String: Any] {
                result["artifactSkipped"] = true
            } else {
                result["data"] = try readBaseline(output.path, image: true).base64EncodedString()
            }
            if let metadata = imageDiff["webmcp"] ?? textDiff["webmcp"] { result["webmcp"] = metadata }
            return result
        }
        if operation == "record" {
            guard let seconds = action["seconds"] as? Int, (1...10).contains(seconds), let steps = action["steps"] as? [[String]] else {
                throw AgentBrowserTransport.Failure("Recording duration must be 1...10 seconds.")
            }
            if !steps.isEmpty { try AgentBrowserPageCommand.validateBatch(steps) }
            // Upstream requires ffmpeg. Do not inherit a shell PATH or fetch
            // executables at runtime. Expose only this explicit local dependency.
            guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
                throw AgentBrowserTransport.Failure("Recording requires locally installed Homebrew ffmpeg; no page action sent.")
            }
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = bin.appendingPathComponent("ffmpeg")
            if !FileManager.default.fileExists(atPath: encoder.path) { try FileManager.default.createSymbolicLink(atPath: encoder.path, withDestinationPath: ffmpeg) }
            let path = root.appendingPathComponent(UUID().uuidString + "." + recordingFormat)
            let sheetPath = path.deletingPathExtension().appendingPathExtension("contact-sheet.png")
            defer { for file in [path, sheetPath] { try? FileManager.default.removeItem(at: file) } }
            func recordCommand(_ words: [String]) throws -> [String: Any] {
                try invoke(binary: binary, words: base + ["batch"], env: env, root: root, input: JSONSerialization.data(withJSONObject: [words]))
            }
            var start = ["record", "start", path.path, "--fps", String(recordingFPS)]
            if action["cursor"] as? Bool == true { start.append("--cursor") }
            if action["contactSheet"] as? Bool == true { start += ["--contact-sheet", "--contact-sheet-threshold", String(contactThreshold)] }
            _ = try recordCommand(start)
            var stopped = false
            defer { if !stopped { _ = try? recordCommand(["record", "stop"]) } }
            let deadline = Date().addingTimeInterval(Double(seconds))
            for words in steps {
                _ = try perform(["command": "upstream", "words": words], tab: tab, directory: directory, context: context)
            }
            while Date() < deadline { Thread.sleep(forTimeInterval: min(0.1, max(0, deadline.timeIntervalSinceNow))) }
            var result = try recordCommand(["record", "stop"])
            stopped = true
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 6 * 1024 * 1024 else { throw AgentBrowserTransport.Failure("Video exceeds 6 MiB limit.") }
            result.removeValue(forKey: "path")
            result.removeValue(forKey: "contactSheetPath")
            if action["contactSheet"] as? Bool == true {
                let sheet = try readBaseline(sheetPath.path, image: true)
                guard size + sheet.count <= 6 * 1024 * 1024 else { throw AgentBrowserTransport.Failure("Video and contact sheet exceed the combined 6 MiB limit.") }
                result["contactSheetData"] = sheet.base64EncodedString()
            }
            result["data"] = try Data(contentsOf: path).base64EncodedString()
            return result
        }
        if let ext = AgentBrowserPageCommand.artifactExtension(arguments) {
            let path = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: path) }
            var flags: [String] = []
            if arguments.first == "screenshot" {
                let plan = try AgentBrowserPageCommand.screenshotPlan(arguments)
                arguments = plan.arguments; flags = plan.flags
                arguments.append(path.path)
            } else if arguments.first == "diff" {
                arguments += ["--output", path.path]
            } else { arguments.append(path.path) }
            var result = try invoke(binary: binary, words: base + flags + ["batch"], env: env, root: root, input: JSONSerialization.data(withJSONObject: [arguments]))
            // Conditional capture intentionally produces no file on unchanged
            // pixels. Preserve its revision/change metadata instead of failing.
            if (result["changed"] as? Bool == false && arguments.first == "screenshot") ||
                (arguments.first == "diff" && (result["match"] as? Bool == true || result["dimensionMismatch"] is [String: Any])) {
                result.removeValue(forKey: "path"); result.removeValue(forKey: "diffPath")
                result["artifactSkipped"] = true
                return result
            }
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 6 * 1024 * 1024 else { throw AgentBrowserTransport.Failure("Artifact exceeds 6 MiB limit.") }
            result.removeValue(forKey: "path"); result.removeValue(forKey: "diffPath")
            result["data"] = try Data(contentsOf: path).base64EncodedString()
            return result
        }
        let result = try invoke(binary: binary, words: base + ["batch"], env: env, root: root, input: JSONSerialization.data(withJSONObject: [arguments]))
        if operation == "setup" { return ["configured": true, "reloadRequired": true, "referencesExpired": true] }
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
