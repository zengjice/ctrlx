import CtrlxCommon
import Foundation
import Logging

/// Response from a control mode command
struct CommandResponse: Sendable {
    let commandNumber: Int
    let output: String
    let isError: Bool

    var lines: [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// One decoded `%output <pane-id> <value>` control-mode notification.
struct TmuxControlOutput: Equatable, Sendable {
    let paneId: String
    let data: Data
}

/// Byte-level decoder for tmux control-mode output notifications.
///
/// tmux keeps the protocol line-oriented by encoding every non-printable byte
/// and literal backslash as exactly three octal digits. Decoding bytes rather
/// than a Swift `String` preserves UTF-8 sequences without depending on read or
/// scalar boundaries.
enum TmuxControlOutputDecoder {
    private static let prefix = Data("%output ".utf8)

    static func decode(_ line: Data) -> TmuxControlOutput? {
        guard line.starts(with: prefix) else { return nil }
        let remainder = line.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: 0x20) else { return nil }
        let paneBytes = remainder[..<separator]
        guard let paneId = String(bytes: paneBytes, encoding: .utf8), !paneId.isEmpty else {
            return nil
        }
        let encoded = remainder[remainder.index(after: separator)...]
        return TmuxControlOutput(paneId: paneId, data: decodeOctalEscapes(encoded))
    }

    private static func decodeOctalEscapes(_ encoded: Data.SubSequence) -> Data {
        var decoded = Data()
        decoded.reserveCapacity(encoded.count)
        var index = encoded.startIndex

        while index < encoded.endIndex {
            guard encoded[index] == 0x5C else { // "\\"
                decoded.append(encoded[index])
                index = encoded.index(after: index)
                continue
            }

            let first = encoded.index(after: index)
            guard first < encoded.endIndex else {
                decoded.append(encoded[index])
                break
            }
            let second = encoded.index(after: first)
            let third = second < encoded.endIndex ? encoded.index(after: second) : encoded.endIndex
            guard
                second < encoded.endIndex,
                third < encoded.endIndex,
                isOctal(encoded[first]),
                isOctal(encoded[second]),
                isOctal(encoded[third])
            else {
                decoded.append(encoded[index])
                index = first
                continue
            }

            let byte = (encoded[first] - 0x30) * 64
                + (encoded[second] - 0x30) * 8
                + (encoded[third] - 0x30)
            decoded.append(byte)
            index = encoded.index(after: third)
        }

        return decoded
    }

    private static func isOctal(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x37
    }
}

/// Errors that can occur with the tmux control client
enum TmuxControlError: Error, LocalizedError {
    case notConnected
    case alreadyConnected
    case connectionFailed(message: String)
    case processTerminated(reason: String?)
    case commandFailed(message: String)
    case invalidResponse(message: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to tmux control mode"
        case .alreadyConnected:
            return "Already connected to tmux control mode"
        case let .connectionFailed(message):
            return "Failed to connect to tmux: \(message)"
        case let .processTerminated(reason):
            return "tmux control mode terminated: \(reason ?? "unknown reason")"
        case let .commandFailed(message):
            return "Command failed: \(message)"
        case let .invalidResponse(message):
            return "Invalid response from tmux: \(message)"
        case .timeout:
            return "Command timed out"
        }
    }
}

