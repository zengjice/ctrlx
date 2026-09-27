import ArgumentParser
import Darwin
import Dependencies
import Foundation

struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Control this instance's Chromium tabs embedded in its local CtrlX session (ordinary WebKit tabs are separate)",
        subcommands: [BrowserRunCommand.self, BrowserIdentityCommand.self, BrowserActionCommand.self]
    )
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
    static let configuration = CommandConfiguration(commandName: "action", abstract: "tabs | open | read | click | type | fill | press | scroll | wait | select | check | screenshot | navigate | show | close")
    @Argument var operation: String
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
        guard ["tabs", "open", "read", "click", "type", "fill", "press", "scroll", "wait", "select", "check", "screenshot", "navigate", "show", "close"].contains(operation) else {
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
        var result = try AgentBrowserTransport.perform(payload)
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
