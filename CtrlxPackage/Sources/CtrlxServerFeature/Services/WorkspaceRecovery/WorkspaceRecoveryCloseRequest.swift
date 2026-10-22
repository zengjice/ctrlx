import CtrlxCommon
import CtrlxNetworking
import Foundation

/// Resolve the user's target before waiting for recovery. tmux checks that
/// physical identity in the same command queue which closes the object.
struct WorkspaceRecoveryCloseRequest: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case session
        case window
        case pane

        var identityKey: String {
            switch self {
            case .session: WorkspaceTmuxRecovery.sessionKey
            case .window: WorkspaceTmuxRecovery.windowKey
            case .pane: WorkspaceTmuxRecovery.paneKey
            }
        }

        var prefix: Character {
            switch self {
            case .session: "$"
            case .window: "@"
            case .pane: "%"
            }
        }

        var captureFormat: String {
            "#{pid}:#{start_time}\u{1f}#{\(rawValue)_id}\u{1f}#{\(identityKey)}"
        }
    }

    static let rejection = "ctrlx-workspace-close-target-changed"
    let kind: Kind
    let serverID: String
    let runtimeID: String
    let identity: UUID?

    init(kind: Kind, output: String, expected: WorkspacePaneIdentity? = nil) throws {
        let fields = output.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count == 3 else { throw WorkspaceRecoveryError("Cannot identify the terminal to close.") }
        let serverParts = fields[0].split(separator: ":", omittingEmptySubsequences: false)
        guard
            serverParts.count == 2, serverParts.allSatisfy({ UInt64($0) != nil }),
            fields[1].first == kind.prefix, UInt64(fields[1].dropFirst()) != nil,
            fields[2].isEmpty || UUID(uuidString: String(fields[2])) != nil else {
            throw WorkspaceRecoveryError("Invalid identity for the terminal to close.")
        }
        self.kind = kind
        self.serverID = String(fields[0])
        self.runtimeID = String(fields[1])
        self.identity = UUID(uuidString: String(fields[2]))
        if let expected {
            let expectedID: UUID = switch kind {
            case .session: expected.sessionID
            case .window: expected.windowID
            case .pane: expected.paneID
            }
            guard serverID == expected.serverID, identity == expectedID else {
                throw WorkspaceRecoveryError("The terminal changed while waiting to close. Select the restored terminal and try again.")
            }
        }
    }

    var arguments: [String] {
        var condition = "#{==:#{pid}:#{start_time},\(serverID)}"
        if let identity {
            condition = "#{&&:\(condition),#{==:#{\(kind.identityKey)},\(identity.uuidString)}}"
        }
        // A formerly unmanaged object may receive its recovery UUID while this
        // request waits. Read that UUID before killing the same physical object.
        let commands = [
            ["display-message", "-p", "-t", runtimeID, "#{\(kind.identityKey)}"],
            ["kill-\(kind.rawValue)", "-t", runtimeID],
        ].map { $0.map(\.posixSingleQuoted).joined(separator: " ") }.joined(separator: " ; ")
        return ["if-shell", "-F", "-t", runtimeID, condition, commands, "display-message -p \(Self.rejection)"]
    }

    func closedTarget(_ result: ProcessResult) throws -> WorkspaceRecoveryClosedTarget? {
        guard result.isSuccess else { throw TmuxError.commandFailed(message: result.stderrString) }
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output != Self.rejection else {
            throw WorkspaceRecoveryError("The terminal changed while waiting to close. Select the restored terminal and try again.")
        }
        guard !output.isEmpty else { return nil }
        guard let id = UUID(uuidString: output) else { throw WorkspaceRecoveryError("Cannot verify the closed terminal's identity.") }
        switch kind {
        case .session: return .session(id)
        case .window: return .window(id)
        case .pane: return .pane(id)
        }
    }
}
