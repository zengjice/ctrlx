import CtrlxCommon
import CtrlxNetworking
import Foundation
import OSLog

private let questionLogger = Logger(subsystem: "com.jicezeng.ctrlx", category: "CodexQuestions")

extension TmuxService {
    @discardableResult
    func recordCodexQuestion(paneID: String, questionID: String) -> Bool {
        guard
            paneID.hasPrefix("%"), Int(paneID.dropFirst()) != nil, !questionID.isEmpty,
            codexQuestionIDs[paneID] != questionID else { return false }
        codexQuestionIDs[paneID] = questionID
        codexQuestionStates.removeValue(forKey: paneID)
        questionLogger.notice("New question identity: pane=\(paneID, privacy: .public)")
        return true
    }

    /// Shared by the local Mac and remote viewers. Viewers send an intent, NOT
    /// an unconditional keypress: a delayed/stale screen cannot select text in
    /// the host's draft. Older hosts reject the unknown command safely.
    @discardableResult
    func expandCodexQuestions(paneID: String, expectedCount: Int, expectedQuestionID: String? = nil, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws -> Bool {
        func deferred(_ reason: String) -> Bool {
            questionLogger.notice("Question expansion deferred: pane=\(paneID, privacy: .public) count=\(expectedCount) reason=\(reason, privacy: .public)")
            return false
        }
        guard
            paneID.hasPrefix("%"), Int(paneID.dropFirst()) != nil,
            (0...999).contains(expectedCount)
        else { return deferred("invalid-request") }
        let questionID = codexQuestionIDs[paneID]
        if let expectedQuestionID, expectedQuestionID != questionID {
            return deferred("question-identity-changed")
        }
        guard !codexQuestionChecks.contains(paneID) else { return deferred("check-in-flight") }
        // Another viewer may have opened it already. Acknowledge that claim
        // even though the collapsed footer is no longer on screen.
        if (codexQuestionStates[paneID]?.count ?? 0) == expectedCount {
            questionLogger.notice("Question already handled: pane=\(paneID, privacy: .public) count=\(expectedCount)")
            return true
        }
        codexQuestionChecks.insert(paneID)
        defer { codexQuestionChecks.remove(paneID) }

        guard let screen = try await codexQuestionScreen(paneID: paneID)
        else { return deferred("screen-not-eligible") }
        guard screen.prompt.count == expectedCount else { return deferred("queue-changed") }
        guard screen.command == "codex" || Self.knownShells.contains(screen.command)
        else { return deferred("foreground-not-codex") }

        if screen.command != "codex" {
            // The telemetry shell wrapper can remain tmux's foreground command.
            // A printed footer alone is not proof that Codex is still running.
            guard
                let detected = await detectAgentPanesIfAvailable(
                    processNamesByPlugin: ["codex": ["codex"]], refreshSnapshot: true
                ), detected[paneID]?.pluginID == "codex" else { return deferred("codex-not-detected") }
            // Process inspection suspends; don't select a draft typed meanwhile.
            guard
                let current = try await codexQuestionScreen(paneID: paneID),
                current.command == screen.command || current.command == "codex",
                current.prompt == screen.prompt
            else { return deferred("screen-changed-during-check") }
        }
        try Task.checkCancellation()
        guard codexQuestionIDs[paneID] == questionID else { return deferred("question-changed-during-check") }

        var state = codexQuestionStates[paneID] ?? CodexQuestionExpansionState()
        let shouldOpen = state.observe(screen.prompt.count)
        // The in-flight guard serializes viewers. Commit the count only after
        // tmux accepts the key, so a failed send can be tried again.
        if shouldOpen {
            do {
                try await sendKeys(paneID, keys: "S-Left", expectedWorkspacePane: expectedWorkspacePane)
            } catch {
                questionLogger.notice("Question expansion failed: pane=\(paneID, privacy: .public) count=\(expectedCount) reason=send-key-failed")
                throw error
            }
            questionLogger.notice("Question opener sent: pane=\(paneID, privacy: .public) count=\(expectedCount)")
        }
        guard codexQuestionIDs[paneID] == questionID else { return deferred("question-changed-during-send") }
        codexQuestionStates[paneID] = screen.prompt.count == 0 ? nil : state
        return true
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
        guard
            fields.count == 4, fields[3] == "0",
            let column = Int(fields[1]), let row = Int(fields[2]),
            let prompt = CodexQuestionPrompt(lines: Array(lines.dropFirst()), cursorRow: row, cursorColumn: column)
        else { return nil }
        return (fields[0], prompt)
    }
}
