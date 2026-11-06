import CtrlxCommon
import CtrlxPluginProtocol
import Foundation

enum AgentHookTrustTmuxSubmission {
    static let rejection = "ctrlx-hook-input-changed"

    static func commands(_ action: AgentHookTrustAction, paneID: String, capture: AgentWorkflowTerminalCapture, provider: any AgentHookTrustProviding) throws -> [[String]] {
        let foreground = capture.foregroundCommand
        guard
            capture.bracketedPaste != false, !capture.inCopyMode,
            !foreground.isEmpty, foreground.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }) else { throw AgentHookTrustError("Cannot safely verify the foreground Agent's input mode.") }

        let input: [[String]]
        switch action {
        case .open:
            if capture.bracketedPaste == nil {
                // Older tmux adds delimiters according to the actual terminal
                // mode. Paste and Return stay in the same guarded command queue.
                let buffer = "ctrlx-hook-\(UUID().uuidString)"
                input = [
                    ["set-buffer", "-b", buffer, "--", "/hooks"],
                    ["paste-buffer", "-p", "-r", "-d", "-b", buffer, "-t", paneID],
                    ["send-keys", "-t", paneID, "Enter"],
                ]
            } else {
                let bytes = Data("\u{1b}[200~/hooks\u{1b}[201~\r".utf8)
                input = [["send-keys", "-t", paneID, "-H"] + bytes.map { String(format: "%02x", $0) }]
            }
        case .trustAll:
            guard provider.hookTrustPanel(lines: capture.plainLines) == .needsReview else {
                throw AgentHookTrustError("Codex's trust-all controls changed. Nothing was approved.")
            }
            input = [["send-keys", "-t", paneID, "-l", "--", "t"]]
        case .close:
            guard provider.hookTrustPanel(lines: capture.plainLines) != nil else {
                throw AgentHookTrustError("The hooks panel changed. Check the terminal.")
            }
            input = [["send-keys", "-t", paneID, "Escape"]]
        case let .press(key, expected):
            guard capture.plainLines == expected, provider.hookTrustAllows(key, lines: capture.plainLines) else {
                throw AgentHookTrustError("The hooks selection changed. Nothing was sent.")
            }
            input = [["send-keys", "-t", paneID, key.rawValue]]
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
