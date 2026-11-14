import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

extension TmuxService {
    func captureWorkflowTerminal(_ instance: AgentWorkflowInstance, composer: AgentWorkflowComposer) async throws -> AgentWorkflowTerminalCapture {
        try await AgentWorkflowComposerInspection.settledCapture(composer: composer) {
            try await self.captureAgentTerminal(paneID: instance.paneID, identity: instance.workspacePane)
        }
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
        _ instance: AgentWorkflowInstance, file: URL, images: [URL] = [], composer: AgentWorkflowComposer,
        imagesReady: @escaping @MainActor @Sendable ([Int]) async throws -> Void,
        launch: @escaping @MainActor @Sendable (@Sendable () throws -> Void) throws -> Void
    ) async throws {
        var capture = try await captureWorkflowTerminal(instance, composer: composer)
        guard AgentWorkflowComposerInspection.readiness(capture, composer: composer) == .ready else {
            throw AgentWorkflowError("The terminal input changed before submission. Nothing was sent.")
        }
        var imageNumbers: [Int] = []
        for (index, image) in images.enumerated() {
            let commands = try AgentWorkflowTmuxSubmission.commands(instance: instance, file: image, capture: capture, submit: false)
            let result = try await runWorkspaceCommand(commands, target: instance.paneID, identity: instance.workspacePane, launch: launch)
            guard result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) != AgentWorkflowTmuxSubmission.rejection else {
                throw AgentWorkflowError("The terminal changed while preparing images. Check the draft before continuing.")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
                capture = try await captureAgentTerminal(paneID: instance.paneID, identity: instance.workspacePane)
                if let numbers = AgentWorkflowComposerInspection.imageNumbers(capture, composer: composer), numbers.count == index + 1, numbers.starts(with: imageNumbers) {
                    imageNumbers = numbers
                    break
                }
                guard ContinuousClock.now < deadline else {
                    throw AgentWorkflowError("The Agent did not confirm its image attachments. Check the draft; nothing will be resent.")
                }
            } while true
        }
        if !images.isEmpty {
            try await imagesReady(imageNumbers)
        }
        let commands = try AgentWorkflowTmuxSubmission.commands(instance: instance, file: file, capture: capture)
        let result = try await runWorkspaceCommand(commands, target: instance.paneID, identity: instance.workspacePane, launch: launch)
        guard result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) != AgentWorkflowTmuxSubmission.rejection else {
            throw AgentWorkflowInputNotWritten(reason: "The foreground Agent or terminal input mode changed. Nothing was sent.")
        }
    }

    func runHumanTmuxInput(_ arguments: [String], target: String, editsInput: Bool = true, launch: (@MainActor @Sendable (@Sendable () throws -> Void) throws -> Void)? = nil) async throws -> ProcessResult {
        guard let workflowInputGate else { return try await runTmuxCommand(arguments, launch: launch) }
        let paneID: String
        if target.first == "%", UInt64(target.dropFirst()) != nil {
            paneID = target
        } else {
            paneID = try await captureWorkspacePane(target: target).info.paneId
        }
        return try await workflowInputGate.human(paneID: paneID, editsInput: editsInput) {
            try await self.runTmuxCommand(arguments, launch: launch)
        }
    }
}
