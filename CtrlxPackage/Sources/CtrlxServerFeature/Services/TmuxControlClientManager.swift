#if os(macOS)
    import CtrlxNetworking
    import Foundation
    import Logging

    /// Manages TmuxControlClient instances, one per tmux session.
    ///
    /// When multiple panes from the same session are being streamed, they share
    /// a single control mode connection. This reduces resource usage and ensures
    /// consistent event handling across all panes in a session.
    ///
    /// Commands and pane output share each session's control connection so
    /// snapshot boundaries and incremental terminal bytes have one ordering.
    @Observable
    @MainActor
    final public class TmuxControlClientManager {
        private let logger = Logger(label: "com.jicezeng.ctrlx.controlclientmanager")

        private let tmuxPath: String
        private let socketPath: String?

        /// Active control clients keyed by session name
        private var clients: [String: TmuxControlClient] = [:]

        /// MainActor reentrancy during actor setup must not create a second
        /// connection for the same session. The entire check/create operation
        /// has one in-flight task, registered before its first suspension.
        private struct ConnectionFlight {
            let token: UUID
            let task: Task<TmuxControlClient, Error>
        }

        private var connectionFlights: [String: ConnectionFlight] = [:]
        private var isShuttingDown = false

        /// Callback for dimension changes (forwarded to PaneStreamManager)
        private var _onDimensionChange: (@MainActor (String, Int, Int) -> Void)?

        /// Callback when panes may have changed (pane exited or session disconnected).
        /// Listeners should refresh their pane list and clean up stale sessions.
        private var _onPanesChanged: (@MainActor () -> Void)?

        /// Decoded and sanitized live terminal bytes.
        private var _onOutput: (@MainActor (String, Data) -> Void)?

        /// Pane output remains disabled until at least one mirror subscribes.
        private var outputEnabledPaneIdsBySession: [String: Set<String>] = [:]

        public init(tmuxPath: String = "/opt/homebrew/bin/tmux", socketPath: String? = nil) {
            self.tmuxPath = tmuxPath
            self.socketPath = socketPath
        }

        /// Sets the callback for dimension changes.
        /// Called when any tracked pane's dimensions change.
        public func setOnDimensionChange(_ handler: @escaping @MainActor (String, Int, Int) -> Void) {
            _onDimensionChange = handler
        }

        /// Sets the callback for when panes may have changed.
        /// Called when a pane exits or a session disconnects.
        /// Listeners should refresh their pane list and clean up stale sessions.
        public func setOnPanesChanged(_ handler: @escaping @MainActor () -> Void) {
            _onPanesChanged = handler
        }

        public func setOnOutput(_ handler: @escaping @MainActor (String, Data) -> Void) {
            _onOutput = handler
        }

        /// Gets or creates a control client for the specified session.
        ///
        /// - Parameter sessionName: The tmux session name
        /// - Returns: The control client for this session
        /// - Throws: If connection fails
        func getClient(for sessionName: String) async throws -> TmuxControlClient {
            guard !isShuttingDown else { throw TmuxControlError.notConnected }
            if let flight = connectionFlights[sessionName] {
                return try await flight.task.value
            }

            let token = UUID()
            let task = Task { try await self.connectClient(for: sessionName) }
            connectionFlights[sessionName] = ConnectionFlight(token: token, task: task)
            defer {
                if connectionFlights[sessionName]?.token == token {
                    connectionFlights.removeValue(forKey: sessionName)
                }
            }
            return try await task.value
        }

        private func connectClient(for sessionName: String) async throws -> TmuxControlClient {
            try Task.checkCancellation()
            if let existing = clients[sessionName], await existing.isConnected {
                logger.debug("Reusing existing control client", metadata: [
                    "session": "\(sessionName)",
                ])
                return existing
            }

            logger.info("Creating new control client", metadata: [
                "session": "\(sessionName)",
            ])

            let client = TmuxControlClient(tmuxPath: tmuxPath, socketPath: socketPath)

            // Set up dimension change handler
            await client.setOnDimensionChange { [weak self] paneId, width, height in
                Task { @MainActor [weak self] in
                    self?.handleDimensionChange(paneId: paneId, width: width, height: height)
                }
            }

            // Set up pane exit handler (pane closed but session still running)
            await client.setOnPaneExited { [weak self] paneId in
                Task { @MainActor [weak self] in
                    self?.handlePanesChanged(reason: "pane \(paneId) exited")
                }
            }

            // Set up layout change handler (pane added/removed/resized)
            await client.setOnLayoutChange { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handlePanesChanged(reason: "layout changed")
                }
            }

            // Set up exit handler (entire session ended)
            await client.setOnExit { [weak self, weak client] reason in
                guard let client else { return }
                Task { @MainActor [weak self] in
                    self?.handleClientExit(
                        client,
                        sessionName: sessionName,
                        reason: reason
                    )
                }
            }

            await client.setOnOutput { [weak self] paneId, data in
                self?._onOutput?(paneId, data)
            }

            do {
                try Task.checkCancellation()
                try await client.connect(sessionTarget: sessionName)
                for paneId in outputEnabledPaneIdsBySession[sessionName] ?? [] {
                    await client.setPaneOutputEnabled(paneId: paneId, enabled: true)
                }
                try Task.checkCancellation()
                guard !isShuttingDown else { throw TmuxControlError.notConnected }
            } catch {
                await client.disconnect()
                throw error
            }
            clients[sessionName] = client

            return client
        }

        /// Registers a pane for dimension tracking via the control client.
        ///
        /// - Parameters:
        ///   - paneId: The pane ID (e.g., "%0")
        ///   - sessionName: The session this pane belongs to
        ///   - dimensions: Initial pane dimensions
        public func registerPaneDimensions(
            paneId: String,
            sessionName: String,
            dimensions: (width: Int, height: Int)
        ) async throws {
            let client = try await getClient(for: sessionName)
            await client.registerPaneDimensions(paneId: paneId, width: dimensions.width, height: dimensions.height)

            logger.info("Registered pane for dimension tracking", metadata: [
                "paneId": "\(paneId)",
                "session": "\(sessionName)",
            ])
        }

        /// Sends a tmux command through the control client for the given session.
        func sendCommand(
            _ command: String,
            sessionName: String,
            timeout: TimeInterval = 5,
            onResponse: (@MainActor @Sendable (CommandResponse) -> Void)? = nil
        ) async throws -> CommandResponse {
            let client = try await getClient(for: sessionName)
            return try await client.sendCommand(
                command,
                timeout: timeout,
                onResponse: onResponse
            )
        }

        func sendCommandList(
            _ commands: [String],
            sessionName: String,
            onResponse: (@MainActor @Sendable (CommandResponse) -> Void)? = nil
        ) async throws -> [CommandResponse] {
            let client = try await getClient(for: sessionName)
            return try await client.sendCommandList(commands, onResponse: onResponse)
        }

        /// Enables or disables terminal output delivery for one pane. Enabling
        /// also creates the session control client before a snapshot starts.
        func setPaneOutputEnabled(
            paneId: String,
            sessionName: String,
            enabled: Bool
        ) async throws {
            if enabled {
                let client = try await getClient(for: sessionName)
                outputEnabledPaneIdsBySession[sessionName, default: []].insert(paneId)
                await client.setPaneOutputEnabled(paneId: paneId, enabled: true)
            } else {
                outputEnabledPaneIdsBySession[sessionName]?.remove(paneId)
                if outputEnabledPaneIdsBySession[sessionName]?.isEmpty == true {
                    outputEnabledPaneIdsBySession.removeValue(forKey: sessionName)
                }
                if let client = clients[sessionName] {
                    await client.setPaneOutputEnabled(paneId: paneId, enabled: false)
                }
            }
        }

        /// Sends a small interactive key batch through an existing control client.
        ///
        /// This method never creates a connection. Returning `false` means no
        /// command was written and the caller may safely use its process-based
        /// fallback. Once any command succeeds, later failures are thrown instead
        /// of returning `false`, which prevents replaying an already-partial batch.
        func sendKeystrokesIfConnected(
            paneId: String,
            sessionName: String,
            keys: [TmuxKey],
            onFirstCommandWritten: (@Sendable () -> Void)? = nil
        ) async throws -> Bool {
            guard let commands = TmuxControlInputEncoder.commands(paneId: paneId, keys: keys) else {
                return false
            }
            return try await sendInputCommandsIfConnected(
                commands, sessionName: sessionName, onFirstCommandWritten: onFirstCommandWritten
            )
        }

        /// Shares the keyboard transport without creating another control client
        /// or spawning one tmux process per scroll event. A thrown error must NOT
        /// trigger fallback: bytes may already have reached the pane.
        func sendRawBytesIfConnected(
            paneId: String,
            sessionName: String,
            data: Data,
            onFirstCommandWritten: (@Sendable () -> Void)? = nil
        ) async throws -> Bool {
            guard let commands = TmuxControlInputEncoder.commands(paneId: paneId, rawBytes: data) else {
                return false
            }
            return try await sendInputCommandsIfConnected(
                commands, sessionName: sessionName, onFirstCommandWritten: onFirstCommandWritten
            )
        }

        private func sendInputCommandsIfConnected(
            _ commands: [String],
            sessionName: String,
            onFirstCommandWritten: (@Sendable () -> Void)?
        ) async throws -> Bool {
            guard !commands.isEmpty else { return true }
            guard let client = clients[sessionName], await client.isConnected else { return false }

            var completedCommand = false
            for (index, command) in commands.enumerated() {
                let response: CommandResponse
                do {
                    response = try await client.sendCommand(
                        command,
                        onWritten: index == 0 ? onFirstCommandWritten : nil
                    )
                } catch TmuxControlError.notConnected where !completedCommand {
                    return false
                } catch {
                    throw error
                }

                guard !response.isError else {
                    throw TmuxControlError.commandFailed(message: response.output)
                }
                completedCommand = true
            }
            return true
        }

        /// Unregisters a pane from dimension tracking.
        ///
        /// - Parameters:
        ///   - paneId: The pane ID
        ///   - sessionName: The session this pane belongs to
        public func unregisterPane(paneId: String, sessionName: String) async {
            guard let client = clients[sessionName] else { return }
            await client.unregisterPane(paneId: paneId)

            logger.info("Unregistered pane", metadata: [
                "paneId": "\(paneId)",
                "session": "\(sessionName)",
            ])

            // Keep the connection alive for faster reconnection when new panes are added.
            // Client cleanup happens via handleClientExit when the session is destroyed.
        }

        /// Moves a live control connection to the session's new dictionary key.
        /// tmux keeps the connection attached across `rename-session`; only our
        /// lookup key and exit callback need to follow the new name.
        func sessionRenamed(from oldName: String, to newName: String) async {
            if let outputPaneIds = outputEnabledPaneIdsBySession.removeValue(forKey: oldName) {
                outputEnabledPaneIdsBySession[newName, default: []].formUnion(outputPaneIds)
            }
            guard oldName != newName, let client = clients.removeValue(forKey: oldName) else { return }

            if clients[newName] != nil {
                // A subscriber raced ahead and already established the new-key
                // client. Keep that authoritative connection; the old client's
                // exit callback still targets oldName, so disconnecting it cannot
                // remove the replacement.
                await client.disconnect()
                return
            }

            await client.setOnExit { [weak self, weak client] reason in
                guard let client else { return }
                Task { @MainActor [weak self] in
                    self?.handleClientExit(
                        client,
                        sessionName: newName,
                        reason: reason
                    )
                }
            }
            clients[newName] = client

            logger.info("Rekeyed control client after session rename", metadata: [
                "oldSession": "\(oldName)",
                "newSession": "\(newName)",
            ])
        }

        /// Disconnects all control clients.
        public func disconnectAll() async {
            logger.info("Disconnecting all control clients")
            isShuttingDown = true
            let flights = Array(connectionFlights.values)
            connectionFlights.removeAll()
            for flight in flights { flight.task.cancel() }
            for flight in flights { _ = try? await flight.task.value }
            let clientsToDisconnect = clients
            clients.removeAll()
            outputEnabledPaneIdsBySession.removeAll()

            // Each client owns an independent child process. Stop them in
            // parallel so one wedged session cannot consume the shutdown budget
            // before the remaining exact child PIDs are reaped.
            await withTaskGroup(of: String.self) { group in
                for (sessionName, client) in clientsToDisconnect {
                    group.addTask {
                        await client.disconnect()
                        return sessionName
                    }
                }
                for await sessionName in group {
                    logger.debug("Disconnected client", metadata: [
                        "session": "\(sessionName)",
                    ])
                }
            }
        }

        /// Extracts the session name from a pane target.
        ///
        /// Pane targets can be in various formats:
        /// - `session:window.pane` (e.g., "mysession:0.1")
        /// - `session:window` (e.g., "mysession:0")
        /// - `session` (e.g., "mysession")
        ///
        /// - Parameter target: The pane target string
        /// - Returns: A textual session name, or nil for stable IDs that require
        ///   a tmux lookup. Never use a pane ID as a connection dictionary key.
        public static func extractSessionName(from target: String) -> String? {
            guard let first = target.first, !["%", "@", "$"].contains(first) else { return nil }
            if let colonIndex = target.firstIndex(of: ":") {
                return String(target[..<colonIndex])
            }
            return target
        }

        // MARK: - Private Methods

        private func handleDimensionChange(paneId: String, width: Int, height: Int) {
            logger.debug("Dimension change from control client", metadata: [
                "paneId": "\(paneId)",
                "width": "\(width)",
                "height": "\(height)",
            ])
            _onDimensionChange?(paneId, width, height)
        }

        private func handlePanesChanged(reason: String) {
            logger.info("Panes changed", metadata: ["reason": "\(reason)"])
            _onPanesChanged?()
        }

        private func handleClientExit(
            _ client: TmuxControlClient,
            sessionName: String,
            reason: String?
        ) {
            guard clients[sessionName] === client else { return }
            logger.warning("Control client exited", metadata: [
                "session": "\(sessionName)",
                "reason": "\(reason ?? "unknown")",
            ])
            clients.removeValue(forKey: sessionName)
            handlePanesChanged(reason: "session \(sessionName) disconnected")

            guard outputEnabledPaneIdsBySession[sessionName]?.isEmpty == false else { return }
            Task { @MainActor [weak self] in
                do {
                    _ = try await self?.getClient(for: sessionName)
                } catch {
                    self?.logger.warning("Failed to reconnect output control client", metadata: [
                        "session": "\(sessionName)",
                        "error": "\(error)",
                    ])
                }
            }
        }
    }
#endif
