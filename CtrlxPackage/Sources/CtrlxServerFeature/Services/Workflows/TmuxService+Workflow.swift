import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

extension TmuxService {
    func captureWorkflowTerminal(_ instance: AgentWorkflowInstance) async throws -> AgentWorkflowTerminalCapture {
        let fields = ["pane_width", "pane_height", "cursor_x", "cursor_y", "cursor_flag", "bracket_paste_flag", "pane_in_mode", "pane_current_command"]
        let metadata = fields.map { "#{\($0)}" }.joined(separator: "\u{1f}")
        let result = try await runWorkspaceCommand([
            ["display-message", "-p", "-t", instance.paneID, metadata],
            ["capture-pane", "-p", "-e", "-N", "-t", instance.paneID],
        ], target: instance.paneID, identity: instance.workspacePane)
        let output = result.stdoutString
        guard let newline = output.firstIndex(of: "\n") else { throw AgentWorkflowError("The terminal snapshot is incomplete.") }
        let values = output[..<newline].components(separatedBy: "\u{1f}")
        guard
            values.count == 8,
            let width = Int(values[0]), let height = Int(values[1]), let x = Int(values[2]), let y = Int(values[3]),
            [values[4], values[5], values[6]].allSatisfy({ $0 == "0" || $0 == "1" }) else {
            throw AgentWorkflowError("Cannot inspect this tmux terminal's input mode.")
        }
        return .init(
            ansi: String(output[output.index(after: newline)...]), width: width, height: height, cursorX: x, cursorY: y,
            cursorVisible: values[4] == "1", bracketedPaste: values[5] == "1", inCopyMode: values[6] == "1", foregroundCommand: values[7]
        )
    }

    func submitWorkflowInput(
        _ instance: AgentWorkflowInstance, file: URL, composer: AgentWorkflowComposer,
        launch: @escaping @MainActor @Sendable (@Sendable () throws -> Void) throws -> Void
    ) async throws {
        let capture = try await captureWorkflowTerminal(instance)
        guard AgentWorkflowComposerInspection.readiness(capture, composer: composer) == .ready else {
            throw AgentWorkflowError("The terminal input changed before submission. Nothing was sent.")
        }
        let commands = try AgentWorkflowTmuxSubmission.commands(instance: instance, file: file, capture: capture)
        let result = try await runWorkspaceCommand(commands, target: instance.paneID, identity: instance.workspacePane, launch: launch)
        guard result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) != AgentWorkflowTmuxSubmission.rejection else {
            throw AgentWorkflowInputNotWritten(reason: "The foreground Agent or terminal input mode changed. Nothing was sent.")
        }
    }

    func runHumanTmuxInput(_ arguments: [String], target: String, editsInput: Bool = true) async throws -> ProcessResult {
        guard let workflowInputGate else { return try await runTmuxCommand(arguments) }
        let paneID: String
        if target.first == "%", UInt64(target.dropFirst()) != nil {
            paneID = target
        } else {
            paneID = try await captureWorkspacePane(target: target).info.paneId
        }
        return try await workflowInputGate.human(paneID: paneID, editsInput: editsInput) {
            try await self.runTmuxCommand(arguments)
        }
    }
}
