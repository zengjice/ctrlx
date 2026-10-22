import CtrlxCommon
import CtrlxNetworking
import Foundation

/// Captured by new-session/new-window themselves, before discovery assigns UUIDs.
struct TmuxCreatedPane: Sendable {
    static let format = "#{pid}:#{start_time}\u{1f}#{pane_id}"
    let serverID: String
    let paneID: String

    init(output: String) throws {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].first == "%", UInt64(parts[1].dropFirst()) != nil else {
            throw TmuxError.commandFailed(message: "Terminal created but could not identify it. Check its tab before retrying.")
        }
        self.serverID = String(parts[0])
        self.paneID = String(parts[1])
    }
}

/// Checked by tmux in the same command queue as the input. A separate metadata
/// query would leave a gap in which a restarted server can reuse the target ID.
enum WorkspaceTerminalInputGuard {
    enum Scope { case pane, window, session }
    static let rejection = "ctrlx-workspace-input-target-changed"

    static func arguments(target: String, identity: WorkspacePaneIdentity, scope: Scope = .pane, commands: [[String]]) throws -> [String] {
        let serverParts = identity.serverID.split(separator: ":", omittingEmptySubsequences: false)
        guard
            !target.isEmpty,
            scope != .pane || (target.first == "%" && UInt64(target.dropFirst()) != nil),
            serverParts.count == 2, serverParts.allSatisfy({ UInt64($0) != nil }) else {
            throw TmuxError.commandFailed(message: "Invalid workspace input target.")
        }
        let (key, id) = switch scope {
        case .pane: (WorkspaceTmuxRecovery.paneKey, identity.paneID)
        case .window: (WorkspaceTmuxRecovery.windowKey, identity.windowID)
        case .session: (WorkspaceTmuxRecovery.sessionKey, identity.sessionID)
        }
        let condition = "#{&&:#{==:#{pid}:#{start_time},\(identity.serverID)},#{==:#{\(key)},\(id.uuidString)}}"
        return arguments(target: target, condition: condition, commands: commands)
    }

    static func arguments(created: TmuxCreatedPane, commands: [[String]]) throws -> [String] {
        let serverParts = created.serverID.split(separator: ":", omittingEmptySubsequences: false)
        guard serverParts.count == 2, serverParts.allSatisfy({ UInt64($0) != nil }) else {
            throw TmuxError.commandFailed(message: "Invalid created terminal identity.")
        }
        return arguments(target: created.paneID, condition: "#{==:#{pid}:#{start_time},\(created.serverID)}", commands: commands)
    }

    private static func arguments(target: String, condition: String, commands: [[String]]) -> [String] {
        let body = commands.map { $0.map(\.posixSingleQuoted).joined(separator: " ") }.joined(separator: " ; ")
        return ["if-shell", "-F", "-t", target, condition, body, "display-message -p \(rejection)"]
    }

    static func validate(output: String) throws {
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) != rejection else {
            throw TmuxError.commandFailed(message: "The terminal changed before input arrived. Select the restored terminal and try again.")
        }
    }
}

extension TmuxService {
    func runCreatedPaneCommand(_ commands: [[String]], created: TmuxCreatedPane) async throws {
        let result = try await runTmuxCommand(WorkspaceTerminalInputGuard.arguments(created: created, commands: commands))
        guard result.isSuccess else { throw TmuxError.commandFailed(message: result.stderrString) }
        try WorkspaceTerminalInputGuard.validate(output: result.stdoutString)
    }

    func sendWorkspaceInput(_ commands: [[String]], target: String, identity: WorkspacePaneIdentity) async throws {
        _ = try await runWorkspaceCommand(commands, target: target, identity: identity)
    }

    func runWorkspaceCommand(_ commands: [[String]], target: String, identity: WorkspacePaneIdentity?, scope: WorkspaceTerminalInputGuard.Scope = .pane) async throws -> ProcessResult {
        let arguments: [String]
        if let identity {
            arguments = try WorkspaceTerminalInputGuard.arguments(target: target, identity: identity, scope: scope, commands: commands)
        } else {
            arguments = commands.enumerated().flatMap { ($0.offset == 0 ? [] : [";"]) + $0.element }
        }
        let result = try await runTmuxCommand(arguments)
        guard result.isSuccess else { throw TmuxError.commandFailed(message: result.stderrString) }
        try WorkspaceTerminalInputGuard.validate(output: result.stdoutString)
        return result
    }
}
