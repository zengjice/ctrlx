import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

extension TmuxService {
    func captureWorkflowTerminal(_ instance: AgentWorkflowInstance) async throws -> AgentWorkflowTerminalCapture {
        try await captureAgentTerminal(paneID: instance.paneID, identity: instance.workspacePane)
    }

    func captureAgentTerminal(paneID: String, identity: WorkspacePaneIdentity) async throws -> AgentWorkflowTerminalCapture {
        let fields = ["pane_width", "pane_height", "cursor_x", "cursor_y", "cursor_flag", "bracket_paste_flag", "pane_in_mode", "pane_current_command"]
        let metadata = fields.map { "#{\($0)}" }.joined(separator: "\u{1f}")
        let result = try await runWorkspaceCommand([
            ["display-message", "-p", "-t", paneID, metadata],
            ["capture-pane", "-p", "-e", "-N", "-t", paneID],
        ], target: paneID, identity: identity)
        return try AgentWorkflowTerminalCapture.parse(result.stdoutString)
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
