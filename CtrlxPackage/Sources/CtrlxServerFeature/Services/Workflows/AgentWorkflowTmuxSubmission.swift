import CtrlxNetworking
import Foundation

enum AgentWorkflowTmuxSubmission {
    static let rejection = "ctrlx-workflow-input-changed"

    static func commands(instance: AgentWorkflowInstance, file: URL, capture: AgentWorkflowTerminalCapture, submit: Bool = true) throws -> [[String]] {
        let command = capture.foregroundCommand
        guard
            capture.bracketedPaste != false, !capture.inCopyMode,
            !command.isEmpty, command.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }) else { throw AgentWorkflowError("Cannot safely verify the foreground Agent command or input mode.") }
        let buffer = "ctrlx-workflow-\(UUID().uuidString)"
        let conditions = [
            "#{==:#{pane_current_command},\(command)}", "#{==:#{pane_in_mode},0}",
            capture.bracketedPaste == nil ? "#{==:#{bracket_paste_flag},}" : "#{bracket_paste_flag}",
            "#{==:#{cursor_x},\(capture.cursorX)}", "#{==:#{cursor_y},\(capture.cursorY)}",
            "#{==:#{pane_width},\(capture.width)}", "#{==:#{pane_height},\(capture.height)}",
        ]
        let condition = conditions.dropFirst().reduce(conditions[0]) { "#{&&:\($0),\($1)}" }
        // tmux 3.6a cannot expose the mode, but paste-buffer -p uses its actual
        // value. Keep literal multi-line paste and Return in the guarded queue.
        var operations = [
            ["load-buffer", "-b", buffer, file.path],
            ["paste-buffer", "-p", "-r", "-d", "-b", buffer, "-t", instance.paneID],
        ]
        if submit {
            operations.append(["send-keys", "-t", instance.paneID, "Enter"])
        }
        let body = operations.map { $0.map(\.posixSingleQuoted).joined(separator: " ") }.joined(separator: " ; ")
        return [["if-shell", "-F", "-t", instance.paneID, condition, body, "display-message -p \(rejection)"]]
    }
}
