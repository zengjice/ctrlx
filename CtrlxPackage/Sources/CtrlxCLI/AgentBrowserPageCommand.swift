import Foundation

/// Page commands only. Upstream owns parsing/semantics; CtrlX owns targets,
/// providers, launch configuration and artifact destinations.
enum AgentBrowserPageCommand {
    static let commands: Set<String> = [
        "snapshot", "click", "dblclick", "focus", "hover", "fill", "type", "press", "keydown", "keyup",
        "keyboard", "select", "check", "uncheck", "drag", "scroll", "scrollintoview", "mouse", "get", "is", "find",
        "wait", "read", "eval", "back", "forward", "reload", "pushstate", "frame", "dialog", "console", "errors",
        "highlight", "set", "network", "storage", "cookies", "screenshot", "pdf", "upload", "download", "vitals", "a11y", "diff",
        "react", "webmcp", "init",
    ]

    static func validate(_ words: [String]) throws {
        func reject(_ reason: String) throws { throw AgentBrowserTransport.Failure(reason) }
        guard let command = words.first, commands.contains(command), words.count <= 128,
              words.reduce(0, { $0 + $1.utf8.count }) <= 48000,
              words.allSatisfy({ !$0.contains("\0") }) else {
            try reject("Unsupported or oversized page command. Browser lifecycle remains in browser action; external runtimes, providers and global browser control are not exposed."); return
        }
        let sub = words.dropFirst().first ?? ""
        if command == "init" {
            guard (sub == "list" && words.count == 2) ||
                  (sub == "add" && words.count == 3) ||
                  (sub == "remove" && words.count == 3 && UUID(uuidString: words[2]) != nil) else {
                try reject("Use init list, init add <source>, or init remove <returned-id>; input files precede --."); return
            }
        }
        if command == "press" {
            _ = try AgentBrowserEngine.upstreamArguments(["command": "press", "key": sub])
        }
        if command == "keydown", !["Shift", "Alt", "Enter", "Tab", "Escape", "Space", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown", "Backspace", "Delete"].contains(sub) {
            try reject("Use page keys or Shift/Alt with keydown; browser/clipboard modifier chords are not exposed.")
        }
        let allowed: [String: Set<String>] = [
            "get": ["text", "html", "value", "attr", "url", "title", "count", "box", "styles"],
            "set": ["viewport", "device", "geo", "media", "headers", "offline", "credentials"],
            "network": ["requests", "request", "route", "unroute", "har"],
            "cookies": ["", "get", "set"],
            "storage": ["local", "session"],
            "diff": ["snapshot", "screenshot", "url"],
            "react": ["tree", "inspect", "renders", "suspense"],
            "webmcp": ["list", "invoke", "result", "cancel"],
        ]
        if let choices = allowed[command], !choices.contains(sub) {
            try reject("Unsupported \(command) subcommand; global cookie clearing/export and browser-wide operations are not exposed.")
        }
        if command == "network", sub == "har", !(words.count >= 3 && ["start", "stop"].contains(words[2])) {
            try reject("Use network har start|stop.")
        }
        if command == "network", sub == "request", words.count != 3 || words[2].isEmpty {
            try reject("Use network request <observed-request-id>.")
        }
        // These options would let a command write files outside the managed
        // artifact contract or read unbounded input via the upstream CLI.
        if ["eval", "read", "diff", "cookies", "webmcp"].contains(command), words.contains(where: { ["--output", "-o", "--stdin", "--file", "--curl"].contains($0) }) {
            try reject("Use --output before -- for artifacts; unbounded file imports are not exposed.")
        }
        if command == "screenshot" { _ = try screenshotPlan(words) }
        if command == "frame" {
            let extended = ["--name", "--url"].contains(sub)
            guard words.count == (extended ? 3 : 2), !sub.isEmpty,
                  extended ? !words[2].isEmpty : !sub.hasPrefix("--") else {
                try reject("Use frame <selector|main> or frame --name|--url <value>."); return
            }
        }
        if command == "webmcp", let index = words.firstIndex(of: "--params"), index + 1 < words.count, words[index + 1].hasPrefix("@") {
            try reject("WebMCP params must be inline JSON, not a file import.")
        }
        if command == "diff" {
            if sub == "url" {
                guard words.count >= 4, words[2...3].allSatisfy({
                    let url = URLComponents(string: $0)
                    return ["http", "https"].contains(url?.scheme) && url?.host != nil && url?.user == nil && url?.password == nil
                }) else {
                    try reject("diff url requires two HTTP(S) URLs."); return
                }
                if words.contains("--screenshot") { _ = try urlScreenshotPlan(words) }
            }
            for (index, word) in words.enumerated() where ["--baseline", "-b"].contains(word) {
                guard sub != "url", index + 1 < words.count, !words[index + 1].isEmpty else {
                    try reject("diff baseline requires a local regular file."); return
                }
            }
            if sub == "screenshot", !words.contains("--baseline") && !words.contains("-b") {
                try reject("diff screenshot requires --baseline <png>.")
            }
        }
        if command == "pdf", words.count != 1 { try reject("Use command --output <new.pdf> -- pdf.") }
        if command == "download", words.count != 2 { try reject("Use command --output <new-file> -- download <selector>.") }
        if command == "network", sub == "har" {
            let contentOption = words.count == 5 && words[2] == "start" && words[3] == "--content" && ["all", "text", "none"].contains(words[4])
            if words.count != 3 && !contentOption { try reject("Use network har start [--content all|text|none], or --output <new.har> -- network har stop.") }
        }
    }