/// Manages one ordered tmux control-mode connection for commands, notifications,
/// and live pane output. Keeping `capture-pane` responses and `%output` on this
/// single parser gives terminal bootstraps an exact snapshot boundary.
actor TmuxControlClient {
    /// A control-mode client has no TTY, so GUI launches commonly inherit no
    /// `TERM` (or `dumb`). tmux exposes that value as `client_termname`, which
    /// terminal apps such as Codex inspect even when the pane itself has a valid
    /// `TERM`. Advertise the renderer's xterm-compatible capabilities without
    /// overwriting a real terminal supplied by a development launch.
    static func controlClientEnvironment(
        inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited
        let term = environment["TERM"] ?? ""
        if term.isEmpty || term.caseInsensitiveCompare("dumb") == .orderedSame {
            environment["TERM"] = "xterm-256color"
        }
        return environment
    }

    private let tmuxPath: String
    private let socketPath: String?
    private let logger = Logger(label: "com.jicezeng.ctrlx.tmuxcontrol")

    // Connection state
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutPipe: Pipe?
    private var processGeneration: UInt64 = 0

    /// Process termination must finish inside AppKit's shutdown deadline. Normal
    /// tmux control clients exit immediately; these bounds only cover a wedged
    /// child and never apply to the tmux server or a pane process.
    private static let gracefulTerminationTimeout = Duration.seconds(1)
    private static let forcedTerminationTimeout = Duration.seconds(1)
    private static let terminationPollInterval = Duration.milliseconds(20)

    // Cached dimensions for change detection
    private var cachedDimensions: [String: (width: Int, height: Int)] = [:]

    // Callbacks for notifications
    private var _onDimensionChange: (@Sendable (String, Int, Int) -> Void)?
    private var _onPaneExited: (@Sendable (String) -> Void)?
    private var _onLayoutChange: (@Sendable () -> Void)?
    private var _onSessionChanged: (@Sendable (String, String) -> Void)?
    private var _onExit: (@Sendable (String?) -> Void)?
    private var _onOutput: (@MainActor @Sendable (String, Data) -> Void)?
    private var outputEnabledPaneIds: Set<String> = []
    private var outputFramers: [String: TerminalOutputTokenFramer] = [:]
    private var outputSanitizers: [String: TerminalOutputSanitizer] = [:]

    // FIFO queue of pending command continuations, in the order commands were written to stdin.
    // tmux processes commands in FIFO order, so the front of this queue always corresponds
    // to the next %begin/%end response from tmux for a CLIENT command.
    //
    // A command list is one queue entry with one response per command. tmux
    // skips the rest of that list after an error, which also completes the entry.
    private struct PendingCommand {
        let id: Int
        let responseCount: Int
        var responses: [CommandResponse] = []
        var continuation: CheckedContinuation<[CommandResponse], any Error>?
        let onResponse: (@MainActor @Sendable (CommandResponse) -> Void)?
    }

    private var pendingCommandQueue: [PendingCommand] = []
    private var commandCounter = 0

    // Current command being accumulated (for %begin/%end blocks)
    private var currentCommandNumber: Int?
    private var currentCommandOutput: [String] = []
    private var currentCommandIsError = false

    // The first %begin/%end after connecting is tmux's response to the `attach` command
    // itself (not a command we sent). We track this to skip the entire block.
    private var skippingInitialBlock = false
    private var receivedInitialResponse = false

    // AsyncStream for ordered data processing from readabilityHandler.
    // Same pattern as PipePaneReader: yield from dispatch queue, consume in single task.
    private var dataContinuation: AsyncStream<Data>.Continuation?
    private var consumerTask: Task<Void, Never>?

    // Byte buffer for incomplete lines (handles chunk splitting at line boundaries)
    private var byteBuffer = Data()

    var isConnected: Bool {
        process?.isRunning == true
    }

    init(tmuxPath: String = "/opt/homebrew/bin/tmux", socketPath: String? = nil) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath
    }

    // MARK: - Callback Setters

    func setOnDimensionChange(_ handler: @escaping @Sendable (String, Int, Int) -> Void) {
        _onDimensionChange = handler
    }

    func setOnPaneExited(_ handler: @escaping @Sendable (String) -> Void) {
        _onPaneExited = handler
    }

    func setOnLayoutChange(_ handler: @escaping @Sendable () -> Void) {
        _onLayoutChange = handler
    }

    func setOnSessionChanged(_ handler: @escaping @Sendable (String, String) -> Void) {
        _onSessionChanged = handler
    }

    func setOnExit(_ handler: @escaping @Sendable (String?) -> Void) {
        _onExit = handler
    }

    func setOnOutput(_ handler: @escaping @MainActor @Sendable (String, Data) -> Void) {
        _onOutput = handler
    }

    func setPaneOutputEnabled(paneId: String, enabled: Bool) {
        if enabled {
            if outputEnabledPaneIds.insert(paneId).inserted {
                outputSanitizers[paneId] = TerminalOutputSanitizer()
            }
        } else {
            outputEnabledPaneIds.remove(paneId)
            outputSanitizers.removeValue(forKey: paneId)
        }
    }

    // MARK: - Connection Management

    /// Connects to tmux in control mode. `ignore-size` prevents this invisible
    /// client from affecting pane geometry; output remains enabled so snapshots
    /// and live bytes share one protocol stream.
    func connect(sessionTarget: String) async throws {
        guard process == nil else {
            throw TmuxControlError.alreadyConnected
        }

        logger.info("Connecting to tmux control mode", metadata: [
            "session": "\(sessionTarget)",
        ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)

        processGeneration &+= 1
        let generation = processGeneration

        var arguments = ["-C", "-f", "ignore-size", "attach", "-t", sessionTarget]
        if let socketPath, !socketPath.isEmpty {
            arguments = ["-S", socketPath] + arguments
        }
        process.arguments = arguments
        process.environment = Self.controlClientEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set up termination handler
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleProcessTermination(
                    generation: generation,
                    exitCode: proc.terminationStatus
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw TmuxControlError.connectionFailed(message: error.localizedDescription)
        }

        self.process = process
        stdin = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe

        // Start reading output via AsyncStream for ordered processing.
        // readabilityHandler fires on a dispatch queue — yielding into the stream
        // is synchronous and non-blocking. A single consumer task drains the stream
        // in order, preventing reordering of control messages.
        let handle = stdoutPipe.fileHandleForReading
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        dataContinuation = continuation

        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            continuation.yield(data)
        }

        consumerTask = Task { [weak self] in
            for await data in stream {
                await self?.processIncomingData(data)
            }
        }

        logger.info("Connected to tmux control mode")
    }

    /// Disconnects from tmux control mode
    func disconnect() async {
        logger.info("Disconnecting from tmux control mode")

        let processToStop = process
        let generationToStop = processGeneration

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        dataContinuation?.finish()
        dataContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil

        // Pending commands may already have executed. `notConnected` is reserved
        // for the pre-write guard; returning it here would allow input callers
        // to replay the same bytes through their process fallback.
        for entry in pendingCommandQueue {
            entry.continuation?.resume(throwing: TmuxControlError.processTerminated(reason: "Disconnected with command pending"))
        }
        pendingCommandQueue.removeAll()
        receivedInitialResponse = false
        skippingInitialBlock = false

        // Closing our write end prevents a control client waiting on stdin from
        // surviving App shutdown. Do this before SIGTERM and keep the exact
        // Process object alive until it has actually exited.
        let inputToClose = stdin
        stdin = nil
        try? inputToClose?.close()

        if let processToStop, processToStop.isRunning {
            processToStop.terminate()
            if !(await waitForTermination(
                of: processToStop,
                timeout: Self.gracefulTerminationTimeout
            )) {
                let pid = processToStop.processIdentifier
                logger.warning("tmux control client ignored SIGTERM; sending SIGKILL", metadata: [
                    "pid": "\(pid)",
                ])
                if processToStop.isRunning, kill(pid, SIGKILL) != 0, errno != ESRCH {
                    logger.error("Failed to SIGKILL tmux control client", metadata: [
                        "pid": "\(pid)",
                        "errno": "\(errno)",
                    ])
                }
                if !(await waitForTermination(
                    of: processToStop,
                    timeout: Self.forcedTerminationTimeout
                )) {
                    logger.error("tmux control client remained alive after SIGKILL", metadata: [
                        "pid": "\(pid)",
                    ])
                }
            }
        }

        // An exit handler may have run while this actor was suspended. Never
        // let cleanup for an old generation erase a newer connection.
        if processGeneration == generationToStop {
            stdoutPipe = nil
            process = nil
            cachedDimensions.removeAll()
            byteBuffer.removeAll()
            outputFramers.removeAll()
            outputSanitizers.removeAll()
        }
    }

    private func waitForTermination(of process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.terminationPollInterval)
        }
        return !process.isRunning
    }

    // MARK: - Dimension Tracking

    /// Registers initial dimensions for a pane so layout-change events can detect changes.
    func registerPaneDimensions(paneId: String, width: Int, height: Int) {
        cachedDimensions[paneId] = (width, height)
        logger.debug("Registered pane dimensions", metadata: ["paneId": "\(paneId)"])
    }

    /// Unregisters a pane from dimension tracking.
    func unregisterPane(paneId: String) {
        cachedDimensions.removeValue(forKey: paneId)
        outputFramers.removeValue(forKey: paneId)
        outputSanitizers.removeValue(forKey: paneId)
        logger.debug("Unregistered pane", metadata: ["paneId": "\(paneId)"])
    }

    // MARK: - Command Execution

    /// Sends a command to tmux and waits for the response
    func sendCommand(
        _ command: String,
        timeout: TimeInterval = 5,
        onWritten: (@Sendable () -> Void)? = nil,
        onResponse: (@MainActor @Sendable (CommandResponse) -> Void)? = nil
    ) async throws -> CommandResponse {
        let responses = try await sendCommandList(
            [command], timeout: timeout, onWritten: onWritten, onResponse: onResponse
        )
        return responses[0] // A nonempty list completes only after a response.
    }

    /// Runs non-blocking tmux commands as one command-queue transaction. A
    /// single input line prevents pane reads between capture and metadata queries.
    /// The boundary callback runs at the LAST response, before later %output.
    func sendCommandList(
        _ commands: [String],
        timeout: TimeInterval = 5,
        onWritten: (@Sendable () -> Void)? = nil,
        onResponse: (@MainActor @Sendable (CommandResponse) -> Void)? = nil
    ) async throws -> [CommandResponse] {
        guard !commands.isEmpty else { return [] }
        guard let stdin else {
            throw TmuxControlError.notConnected
        }

        commandCounter += 1
        let commandNumber = commandCounter

        let commandData = Data((commands.joined(separator: " ; ") + "\n").utf8)

        // Create timeout task that we can cancel on success
        let timeoutTask = Task {
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            // Keep a tombstone until tmux's response arrives. Removing a timed
            // out request would misassign its late response to the next capture.
            self.expirePendingCommand(id: commandNumber)
        }

        // Wait for response
        do {
            let response = try await withCheckedThrowingContinuation { continuation in
                pendingCommandQueue.append(PendingCommand(
                    id: commandNumber,
                    responseCount: commands.count,
                    continuation: continuation,
                    onResponse: onResponse
                ))
                do {
                    try stdin.write(contentsOf: commandData)
                    onWritten?()
                } catch {
                    pendingCommandQueue.removeLast()
                    continuation.resume(throwing: error)
                }
            }
            timeoutTask.cancel()
            return response
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    // MARK: - Read Loop

    private func expirePendingCommand(id: Int) {
        guard let idx = pendingCommandQueue.firstIndex(where: { $0.id == id }) else { return }
        let continuation = pendingCommandQueue[idx].continuation
        pendingCommandQueue[idx].continuation = nil
        continuation?.resume(throwing: TmuxControlError.timeout)
    }

    private func processIncomingData(_ data: Data) async {
        // Append raw bytes to buffer first (handles chunk splitting)
        byteBuffer.append(data)

        // Process complete lines (ending with newline byte 0x0A)
        let newlineByte: UInt8 = 0x0A

        while let newlineIndex = byteBuffer.firstIndex(of: newlineByte) {
            let lineData = Data(byteBuffer[..<newlineIndex])
            byteBuffer = Data(byteBuffer[(newlineIndex + 1)...])

            await parseLine(lineData)
        }
    }

    // MARK: - Line Parsing

    private func parseLine(_ lineData: Data) async {
        // A notification never occurs inside a command output block. Treat all
        // non-terminator lines there as command text, even if captured pane text
        // itself begins with a control-looking `%output` prefix.
        if currentCommandNumber == nil,
           let output = TmuxControlOutputDecoder.decode(lineData) {
            await handleOutput(output)
            return
        }

        // Only tmux's textual control records and capture-pane response lines
        // require UTF-8. A `%output` payload is an arbitrary byte stream and may
        // legally end in the middle of a scalar.
        guard let line = String(data: lineData, encoding: .utf8) else { return }

        if currentCommandNumber != nil {
            if line.hasPrefix("%end ") {
                await parseEndBlock(line)
            } else if line.hasPrefix("%error ") {
                await parseErrorBlock(line)
            } else {
                currentCommandOutput.append(line)
            }
            return
        }

        if line.hasPrefix("%layout-change ") {
            handleLayoutChange(line)
        } else if line.hasPrefix("%begin ") {
            parseBeginBlock(line)
        } else if line.hasPrefix("%exit") {
            parseExit(line)
        } else if line.hasPrefix("%session-changed ") {
            parseSessionChanged(line)
        }
    }

    private func handleOutput(_ output: TmuxControlOutput) async {
        // Track every pane even while delivery is disabled. A subscriber may be
        // enabled between the prefix and suffix of one terminal token; retaining
        // that tiny prefix is what makes its first snapshot boundary safe.
        var framer = outputFramers[output.paneId] ?? TerminalOutputTokenFramer()
        let framedData = framer.frame(output.data)
        outputFramers[output.paneId] = framer

        guard outputEnabledPaneIds.contains(output.paneId), !framedData.isEmpty else { return }
        var sanitizer = outputSanitizers[output.paneId] ?? TerminalOutputSanitizer()
        let data = sanitizer.sanitize(framedData)
        outputSanitizers[output.paneId] = sanitizer
        guard !data.isEmpty else { return }
        await _onOutput?(output.paneId, data)
    }

    // MARK: - Layout Change Handling

    private func handleLayoutChange(_ line: String) {
        logger.debug("Layout change detected")

        // Extract pane dimensions directly from the layout string in the event.
        // Format: "%layout-change @<window-id> <layout-string> [<visible-layout>]"
        // This fires BEFORE pipe-pane delivers the shell's SIGWINCH redraw data,
        // so the terminal resizes before processing absolute cursor positioning
        // sequences that assume the new column count.
        let parts = line.split(separator: " ", maxSplits: 2)
        if parts.count >= 3 {
            let layoutString = String(parts[2].split(separator: " ").first ?? parts[2])
            if let layout = TmuxLayoutParser.parse(layoutString) {
                updateTrackedDimensionsFromLayout(layout)
            }
        }

        // Still refresh via list-panes to detect pane exits (panes no longer in layout)
        Task { [weak self] in
            await self?.refreshStreamingPaneDimensions()
        }
        // Notify listeners that the layout changed — this triggers a full pane list
        // refresh so new panes (splits) and layout string updates are detected instantly
        // instead of waiting for the 5-second polling timer.
        _onLayoutChange?()
    }

    /// Walks the layout tree and fires dimension change callbacks for tracked panes
    /// whose dimensions differ from cached values.
    private func updateTrackedDimensionsFromLayout(_ node: LayoutNode) {
        switch node {
        case let .pane(id, width, height):
            let paneId = "%\(id)"
            if
                let cached = cachedDimensions[paneId],
                cached.width != width || cached.height != height {
                cachedDimensions[paneId] = (width, height)
                logger.debug("Pane dimension changed (from layout)", metadata: [
                    "paneId": "\(paneId)",
                    "width": "\(width)",
                    "height": "\(height)",
                ])
                _onDimensionChange?(paneId, width, height)
            }
        case let .horizontal(children, _, _),
             let .vertical(children, _, _):
            for child in children {
                updateTrackedDimensionsFromLayout(child)
            }
        }
    }

    private func refreshStreamingPaneDimensions() async {
        guard !cachedDimensions.isEmpty else { return }

        do {
            let response = try await sendCommand("list-panes -a -F '#{pane_id} #{pane_width} #{pane_height}'")

            // Collect pane IDs that still exist
            var existingPaneIds = Set<String>()

            for line in response.lines where !line.isEmpty {
                let parts = line.split(separator: " ")
                guard
                    parts.count == 3,
                    let width = Int(parts[1]),
                    let height = Int(parts[2]) else { continue }

                let paneId = String(parts[0])
                existingPaneIds.insert(paneId)

                // Only notify for panes we're tracking
                if
                    let cached = cachedDimensions[paneId],
                    cached.width != width || cached.height != height {
                    cachedDimensions[paneId] = (width, height)
                    logger.debug("Pane dimension changed", metadata: [
                        "paneId": "\(paneId)",
                        "width": "\(width)",
                        "height": "\(height)",
                    ])
                    _onDimensionChange?(paneId, width, height)
                }
            }

            // Check for panes we're tracking that no longer exist
            let trackedPaneIds = Set(cachedDimensions.keys)
            let exitedPaneIds = trackedPaneIds.subtracting(existingPaneIds)

            for paneId in exitedPaneIds {
                logger.info("Pane exited (no longer in list)", metadata: ["paneId": "\(paneId)"])
                cachedDimensions.removeValue(forKey: paneId)
                _onPaneExited?(paneId)
            }
        } catch {
            logger.error("Failed to refresh pane dimensions: \(error.localizedDescription)")
        }
    }

    // MARK: - Command Response Parsing

    private func parseBeginBlock(_ line: String) {
        // Format: %begin <timestamp> <command-number> <flags>
        let parts = line.split(separator: " ")
        guard
            parts.count >= 3,
            let tmuxCommandNumber = Int(parts[2]) else { return }

        // Skip the initial attach response (first %begin/%end after connecting).
        // This is tmux's response to the `tmux -C attach` command itself,
        // not a command we sent via sendCommand().
        if !receivedInitialResponse {
            receivedInitialResponse = true
            skippingInitialBlock = true
            currentCommandNumber = tmuxCommandNumber
            currentCommandOutput = []
            currentCommandIsError = false
            return
        }

        currentCommandNumber = tmuxCommandNumber
        currentCommandOutput = []
        currentCommandIsError = false
    }

    private func parseEndBlock(_ line: String) async {
        // Format: %end <timestamp> <command-number> <flags>
        await finalizeBlock(line: line, isError: currentCommandIsError)
    }

    private func parseErrorBlock(_ line: String) async {
        // Format: %error <timestamp> <command-number> <flags>
        // tmux uses %error as the block terminator for failed commands (in place of %end).
        // Resolve the queued entry with an error response so the caller unblocks immediately;
        // otherwise the next command's %end would silently pop this queue slot, misaligning
        // every subsequent response and eventually causing 5-second timeouts.
        await finalizeBlock(line: line, isError: true)
    }

    /// Shared handling for `%end` and `%error` — both terminate a command block.
    private func finalizeBlock(line: String, isError: Bool) async {
        let parts = line.split(separator: " ")
        guard
            parts.count >= 3,
            let tmuxCommandNumber = Int(parts[2]),
            tmuxCommandNumber == currentCommandNumber else { return }

        let response = CommandResponse(
            commandNumber: tmuxCommandNumber,
            output: currentCommandOutput.joined(separator: "\n"),
            isError: isError
        )

        // Skip the initial attach response (flagged in parseBeginBlock)
        if skippingInitialBlock {
            skippingInitialBlock = false
            currentCommandNumber = nil
            currentCommandOutput = []
            return
        }

        // Clear parser state before calling MainActor; that callback may queue
        // another command while this actor is suspended.
        currentCommandNumber = nil
        currentCommandOutput = []

        // tmux executes the list without reading more pane data between its
        // commands. An error skips the list's remaining commands (no responses).
        if !pendingCommandQueue.isEmpty {
            pendingCommandQueue[0].responses.append(response)
            if isError || pendingCommandQueue[0].responses.count == pendingCommandQueue[0].responseCount {
                let entry = pendingCommandQueue.removeFirst()
                if let continuation = entry.continuation {
                    await entry.onResponse?(response)
                    continuation.resume(returning: entry.responses)
                }
            }
        }
    }

    // MARK: - Session and Exit Parsing

    private func parseSessionChanged(_ line: String) {
        // Format: %session-changed $<session-id> <session-name>
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return }

        let sessionId = String(parts[1])
        let sessionName = String(parts[2])

        logger.info("Session changed", metadata: [
            "sessionId": "\(sessionId)",
            "sessionName": "\(sessionName)",
        ])

        _onSessionChanged?(sessionId, sessionName)
    }

    private func parseExit(_ line: String) {
        // Format: %exit [reason]
        let reason = line.hasPrefix("%exit ") ? String(line.dropFirst("%exit ".count)) : nil

        logger.info("tmux control mode exited", metadata: [
            "reason": "\(reason ?? "none")",
        ])

        _onExit?(reason)
    }

    private func handleProcessTermination(generation: UInt64, exitCode: Int32) async {
        guard generation == processGeneration else {
            logger.debug("Ignoring stale tmux process termination", metadata: [
                "generation": "\(generation)",
                "currentGeneration": "\(processGeneration)",
            ])
            return
        }

        logger.warning("tmux process terminated", metadata: [
            "exitCode": "\(exitCode)",
        ])

        // Cancel all pending commands
        for entry in pendingCommandQueue {
            entry.continuation?.resume(throwing: TmuxControlError.processTerminated(reason: "Exit code: \(exitCode)"))
        }
        pendingCommandQueue.removeAll()

        _onExit?("Process terminated with code \(exitCode)")

        // Clean up
        process = nil
        stdin = nil
        stdoutPipe = nil
    }

    // MARK: - Test Hooks

    /// Feeds synthetic control-mode bytes through the parser. Tests only.
    func testProcessIncomingData(_ data: Data) async {
        await processIncomingData(data)
    }

    /// Enqueues a continuation that would be resumed by a `%end` or `%error` block.
    /// Returns the resolved response (or throws on error/timeout). Tests only.
    func testEnqueueCommand(
        id: Int,
        onResponse: (@MainActor @Sendable (CommandResponse) -> Void)? = nil
    ) async throws -> CommandResponse {
        let responses = try await testEnqueueCommandList(id: id, count: 1, onResponse: onResponse)
        return responses[0]
    }

    func testEnqueueCommandList(
        id: Int,
        count: Int,
        onResponse: (@MainActor @Sendable (CommandResponse) -> Void)? = nil
    ) async throws -> [CommandResponse] {
        try await withCheckedThrowingContinuation { continuation in
            pendingCommandQueue.append(PendingCommand(
                id: id,
                responseCount: count,
                continuation: continuation,
                onResponse: onResponse
            ))
        }
    }

    func testSetPaneOutputEnabled(_ paneId: String, enabled: Bool) {
        setPaneOutputEnabled(paneId: paneId, enabled: enabled)
    }

    func testExpireCommand(id: Int) {
        expirePendingCommand(id: id)
    }

    /// Number of pending commands awaiting a response. Tests only.
    var testPendingCommandCount: Int {
        pendingCommandQueue.count
    }

    /// PID of the exact control-mode subprocess owned by this actor. Tests only.
    var testProcessIdentifier: Int32? {
        process?.processIdentifier
    }

    /// Bypass the initial attach-response skip so tests can feed normal blocks. Tests only.
    func testMarkInitialAttachHandled() {
        receivedInitialResponse = true
    }
}
