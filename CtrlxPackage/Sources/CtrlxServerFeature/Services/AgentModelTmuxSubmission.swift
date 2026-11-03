import CtrlxCommon
import CtrlxPluginProtocol
import Foundation

enum AgentModelTmuxSubmission {
    static let rejection = "ctrlx-model-input-changed"

    static func commands(_ command: String, paneID: String, capture: AgentWorkflowTerminalCapture) throws -> [[String]] {
        let bytes = try AgentModelTerminal.commandBytes(command)
        let foreground = capture.foregroundCommand
        guard
            capture.bracketedPaste != false, !foreground.isEmpty, foreground.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }) else { throw AgentModelError("Cannot safely verify the foreground Agent's input mode.") }

        let input: [[String]]
        if capture.bracketedPaste == nil {
            // tmux 3.6a cannot expose bracket_paste_flag, but paste-buffer -p
            // already checks the actual mode before adding paste delimiters.
            // Keep the single-line paste and Return in one guarded command queue.
            let buffer = "ctrlx-model-\(UUID().uuidString)"
            input = [
                ["set-buffer", "-b", buffer, "--", command],
                ["paste-buffer", "-p", "-r", "-d", "-b", buffer, "-t", paneID],
                ["send-keys", "-t", paneID, "Enter"],
            ]
        } else {
            input = [["send-keys", "-t", paneID, "-H"] + bytes.map { String(format: "%02x", $0) }]
        }
        let conditions = [
            capture.bracketedPaste == nil ? "#{==:#{bracket_paste_flag},}" : "#{bracket_paste_flag}",
            "#{==:#{pane_current_command},\(foreground)}", "#{==:#{pane_in_mode},0}",
            "#{==:#{cursor_x},\(capture.cursorX)}", "#{==:#{cursor_y},\(capture.cursorY)}",
            "#{==:#{pane_width},\(capture.width)}", "#{==:#{pane_height},\(capture.height)}",
        ]
        let condition = conditions.dropFirst().reduce(conditions[0]) { "#{&&:\($0),\($1)}" }
        let body = input.map { $0.map(\.posixSingleQuoted).joined(separator: " ") }.joined(separator: " ; ")
        return [["if-shell", "-F", "-t", paneID, condition, body, "display-message -p \(rejection)"]]
    }
}
