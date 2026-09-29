import ArgumentParser
import Darwin
import Dependencies
import Foundation

struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Control this instance's Chromium tabs embedded in its local CtrlX session (ordinary WebKit tabs are separate)",
        subcommands: [BrowserRunCommand.self, BrowserIdentityCommand.self, BrowserActionCommand.self, BrowserPageCommand.self, BrowserBatchCommand.self, BrowserSetupCommand.self, BrowserRecordCommand.self, BrowserEngineCommand.self, BrowserEngineProviderCommand.self]
    )
}

struct BrowserPageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "command", abstract: "Vercel page capabilities in an owned embedded tab; options precede --, e.g. --tab ID -- get title",
        discussion: "Page commands: " + AgentBrowserPageCommand.commands.sorted().joined(separator: ", ") + ". Use action open/tabs/navigate/show/close for tab lifecycle. screenshot/diff screenshot/diff url --screenshot/pdf/download/network har stop require --output before --. See browser batch/setup/record for managed workflows. No browser-wide or external-runtime commands.")
    @Option var tab: String
    @Option(help: "New artifact path; never overwrites an existing file") var output: String?
    @Option(help: "UTF-8 JavaScript for eval/init add, or a JSON object for webmcp invoke; max 48 KB") var inputFile: String?
    @Flag(help: "Read eval/init/WebMCP input from a pipe instead of a file or inline argument; max 48 KB") var inputStdin = false
    @Argument(parsing: .captureForPassthrough) var arguments: [String]

    func run() throws {
        var words = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        guard inputFile == nil || !inputStdin else { throw ValidationError("Choose --input-file or --input-stdin, not both.") }
        if let inputFile {
            words = try AgentBrowserPageCommand.withInput(words, data: ManagedAgentBrowser.readBaseline(inputFile, image: false))
        } else if inputStdin {
            guard isatty(STDIN_FILENO) == 0 else { throw ValidationError("--input-stdin requires piped input, not an interactive terminal.") }
            var data = Data()
            while data.count <= 48000 {
                let chunk = try FileHandle.standardInput.read(upToCount: 48001 - data.count) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            words = try AgentBrowserPageCommand.withInput(words, data: data)
        }
        try AgentBrowserPageCommand.validate(words)
        let artifact = AgentBrowserPageCommand.artifactExtension(words)
        guard (artifact != nil) == (output != nil) else { throw ValidationError("screenshot/diff screenshot/diff url --screenshot/pdf/download/network har stop require --output before --; other commands do not accept it.") }
        if let output, FileManager.default.fileExists(atPath: output) { throw ValidationError("Output already exists; no page action sent.") }
        let raw = try AgentBrowserEngine.perform(["command": "upstream", "tab": tab, "words": words], explicit: "vercel")
        let result = try AgentBrowserBatch.export(raw, to: output)
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys]), as: UTF8.self))
    }
}

struct BrowserBatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch", abstract: "Run 1...32 page commands under one tab lock; stop on first failure by default, never retry")
    @Option var tab: String
    @Option(help: "JSON array of argv arrays, or objects with command (argv) and optional output (new artifact path)") var commandsJSON: String
    @Flag(help: "Continue after failures without retrying them; inspect per-step success. Exit status remains failure if any step fails.") var continueOnError = false

    func run() throws {
        let steps = try AgentBrowserBatch.decode(Data(commandsJSON.utf8))
        let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(steps))
        let result = try AgentBrowserEngine.perform(["command": "batch", "tab": tab, "steps": rows, "continueOnError": continueOnError], explicit: "vercel")
        let success = (result as? [[String: Any]])?.allSatisfy { $0["success"] as? Bool == true } == true
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["ok": success, "result": result], options: [.sortedKeys]), as: UTF8.self))
        if !success { throw ExitCode.failure }
    }
}

