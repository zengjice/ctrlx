import ArgumentParser
import Foundation

struct BrowserRecordStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-start",
        abstract: "Start a background Host MP4 recording; page interaction stays available (maximum 10 minutes)"
    )
    @Option var tab: String
    @Option(help: "New absolute .mp4 path on this Host; never overwrites") var output: String
    @Option(help: "Duration limit, 1...600 seconds") var seconds = 600
    @Option(help: "Capture rate, 1...30 fps") var fps = 10

    func validate() throws {
        guard
            (1...600).contains(seconds), (1...30).contains(fps),
            output.hasPrefix("/"), !output.contains("\0"),
            URL(fileURLWithPath: output).pathExtension.lowercased() == "mp4" else {
            throw ValidationError("Use a new absolute .mp4 path, 1...600 seconds and 1...30 fps.")
        }
        guard !FileManager.default.fileExists(atPath: output) else {
            throw ValidationError("Output exists; choose a new path.")
        }
    }

    func run() throws {
        try BrowserRecordingResult.printResult([
            "command": "record-start", "tab": tab, "output": output, "seconds": seconds, "fps": fps,
        ])
    }
}

struct BrowserRecordStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record-stop", abstract: "Stop recording and finalize the MP4; use record-status until completed")
    @Option var tab: String
    @Option(help: "Expected recording ID returned by record-start") var recording: String?

    func run() throws {
        var action: [String: Any] = ["command": "record-stop", "tab": tab]
        if let recording {
            action["recording"] = recording
        }
        try BrowserRecordingResult.printResult(action)
    }
}

struct BrowserRecordStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record-status", abstract: "Read recording state, stop reason and Host file path")
    @Option var tab: String
    @Option(help: "Expected recording ID returned by record-start") var recording: String?

    func run() throws {
        var action: [String: Any] = ["command": "record-status", "tab": tab]
        if let recording {
            action["recording"] = recording
        }
        try BrowserRecordingResult.printResult(action)
    }
}

private enum BrowserRecordingResult {
    static func printResult(_ action: [String: Any]) throws {
        guard let tab = action["tab"] as? String, UUID(uuidString: tab) != nil else {
            throw ValidationError("Invalid tab ID.")
        }
        // Recording observes a page; even a long-running Agent action must not
        // prevent querying or stopping it. The Host owns recording serialization.
        let (_, context) = try AgentBrowserTransport.registeredContext(for: action["command"] as? String)
        let result = try AgentBrowserTransport.perform(action, context: context)
        try print(String(decoding: JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys]), as: UTF8.self))
    }
}
