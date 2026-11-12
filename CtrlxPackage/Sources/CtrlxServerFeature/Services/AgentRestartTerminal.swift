import CtrlxCommon
import CtrlxNetworking
import Foundation

@MainActor
enum AgentRestartTerminal {
    static let rejection = "ctrlx-agent-restart-target-changed"
    static let success = "ctrlx-agent-resumed"
    static let format = "#{pane_pid}\u{1f}#{pane_tty}\u{1f}#{pane_dead}\u{1f}#{pane_current_command}"

    static func process(loginShell: String, invocation: String, prefix: String?, shellCommand: String) -> [String] {
        // Let Bash's selected login profile own startup order and overrides.
        // Only fall back to .bashrc when no readable login profile exists.
        let startup = (loginShell as NSString).lastPathComponent == "bash"
            ? #"""
            if [ ! -r "$HOME/.bash_profile" ] &&
                [ ! -r "$HOME/.bash_login" ] &&
                [ ! -r "$HOME/.profile" ] && [ -r "$HOME/.bashrc" ]; then
                . "$HOME/.bashrc"
            fi

            """# : ""
        let line = prefix.map { "\($0); \(invocation)" } ?? invocation
        // Return to a shell even if Resume reports a CLI error, preserving this tab.
        return [loginShell, "-l", "-i", "-c", startup + line + "; exec /bin/sh -c " + shellCommand.posixSingleQuoted]
    }

    struct Snapshot: Sendable {
        let processID: String
        let tty: String
        let isDead: Bool
        let command: String
        let remainOnExit: String?

        init(output: String) throws {
            let lines = output.components(separatedBy: "\n")
            let fields = (lines.first ?? "").components(separatedBy: "\u{1f}")
            let value = lines.dropFirst().first(where: { !$0.isEmpty })?.components(separatedBy: " ").last
            guard
                fields.count == 4, Int32(fields[0]).map({ $0 > 1 }) == true,
                fields[1].hasPrefix("/dev/tty"), ["0", "1"].contains(fields[2]),
                value == nil || ["on", "off", "failed"].contains(value) else {
                throw AgentRestartError("The Agent terminal could not be inspected.")
            }
            self.processID = fields[0]
            self.tty = fields[1]
            self.isDead = fields[2] == "1"
            self.command = fields[3]
            self.remainOnExit = value
        }
    }

    static func restoreCommands(paneID: String, snapshot: Snapshot) -> [[String]] {
        if let value = snapshot.remainOnExit {
            [["set-option", "-p", "-t", paneID, "remain-on-exit", value]]
        } else {
            [["set-option", "-pu", "-t", paneID, "remain-on-exit"]]
        }
    }

    static func guardedCommands(paneID: String, snapshot: Snapshot, commands: [[String]]) -> [[String]] {
        let condition = "#{&&:#{==:#{pane_pid},\(snapshot.processID)},#{&&:#{==:#{pane_dead},\(snapshot.isDead ? 1 : 0)},#{==:#{pane_current_command},\(snapshot.command)}}}"
        let body = commands.map { $0.map(\.posixSingleQuoted).joined(separator: " ") }.joined(separator: " ; ")
        return [["if-shell", "-F", "-t", paneID, condition, body, "display-message -p \(rejection)"]]
    }

    static func launchCommands(paneID: String, original: Snapshot, ready: Snapshot, directory: String, process: [String], environment: [String], payload: String?) throws -> [[String]] {
        guard
            original.processID == ready.processID, original.tty == ready.tty,
            ready.isDead || TmuxService.knownShells.contains(ready.command),
            ready.command.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }) else {
            throw AgentRestartError("Another process is using this terminal. Check it before resuming manually.")
        }
        var commands: [[String]] = []
        if let payload {
            commands.append(["set-option", "-p", "-t", paneID, SessionLaunchPreparation.launchPayloadOption, payload])
        }
        commands.append(["respawn-pane", "-k", "-t", paneID, "-c", directory] + environment.flatMap { ["-e", $0] } + process)
        commands += restoreCommands(paneID: paneID, snapshot: original)
        commands.append(["display-message", "-p", success])
        return guardedCommands(paneID: paneID, snapshot: ready, commands: commands)
    }
}
