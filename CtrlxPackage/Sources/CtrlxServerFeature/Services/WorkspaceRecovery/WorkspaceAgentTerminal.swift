import CtrlxCommon
import Foundation

/// The guard and launch run in one tmux command queue. No living process may be
/// replaced, including when inspection and launch straddle another client action.
enum WorkspaceAgentTerminal {
    static let inspectionFormat = ["#{\(WorkspaceTmuxRecovery.paneKey)}", "#{pane_dead}", "#{\(WorkspaceTmuxRecovery.agentPendingKey)}", "#{\(WorkspaceTmuxRecovery.agentLaunchKey)}"].joined(separator: "\u{1f}")

    static func parse(_ result: ProcessResult) throws -> WorkspaceRecoveryAgentPane {
        let values = result.stdoutString.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard result.isSuccess, values.count == 4, let identity = UUID(uuidString: values[0]) else {
            throw WorkspaceRecoveryError("The recovery terminal is unavailable.")
        }
        return .init(
            identity: identity,
            isDead: values[1] == "1",
            isPlaceholder: UUID(uuidString: values[2]) == identity,
            launchID: UUID(uuidString: values[3]),
            source: nil
        )
    }

    static func launchArguments(runtimeID: String, pane: WorkspaceRecoveryPane, record: WorkspaceRecoveryAgentLaunch, process: [String], environment: [String]) -> [String] {
        let identity = pane.id.uuidString
        let condition = "#{&&:#{==:#{pid}:#{start_time},\(record.serverID)},#{&&:#{==:#{\(WorkspaceTmuxRecovery.paneKey)},\(identity)},#{&&:#{==:#{\(WorkspaceTmuxRecovery.agentPendingKey)},\(identity)},#{pane_dead}}}}"
        var commands = [
            ["set-option", "-p", "-t", runtimeID, WorkspaceTmuxRecovery.agentLaunchKey, record.id.uuidString],
            ["respawn-pane", "-t", runtimeID, "-c", pane.directory] + environment.flatMap { ["-e", $0] } + process,
        ]
        if record.kind == .shell {
            commands.append(["set-option", "-p", "-u", "-t", runtimeID, "remain-on-exit"])
        }
        commands.append(["display-message", "-p", record.id.uuidString])
        let body = commands.map { $0.map(\.posixSingleQuoted).joined(separator: " ") }.joined(separator: " ; ")
        return ["if-shell", "-F", "-t", runtimeID, condition, body, "display-message -p recovery-target-changed"]
    }

    static func verifyLaunch(_ result: ProcessResult, record: WorkspaceRecoveryAgentLaunch) throws {
        guard result.isSuccess, result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == record.id.uuidString else {
            throw WorkspaceRecoveryError(result.isSuccess ? "The recovery terminal changed before launch. Its current process was kept." : result.stderrString)
        }
    }
}