struct BrowserSetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Replace this tab's init setup; reload explicitly afterwards to instrument a fresh document")
    @Option var tab: String
    @Flag(help: "Install upstream React DevTools hook before subsequent page scripts") var react = false
    @Option(parsing: .singleValue, help: "UTF-8 init script, up to four files; omitting all options clears future injection") var initScript: [String] = []

    func run() throws {
        guard initScript.count <= 4 else { throw ValidationError("At most four init scripts.") }
        let sources = try initScript.map { path -> String in
            let data = try ManagedAgentBrowser.readBaseline(path, image: false)
            guard data.count <= 48000, let source = String(data: data, encoding: .utf8) else { throw ValidationError("Init script must be UTF-8 and at most 48 KB.") }
            return source
        }
        let result = try AgentBrowserEngine.perform(["command": "setup", "tab": tab, "react": react, "sources": sources], explicit: "vercel")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys]), as: UTF8.self))
    }
}

struct BrowserRecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record", abstract: "Record a bounded 1...10 second WebM/MP4 clip of the owned page (requires local Homebrew ffmpeg)")
    @Option var tab: String
    @Option var output: String
    @Option var seconds: Int = 3
    @Option(help: "webm (default) or mp4") var format: String = "webm"
    @Option(help: "Capture frame rate, 1...60") var fps: Int = 10
    @Flag(help: "Include upstream cursor feedback in the recording") var cursor = false
    @Option(help: "Optional new PNG path for an upstream contact sheet") var contactSheet: String?
    @Option(help: "Changed-pixel ratio for contact-sheet selection, 0...1") var contactSheetThreshold: Double = 0.05
    @Option(help: "Optional JSON argv-array batch to execute while recording; stop on first failure") var commandsJSON: String?

    func run() throws {
        guard (1...10).contains(seconds), !FileManager.default.fileExists(atPath: output) else { throw ValidationError("Use 1...10 seconds and a new output path.") }
        try AgentBrowserPageCommand.validateRecording(format: format, fps: fps)
        guard contactSheetThreshold.isFinite, (0...1).contains(contactSheetThreshold) else { throw ValidationError("Contact sheet threshold must be 0...1.") }
        if let contactSheet {
            guard !FileManager.default.fileExists(atPath: contactSheet),
                  URL(fileURLWithPath: contactSheet).standardizedFileURL != URL(fileURLWithPath: output).standardizedFileURL else {
                throw ValidationError("Contact sheet must use a separate new path.")
            }
        }
        var steps: [[String]] = []
        if let commandsJSON {
            guard commandsJSON.utf8.count <= 65536, let parsed = try JSONSerialization.jsonObject(with: Data(commandsJSON.utf8)) as? [[String]] else { throw ValidationError("Invalid command batch.") }
            try AgentBrowserPageCommand.validateBatch(parsed)
            steps = parsed
        }
        let result = try AgentBrowserEngine.perform(["command": "record", "tab": tab, "seconds": seconds, "steps": steps,
            "format": format, "fps": fps, "cursor": cursor, "contactSheet": contactSheet != nil,
            "contactSheetThreshold": contactSheetThreshold], explicit: "vercel")
        guard let body = result as? [String: Any], let encoded = body["data"] as? String,
              let data = Data(base64Encoded: encoded), AgentBrowserPageCommand.isRecording(data, format: format) else { throw ValidationError("Invalid recording artifact.") }
        var sheet: Data?
        if contactSheet != nil {
            guard let encoded = body["contactSheetData"] as? String, let png = Data(base64Encoded: encoded),
                  png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ValidationError("Invalid contact sheet artifact.") }
            sheet = png
        }
        let fd = Darwin.open(output, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ValidationError("Output exists or cannot be created.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.close()
        var summary: [String: Any] = ["path": output, "bytes": data.count, "format": format, "fps": fps, "cursor": cursor]
        if let contactSheet, let sheet {
            let sheetFD = Darwin.open(contactSheet, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard sheetFD >= 0 else { throw ValidationError("Video saved at \(output), but contact-sheet output exists or cannot be created. No retry performed.") }
            let sheetHandle = FileHandle(fileDescriptor: sheetFD, closeOnDealloc: true)
            try sheetHandle.write(contentsOf: sheet); try sheetHandle.close()
            summary["contactSheetPath"] = contactSheet
            summary["contactSheetFrames"] = body["contactSheetFrames"]
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": summary], options: [.sortedKeys]), as: UTF8.self))
    }
}

/// Read-only diagnosis. Does not create credentials or launch the browser.
struct BrowserIdentityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "identity", abstract: "Identify the calling Codex without opening the browser (no credentials printed)")

    func run() throws {
        @Dependency(AgentBrowserProcessClient.self) var processes
        let owner = try processes.callingCodex(from: getppid(), uid: getuid())
        let json = try JSONSerialization.data(withJSONObject: ["pid": owner.pid, "runtime": owner.runtimeKey], options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}

struct BrowserRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Optional launch convenience; plain codex also discovers its browser identity automatically")
    @Option(help: "Human-readable session / window / pane label") var label: String?
    @Argument(parsing: .captureForPassthrough) var command: [String]

    func run() throws {
        let words = command.first == "--" ? Array(command.dropFirst()) : command
        guard let executable = words.first, !executable.isEmpty else { throw ValidationError("Use: ctrlx browser run -- codex [arguments]") }
        if let label { setenv("CTRLX_BROWSER_LABEL", label, 1) }
        // Compatibility convenience only. Identity is discovered at action time,
        // not granted by this command or inherited through environment variables.
        let pointers = words.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        pointers.withUnsafeBufferPointer { buffer in _ = execvp(executable, buffer.baseAddress!) }
        throw AgentBrowserTransport.Failure("Cannot execute \(executable): \(String(cString: strerror(errno)))")
    }
}

struct BrowserActionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "action", abstract: "tabs | open | read | snapshot (vercel) | click | type | fill | press | scroll | wait | select | check | screenshot | navigate | show | close")
    @Argument var operation: String
    @Option(help: "ctrlx (original) or vercel; overrides this Codex instance's saved engine") var engine: String?
    @Option var tab: String?
    @Option var url: String?
    @Option var selector: String?
    @Option var text: String?
    @Option(help: "Page key, e.g. Enter, Shift+Tab, Meta+A; no browser/clipboard shortcuts") var key: String?
    @Option(parsing: .unconditional, help: "Horizontal scroll distance in CSS pixels (-10000...10000)") var deltaX: Int?
    @Option(parsing: .unconditional, help: "Vertical scroll distance in CSS pixels (-10000...10000)") var deltaY: Int?
    @Option(help: "Wait condition: ready, attached, visible, hidden, enabled") var state: String?
    @Option(help: "Wait deadline in milliseconds (100...10000; default 5000)") var timeoutMs: Int?
    @Option(help: "Exact option value for a native single-select") var value: String?
    @Option(help: "Desired checkbox/radio state: true or false") var checked: Bool?
    @Option(help: "Read text offset (default 0)") var textOffset: Int?
    @Option(help: "Read text page size (1...20000; default 20000)") var textLimit: Int?
    @Option(help: "Read controls offset (default 0)") var controlOffset: Int?
    @Option(help: "Read controls page size (1...100; default 100)") var controlLimit: Int?
    @Option(help: "New PNG path; never overwrites an existing file") var output: String?

    func run() throws {
        _ = try AgentBrowserEngine.resolve(engine, saved: nil)
        guard ["tabs", "open", "read", "snapshot", "click", "type", "fill", "press", "scroll", "wait", "select", "check", "screenshot", "navigate", "show", "close"].contains(operation) else {
            throw ValidationError("Unsupported browser operation.")
        }
        if !["tabs", "open"].contains(operation), tab == nil { throw ValidationError("This operation requires --tab.") }
        if ["click", "type", "fill", "select", "check"].contains(operation), selector == nil { throw ValidationError("This operation requires --selector.") }
        if ["type", "fill"].contains(operation), text == nil { throw ValidationError("This operation requires --text (empty text clears with fill).") }
        if operation == "press", key == nil { throw ValidationError("press requires --key.") }
        if operation == "select", value == nil { throw ValidationError("select requires --value.") }
        if operation == "check", checked == nil { throw ValidationError("check requires --checked true|false.") }
        var payload: [String: Any] = ["command": operation]
        if let tab { payload["tab"] = tab }
        if let url { payload["url"] = url }
        if let selector { payload["selector"] = selector }
        if let text { payload["text"] = text }
        if let key { payload["key"] = key }
        if let deltaX { payload["deltaX"] = deltaX }
        if let deltaY { payload["deltaY"] = deltaY }
        if let state { payload["state"] = state }
        if let timeoutMs { payload["timeoutMs"] = timeoutMs }
        if let value { payload["value"] = value }
        if let checked { payload["checked"] = checked }
        if let textOffset { payload["textOffset"] = textOffset }
        if let textLimit { payload["textLimit"] = textLimit }
        if let controlOffset { payload["controlOffset"] = controlOffset }
        if let controlLimit { payload["controlLimit"] = controlLimit }
        if operation == "screenshot", output == nil { throw ValidationError("screenshot requires --output <new.png>") }
        var result = try AgentBrowserEngine.perform(payload, explicit: engine)
        if operation == "screenshot", let output {
            guard let body = result as? [String: Any], let encoded = body["data"] as? String,
                  let image = Data(base64Encoded: encoded), image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw ValidationError("Invalid PNG screenshot.")
            }
            let fd = Darwin.open(output, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ValidationError("Output exists or cannot be created.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: image)
            try handle.close()
            result = ["path": output]
        }
        let json = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}

struct BrowserEngineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "engine", abstract: "Read/set this Codex instance's engine: vercel (default) or ctrlx; existing tabs and logins are kept")
    @Argument var name: String?

    func run() throws {
        if let name { _ = try AgentBrowserEngine.resolve(name, saved: nil) }
        @Dependency(AgentBrowserProcessClient.self) var processes
        let owner = try processes.callingCodex(from: getppid(), uid: getuid())
        let selected = try AgentBrowserTransport.withRunContext(for: owner) { url, context in
            try processes.validate(owner)
            if let name {
                context["engine"] = name
                try AgentBrowserTransport.writePrivateJSON(context, to: url)
            }
            return try AgentBrowserEngine.resolve(nil, saved: context["engine"] as? String).rawValue
        }
        print("{\"engine\":\"\(selected)\",\"scope\":\"calling-codex\",\"vercelVersion\":\"\(ManagedAgentBrowser.version)\"}")
    }
}

/// Private provider protocol, not a user-controlled command passthrough.
struct BrowserEngineProviderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "engine-provider", shouldDisplay: false)
    func run() throws {
        let data = try FileHandle.standardInput.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536,
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["protocol"] as? String == "agent-browser.plugin.v1",
              let path = ProcessInfo.processInfo.environment["CTRLX_ENGINE_PROVIDER_FILE"] else {
            throw ValidationError("Invalid managed provider request.")
        }
        let config = try AgentBrowserTransport.readPrivateJSON(URL(fileURLWithPath: path))
        guard let address = config["url"] as? String, let url = URLComponents(string: address),
              url.scheme == "ws", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.count == 73 else { throw ValidationError("Invalid scoped engine endpoint.") }
        var response: [String: Any] = ["protocol": "agent-browser.plugin.v1", "success": true]
        switch request["type"] as? String {
        case "browser.launch": response["browser"] = ["cdpUrl": address, "directPage": true]
        case "plugin.manifest": response["manifest"] = ["name": "ctrlx", "capabilities": ["browser.provider"]]
        default: throw ValidationError("Unsupported managed provider request.")
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self))
    }
}
