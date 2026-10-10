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

        guard let screen = try await codexQuestionScreen(paneID: paneID),
              screen.prompt.count == expectedCount,
              screen.command == "codex" || Self.knownShells.contains(screen.command),
              (codexQuestionStates[paneID]?.count ?? 0) != expectedCount
        else { return }

        if screen.command != "codex" {
            // The telemetry shell wrapper can remain tmux's foreground command.
            // A printed footer alone is not proof that Codex is still running.
            guard let detected = await detectAgentPanesIfAvailable(
                processNamesByPlugin: ["codex": ["codex"]], refreshSnapshot: true
            ), detected[paneID]?.pluginID == "codex" else { return }
            // Process inspection suspends; don't select a draft typed meanwhile.
            guard let current = try await codexQuestionScreen(paneID: paneID),
                  current.command == screen.command || current.command == "codex",
                  current.prompt == screen.prompt
            else { return }
        }
        try Task.checkCancellation()

        var state = codexQuestionStates[paneID] ?? CodexQuestionExpansionState()
        let shouldOpen = state.observe(screen.prompt.count)
        // Claim before the next suspension, including requests from other Macs.
        codexQuestionStates[paneID] = screen.prompt.count == 0 ? nil : state
        guard shouldOpen else { return }
        try await sendKeys(paneID, keys: "S-Left")
    }

    private func codexQuestionScreen(paneID: String) async throws -> (command: String, prompt: CodexQuestionPrompt)? {
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
        guard fields.count == 4, fields[3] == "0",
              let column = Int(fields[1]), let row = Int(fields[2]),
              let prompt = CodexQuestionPrompt(lines: Array(lines.dropFirst()), cursorRow: row, cursorColumn: column)
        else { return nil }
        return (fields[0], prompt)
    }
}
