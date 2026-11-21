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

    private struct TerminalTab: Sendable {
        let windowID: String
        let sessionRuntimeID: String
        let sessionID: UUID?
    }

    static let rejection = "ctrlx-workspace-close-target-changed"
    static let scopeChanged = WorkspaceRecoveryError("The session changed while waiting to close. Review its tabs and confirm again.")
    static let terminalTabContextFormat = "\u{1f}#{session_id}\u{1f}#{window_id}\u{1f}#{\(WorkspaceTmuxRecovery.sessionKey)}"
    let kind: Kind
    let serverID: String
    let runtimeID: String
    let identity: UUID?
    private let terminalTab: TerminalTab?
    var resourceSessionID: UUID? {
        terminalTab?.sessionID
    }

    init(kind: Kind, output: String, expected: WorkspacePaneIdentity? = nil, tabWindowID: String? = nil) throws {
        let fields = output.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count == (tabWindowID == nil ? 3 : 6) else { throw WorkspaceRecoveryError("Cannot identify the terminal to close.") }
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
        if let tabWindowID {
            let sessionID = UUID(uuidString: String(fields[5]))
            guard
                kind != .pane,
                let sessionNumber = UInt64(fields[3].dropFirst()), fields[3] == "$\(sessionNumber)",
                let windowNumber = UInt64(fields[4].dropFirst()), tabWindowID == "@\(windowNumber)", fields[4] == tabWindowID,
                expected == nil || sessionID == expected?.sessionID else {
                throw Self.scopeChanged
            }
            self.terminalTab = TerminalTab(windowID: tabWindowID, sessionRuntimeID: String(fields[3]), sessionID: sessionID)
        } else {
            self.terminalTab = nil
        }
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

    func arguments(keepingResourceSession: Bool = false) -> [String] {
        var target = runtimeID
        var condition = "#{==:#{pid}:#{start_time},\(serverID)}"
        if let identity {
            condition = "#{&&:\(condition),#{==:#{\(kind.identityKey)},\(identity.uuidString)}}"
        }
        if let terminalTab {
            target = "\(terminalTab.sessionRuntimeID):\(terminalTab.windowID)"
            // tmux can resolve a missing window in a target to the session's current window.
            let sameTab = "#{&&:#{==:#{session_id},\(terminalTab.sessionRuntimeID)},#{==:#{window_id},\(terminalTab.windowID)}}"
            // Several links in the same session can point to one physical window.
            let otherWindows = "#{W:#{?#{!=:#{window_id},\(terminalTab.windowID)},1,}}"
            let onlyTargetWindow = "#{==:\(otherWindows),}"
            let scope: String
            if kind == .session {
                scope = onlyTargetWindow
            } else {
                // kill-window removes every link to the target, even in other sessions.
                let endsSession = keepingResourceSession ? "#{&&:\(onlyTargetWindow),#{!=:#{session_id},\(terminalTab.sessionRuntimeID)}}" : onlyTargetWindow
                scope = "#{==:#{S:#{?\(endsSession),1,}},}"
            }
            condition = "#{&&:\(condition),#{&&:\(sameTab),\(scope)}}"
        }
        // A formerly unmanaged object may receive its recovery UUID while this
        // request waits. Read that UUID before killing the same physical object.
        let commands = [
            ["display-message", "-p", "-t", runtimeID, "#{\(kind.identityKey)}"],
            ["kill-\(kind.rawValue)", "-t", runtimeID],
        ].map { $0.map(\.posixSingleQuoted).joined(separator: " ") }.joined(separator: " ; ")
        return ["if-shell", "-F", "-t", target, condition, commands, "display-message -p \(Self.rejection)"]
    }

    func closedTarget(_ result: ProcessResult) throws -> WorkspaceRecoveryClosedTarget? {
        guard result.isSuccess else { throw TmuxError.commandFailed(message: result.stderrString) }
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output != Self.rejection else {
            if terminalTab != nil {
                throw Self.scopeChanged
            }
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
