import CtrlxCommon
import CtrlxNetworking
import Foundation

extension TmuxService {
    /// Shared by the local Mac and remote viewers. Viewers send an intent, NOT
    /// an unconditional keypress: a delayed/stale screen cannot select text in
    /// the host's draft. Older hosts reject the unknown command safely.
    func expandCodexQuestions(paneID: String, expectedCount: Int) async throws {
        guard paneID.hasPrefix("%"), Int(paneID.dropFirst()) != nil,
              (0...999).contains(expectedCount),
              !codexQuestionChecks.contains(paneID)
        else { return }
        codexQuestionChecks.insert(paneID)
        defer { codexQuestionChecks.remove(paneID) }

        // Get cursor, foreground command, copy-mode and screen in one tmux
        // invocation. capture-pane does not include history without -S.
        let result = try await runTmuxCommand([
            "display-message", "-p", "-t", paneID,
            "#{pane_current_command}\t#{cursor_x}\t#{cursor_y}\t#{pane_in_mode}",
            ";", "capture-pane", "-p", "-t", paneID,
        ])
        guard result.isSuccess else { throw TmuxError.commandFailed(message: result.stderrString) }
        let lines = result.stdoutString.components(separatedBy: "\n")
        let fields = lines.first?.components(separatedBy: "\t") ?? []
        guard fields.count == 4, fields[0] == "codex", fields[3] == "0",
              let column = Int(fields[1]), let row = Int(fields[2]),
              let prompt = CodexQuestionPrompt(lines: Array(lines.dropFirst()), cursorRow: row, cursorColumn: column),
              prompt.count == expectedCount
        else { return }

        var state = codexQuestionStates[paneID] ?? CodexQuestionExpansionState()
        let shouldOpen = state.observe(prompt.count)
        // Claim before the next suspension, including requests from other Macs.
        codexQuestionStates[paneID] = prompt.count == 0 ? nil : state
        guard shouldOpen else { return }
        try await sendKeys(paneID, keys: "S-Left")
    }
}
