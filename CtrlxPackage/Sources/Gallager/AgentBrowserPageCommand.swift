import Foundation

/// Page commands only. Upstream owns parsing/semantics; CtrlX owns targets,
/// providers, launch configuration and artifact destinations.
enum AgentBrowserPageCommand {
    static let commands: Set<String> = [
        "snapshot", "click", "dblclick", "focus", "hover", "fill", "type", "press", "keydown", "keyup",
        "keyboard", "select", "check", "uncheck", "drag", "scroll", "scrollintoview", "mouse", "get", "is", "find",
        "wait", "read", "eval", "back", "forward", "reload", "pushstate", "frame", "dialog", "console", "errors",
        "highlight", "set", "network", "storage", "cookies", "screenshot", "pdf", "upload", "download", "vitals", "a11y", "diff",
    ]

    static func validate(_ words: [String]) throws {
        func reject(_ reason: String) throws { throw AgentBrowserTransport.Failure(reason) }
        guard let command = words.first, commands.contains(command), words.count <= 128,
              words.reduce(0, { $0 + $1.utf8.count }) <= 48000,
              words.allSatisfy({ !$0.contains("\0") }) else {
            try reject("Unsupported or oversized page command. Browser lifecycle remains in browser action; external runtimes, providers and global browser control are not exposed."); return
        }
        let sub = words.dropFirst().first ?? ""
        if command == "press" {
            _ = try AgentBrowserEngine.upstreamArguments(["command": "press", "key": sub])
        }
        if command == "keydown", !["Shift", "Alt", "Enter", "Tab", "Escape", "Space", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown", "Backspace", "Delete"].contains(sub) {
            try reject("Use page keys or Shift/Alt with keydown; browser/clipboard modifier chords are not exposed.")
        }
        let allowed: [String: Set<String>] = [
            "get": ["text", "html", "value", "attr", "url", "title", "count", "box", "styles"],
            "set": ["viewport", "device", "geo", "media", "headers", "offline", "credentials"],
            "network": ["requests", "route", "unroute", "har"],
            "cookies": ["", "get", "set"],
            "storage": ["local", "session"],
            "diff": ["snapshot"],
        ]
        if let choices = allowed[command], !choices.contains(sub) {
            try reject("Unsupported \(command) subcommand; global cookie clearing/export and browser-wide operations are not exposed.")
        }
        if command == "network", sub == "har", !(words.count >= 3 && ["start", "stop"].contains(words[2])) {
            try reject("Use network har start|stop.")
        }
        // These options would let a command write files outside the managed
        // artifact contract or read unbounded input via the upstream CLI.
        if ["eval", "read", "diff", "cookies"].contains(command), words.contains(where: { ["--output", "-o", "--stdin", "--file", "--curl", "--baseline"].contains($0) }) {
            try reject("Use --output before -- for artifacts; file imports and baseline diffs are not exposed.")
        }
        if command == "screenshot", words.dropFirst().contains(where: { !["--full", "-f", "--annotate"].contains($0) }) {
            try reject("Use command --output <new.png> -- screenshot [--full] [--annotate].")
        }
        if command == "pdf", words.count != 1 { try reject("Use command --output <new.pdf> -- pdf.") }
        if command == "download", words.count != 2 { try reject("Use command --output <new-file> -- download <selector>.") }
        if command == "network", sub == "har", words.count != 3 { try reject("Use command --output <new.har> -- network har stop.") }
    }

    static func artifactExtension(_ words: [String]) -> String? {
        switch words.first {
        case "screenshot": "png"
        case "pdf": "pdf"
        case "download": "download"
        case "network" where Array(words.prefix(3)) == ["network", "har", "stop"]: "har"
        default: nil
        }
    }
}
