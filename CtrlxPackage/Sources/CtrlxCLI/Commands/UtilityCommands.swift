import ArgumentParser
import Foundation

struct PingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Check if CtrlX is running"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "system.ping", options: options, timeoutSeconds: 5)
        if options.json {
            printResponse(response, json: true)
        } else {
            print("pong")
        }
    }
}

struct WaitReadyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait-ready",
        abstract: "Block until CtrlX responds to ping, or fail after a timeout",
        discussion: """
        Polls `system.ping` until it succeeds, then exits 0. Useful in
        login-time scripts that fire before the CtrlX app finishes launching.
        """
    )

    @Option(name: .long, help: "Maximum seconds to wait before giving up (default: 30)")
    var timeout: Double = 30

    @Option(name: .long, help: "Seconds between polls (default: 0.2)")
    var interval = 0.2

    @OptionGroup var options: GlobalOptions

    mutating func validate() throws {
        guard timeout.isFinite, timeout > 0, interval.isFinite, interval > 0 else {
            throw ValidationError("Timeout and interval must be finite positive seconds.")
        }
    }

    func run() throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let request = JSONRPCRequest(id: UUID().uuidString, method: "system.ping", params: [:])
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let remainingSeconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1E18
            if
                let response = try? SocketClient.send(request, socketPath: options.socket, timeoutSeconds: min(1, remainingSeconds)),
                response.ok {
                if options.json {
                    if
                        let data = try? JSONEncoder().encode(response),
                        let str = String(data: data, encoding: .utf8) {
                        print(str)
                    }
                } else {
                    print("ready")
                }
                return
            }
            let pause = ContinuousClock.now.duration(to: deadline).components
            let pauseSeconds = Double(pause.seconds) + Double(pause.attoseconds) / 1E18
            if pauseSeconds > 0 {
                Thread.sleep(forTimeInterval: min(interval, pauseSeconds))
            }
        }
        // Write to stderr and exit non-zero so login-time scripts can fail fast.
        // `CleanExit.message` would print to stdout and exit 0, breaking the
        // contract documented for this command.
        FileHandle.standardError.write(
            Data("Error: timed out waiting for CtrlX after \(timeout)s\n".utf8)
        )
        throw ExitCode.failure
    }
}

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "List available API methods"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "system.capabilities", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(methods) = result["methods"] {
            for method in methods {
                if case let .string(name) = method {
                    print(name)
                }
            }
        }
    }
}

struct IdentifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identify",
        abstract: "Show current context (session/window/pane)"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        // Pass TMUX_PANE if available for context detection
        if let tmuxPane = ProcessInfo.processInfo.environment["TMUX_PANE"] {
            params["pane_id"] = .string(tmuxPane)
        }
        let response = try executeRequest(method: "system.identify", params: params, options: options, timeoutSeconds: 5)
        printResponse(response, json: options.json)
    }
}
