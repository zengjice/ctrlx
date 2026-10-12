import CtrlxCommon
import CtrlxNetworking
import Foundation
import Logging

/// Executes commands received from viewers via the relay server.
///
/// Translates `CommandMessage` objects into tmux operations using `TmuxService`.
public actor TmuxCommandExecutor {
    // MARK: - Properties

    private let logger = Logger(label: "com.jicezeng.ctrlx.commandexecutor")
    private let tmuxService: TmuxService
    private let sendRawInputIfConnected: @Sendable (String, Data) async throws -> Bool

    // MARK: - Initialization

    public init(
        tmuxService: TmuxService,
        sendRawInputIfConnected: @escaping @Sendable (String, Data) async throws -> Bool = { _, _ in false }
    ) {
        self.tmuxService = tmuxService
        self.sendRawInputIfConnected = sendRawInputIfConnected
    }

    // MARK: - Command Execution

    /// Execute a command received from viewer
    /// - Parameter command: The command to execute
    /// - Returns: Response indicating success or failure
    public func execute(_ command: CommandMessage) async -> CommandResponseMessage {
        let logType = if case .pasteTerminalText = command.command { "pasteTerminalText" }
            else { String(describing: command.command) }
        logger.info("Executing command", metadata: [
            "command": "\(logType)",
            "paneId": "\(command.paneId)",
        ])

        do {
            switch command.command {
            case let .sendKeystroke(spec):
                try await executeSendKeystroke(paneId: command.paneId, keys: spec.keystrokes)

            case let .pasteTerminalText(spec):
                guard spec.text.utf8.count <= PasteTerminalText.maximumUTF8Bytes else {
                    throw CommandError.invalidPayload("Clipboard text exceeds 64 KiB")
                }
                guard !spec.text.contains(DroppedPathFormatter.bracketedPasteEnd) else {
                    throw CommandError.invalidPayload("Clipboard text contains a paste-end control sequence")
                }
                guard !spec.text.isEmpty else { return .success(for: command.id) }
                try await tmuxService.loadAndPasteBuffer(
                    target: command.paneId,
                    content: spec.text,
                    bufferName: "ctrlx-paste-\(command.id.uuidString)",
                    preserveLineFeeds: true
                )

            case let .expandCodexQuestions(spec):
                try await tmuxService.expandCodexQuestions(paneID: command.paneId, expectedCount: spec.expectedCount)

            case let .sendRawInput(spec):
                guard let data = spec.data, !data.isEmpty else {
                    throw CommandError.invalidPayload("Invalid base64 data in sendRawInput")
                }
                // The viewer's FIFO remains the owner of ordering. Fall back
                // only when no control-mode bytes were written, never on error.
                let started = ContinuousClock.now
                defer { TerminalTransportMetrics.shared.recordDuration(.rawInputSend, since: started) }
                if try await !sendRawInputIfConnected(command.paneId, data) {
                    try await tmuxService.sendRawBytes(command.paneId, data: data)
                }

            case .cancelOperation:
                try await tmuxService.sendInterrupt(command.paneId)

            case let .resizeTmuxPane(spec):
                // A tmux window has one global grid. Only a direct user action
                // may change it; legacy automatic requests omit this marker.
                guard spec.userInitiated == true else {
                    return .failure(
                        for: command.id,
                        error: "Terminal resize requires explicit user action"
                    )
                }
                try await tmuxService.fitWindow(
                    command.paneId,
                    width: spec.width,
                    height: spec.height
                )

            case let .splitTmuxPane(spec):
                let newPaneId = try await tmuxService.splitPane(
                    command.paneId,
                    horizontal: spec.direction == .horizontal
                )
                return .success(for: command.id, paneId: newPaneId)

            case .selectTmuxPane:
                try await tmuxService.selectPane(command.paneId)

            case .selectTmuxWindow:
                try await tmuxService.selectWindow(command.paneId)

            case .startTerminalStream,
                 .listSessionDirectories,
                 .createSessionDirectory,
                 .browseFiles,
                 .browseBrowser,
                 .stopTerminalStream,
                 .createTmuxSession,
                 .createTmuxWindow,
                 .prepareAgentFork,
                 .forkAgentSession,
                 .setSharedTerminalLayout,
                 .setYoloMode,
                 .markHandled,
                 .renameTmuxSession,
                 .setSessionDescription,
                 .setSessionColor,
                 .setSessionEmoji,
                 .setSessionState,
                 .setWindowName,
                 .moveTmuxWindows,
                 .submitEditorContent,
                 .cancelEditorSession,
                 .checkRunningProcesses,
                 .killTmuxWindow,
                 .killTmuxSession,
                 .sendDroppedFiles:
                // These commands are handled by AppCoordinator, should not reach here
                logger.warning("Command should be handled by AppCoordinator, not executor")
            }

            logger.info("Command executed successfully", metadata: ["commandId": "\(command.id)"])
            return .success(for: command.id)

        } catch {
            logger.error("Command execution failed", metadata: [
                "commandId": "\(command.id)",
                "error": "\(error)",
            ])
            return .failure(for: command.id, error: error.localizedDescription)
        }
    }

    // MARK: - Private Command Handlers

    private func executeSendKeystroke(paneId: String, keys: [TmuxKey]) async throws {
        // Batch consecutive keys by literal mode to minimize tmux process
        // spawns; the shared implementation lives on TmuxService so the plugin
        // `sendKeys` sink can reuse it.
        try await tmuxService.sendKeystrokes(paneId, keys: keys)
    }
}

// MARK: - Command Errors

enum CommandError: LocalizedError {
    case invalidPayload(String)
    case paneNotFound(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPayload(message):
            "Invalid command payload: \(message)"
        case let .paneNotFound(paneId):
            "Pane not found: \(paneId)"
        case let .executionFailed(message):
            "Command execution failed: \(message)"
        }
    }
}