    /// File/stdin bytes become a single literal argument before reaching the
    /// upstream parser. Never let it open caller-selected paths itself.
    static func withInput(_ words: [String], data: Data) throws -> [String] {
        guard data.count <= 48000, let text = String(data: data, encoding: .utf8) else {
            throw AgentBrowserTransport.Failure("Command input must be UTF-8 and at most 48 KB.")
        }
        let result: [String]
        if words == ["eval"] || words == ["init", "add"] {
            result = words + [text]
        } else if words.count >= 3, Array(words.prefix(2)) == ["webmcp", "invoke"], !words.contains("--params") {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw AgentBrowserTransport.Failure("WebMCP input must be a JSON object.")
            }
            result = words + ["--params", text]
        } else {
            throw AgentBrowserTransport.Failure("Input file/stdin supports eval/init add without inline code, or webmcp invoke without --params.")
        }
        try validate(result)
        return result
    }

    static func artifactExtension(_ words: [String]) -> String? {
        switch words.first {
        case "screenshot": (try? screenshotPlan(words).flags.contains("jpeg")) == true ? "jpeg" : "png"
        case "diff" where words.dropFirst().first == "screenshot": "png"
        case "diff" where words.dropFirst().first == "url" && words.contains("--screenshot"): "png"
        case "pdf": "pdf"
        case "download": "download"
        case "network" where Array(words.prefix(3)) == ["network", "har", "stop"]: "har"
        default: nil
        }
    }

    /// Upstream 0.38.1 parses --screenshot but its native URL handler ignores
    /// it. Compose its existing navigation/snapshot/image-diff operations.
    static func urlScreenshotPlan(_ words: [String]) throws -> (wait: String, snapshot: [String], screenshot: [String], diff: [String]) {
        guard words.count >= 5, Array(words.prefix(2)) == ["diff", "url"] else {
            throw AgentBrowserTransport.Failure("Use diff url <url1> <url2> --screenshot.")
        }
        var wait = "load", snapshot = ["snapshot"], screenshot = ["screenshot"], diff = ["diff", "screenshot"]
        var index = 4, seen = Set<String>()
        while index < words.count {
            let option = words[index]
            guard seen.insert(option).inserted else { throw AgentBrowserTransport.Failure("Duplicate URL diff option.") }
            switch option {
            case "--screenshot": break
            case "--full", "-f": screenshot.append("--full"); diff.append("--full")
            case "--compact", "-c": snapshot.append("--compact")
            case "--wait-until", "--selector", "-s", "--depth", "-d":
                index += 1
                guard index < words.count else { throw AgentBrowserTransport.Failure("Missing URL diff option value.") }
                let value = words[index]
                if option == "--wait-until" {
                    guard ["load", "domcontentloaded", "networkidle"].contains(value) else { throw AgentBrowserTransport.Failure("Invalid URL diff wait strategy.") }
                    wait = value
                } else if ["--depth", "-d"].contains(option) {
                    guard let depth = UInt32(value) else { throw AgentBrowserTransport.Failure("Invalid URL diff depth.") }
                    snapshot += ["--depth", String(depth)]
                } else {
                    guard !value.isEmpty else { throw AgentBrowserTransport.Failure("URL diff selector cannot be empty.") }
                    snapshot += ["--selector", value]
                    screenshot += ["--selector", value]
                    diff += ["--selector", value]
                }
            default: throw AgentBrowserTransport.Failure("Unsupported URL screenshot diff option.")
            }
            index += 1
        }
        guard seen.contains("--screenshot") else { throw AgentBrowserTransport.Failure("Missing --screenshot.") }
        _ = try screenshotPlan(screenshot)
        return (wait, snapshot, screenshot, diff)
    }

    static func validateRecording(format: String, fps: Int) throws {
        guard ["webm", "mp4"].contains(format), (1...60).contains(fps) else {
            throw AgentBrowserTransport.Failure("Recording format must be webm or mp4 and fps must be 1...60.")
        }
    }

    static func isRecording(_ data: Data, format: String) -> Bool {
        if format == "webm" { return data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) }
        return format == "mp4" && data.count >= 12 && data.dropFirst(4).prefix(4) == Data("ftyp".utf8)
    }

    /// Explicit selector avoids the upstream selector/path heuristic. Only
    /// these fixed output flags may escape JSON into the global argv scanner.
    static func screenshotPlan(_ words: [String]) throws -> (arguments: [String], flags: [String]) {
        var arguments = ["screenshot"], flags: [String] = [], selector: String?
        var seen = Set<String>(), index = 1
        while index < words.count {
            let option = words[index]
            guard seen.insert(option).inserted else { throw AgentBrowserTransport.Failure("Duplicate screenshot option.") }
            switch option {
            case "--full", "-f", "--if-changed": arguments.append(option)
            case "--annotate": flags.append(option)
            case "--selector", "--format", "--quality", "--threshold":
                index += 1
                guard index < words.count else { throw AgentBrowserTransport.Failure("Missing screenshot option value.") }
                let value = words[index]
                switch option {
                case "--selector":
                    guard !value.isEmpty, !value.hasPrefix("-") else { throw AgentBrowserTransport.Failure("Invalid screenshot selector.") }
                    selector = value
                case "--format":
                    guard ["png", "jpeg"].contains(value) else { throw AgentBrowserTransport.Failure("Screenshot format must be png or jpeg.") }
                    flags += ["--screenshot-format", value]
                case "--quality":
                    guard let quality = Int(value), (0...100).contains(quality) else { throw AgentBrowserTransport.Failure("JPEG quality must be 0...100.") }
                    flags += ["--screenshot-quality", value]
                default:
                    guard let threshold = Double(value), threshold.isFinite, (0...1).contains(threshold) else { throw AgentBrowserTransport.Failure("Screenshot threshold must be 0...1.") }
                    arguments += [option, value]
                }
            default: throw AgentBrowserTransport.Failure("Use screenshot [--selector CSS] [--full] [--annotate] [--format png|jpeg] [--quality 0...100] [--if-changed] [--threshold 0...1]; output precedes --.")
            }
            index += 1
        }
        if seen.contains("--quality"), !flags.contains("jpeg") { throw AgentBrowserTransport.Failure("--quality requires --format jpeg.") }
        if let selector { arguments.insert(selector, at: 1) }
        return (arguments, flags)
    }

    static func validateBatch(_ steps: [[String]]) throws {
        guard !steps.isEmpty, steps.count <= 32, steps.flatMap({ $0 }).reduce(0, { $0 + $1.utf8.count }) <= 48000 else {
            throw AgentBrowserTransport.Failure("Batch requires 1...32 commands and at most 48 KB of arguments.")
        }
        for words in steps {
            try validate(words)
            guard artifactExtension(words) == nil else { throw AgentBrowserTransport.Failure("Artifacts must be captured separately with command --output, not in batch.") }
        }
    }
}
