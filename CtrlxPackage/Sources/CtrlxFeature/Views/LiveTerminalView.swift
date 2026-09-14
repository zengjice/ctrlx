#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// Displays a live streaming terminal from the host app.
    ///
    /// This view requests a terminal stream from the host, displays the live output,
    /// and handles dimension changes. It replaces the static snapshot view.
    ///
    /// When `isInteractive` is true, the terminal accepts keyboard input which is
    /// forwarded to tmux via the relay server.
    struct LiveTerminalView: View {
        let paneId: String

        /// Binding to the response state for displaying response options above the terminal
        @Binding var responseState: ResponseState?

        /// Binding to the terminal title detected via OSC escape sequences
        @Binding var terminalTitle: String?

        /// Binding to the latest clipboard content from the host (OSC 52)
        @Binding var clipboardContent: String?

        /// Whether the host is connected
        let isConnected: Bool

        /// Whether yolo mode is enabled for this pane
        let isYoloMode: Bool

        /// Whether the navigation bar is hidden (show an overlay copy button)
        let hideNavigationBar: Bool

        /// Whether to show the keyboard toggle in the bottom safe area.
        /// Set to false when used in multi-pane layouts where the parent manages the keyboard.
        let showKeyboardButton: Bool

        /// Shared settings. The body reads the control position directly so a
        /// Settings change updates an already-open terminal without reconnecting.
        let settings: IOSSettings

        /// Whether this pane owns the terminal-copy toolbar action.
        /// Multi-pane layouts enable it only for the selected pane.
        let showCopyButton: Bool

        /// Whether this terminal pane is the active/selected one.
        /// When false, keyboard input and its shortcut bar are suppressed.
        /// Used in multi-pane layouts where only the selected pane accepts input.
        let isActive: Bool

        /// Whether a parent-managed multi-pane layout wants the software keyboard.
        /// The selected pane keeps its shortcut bar available even when this is false.
        let parentKeyboardRequested: Bool

        /// Submits a structured `AgentResponse` for the open response form.
        let submitResponse: ResponseSender

        /// Observes keyboard input after it has entered the terminal send queue.
        /// The parent uses this only to detect user-submitted Agent turns.
        let onTerminalInput: @MainActor ([TmuxKey]) -> Void

        /// Lets a parent-owned input bar capture this pane's terminal text only
        /// when dictation starts, without continuously mirroring terminal output.
        let onVoiceInputContextProviderChange: @MainActor (TerminalVoiceInputContextProvider?) -> Void

        /// Parent-owned input controls must cancel a pending tap correction
        /// before sending their own keys to this pane.
        let onCursorNavigationCancellationChange: @MainActor ((@MainActor () -> Void)?) -> Void

        /// Lets a parent-owned command menu fail closed while this pane is
        /// bootstrapping or reconnecting, without reading terminal pixels.
        let onTerminalInputReadinessChange: @MainActor ((@MainActor () -> Bool)?) -> Void

        /// Live OTEL telemetry for this pane's session (issue #597), shown as a
        /// thin meter strip above the terminal (surface C).
        var telemetry: SessionTelemetry?

        @Environment(ViewerRelayClient.self) private var relayClient
        @State private var coordinator: StreamCoordinator

        /// Whether this standalone terminal requests the software keyboard.
        @State private var isInteractive = false

        /// Changes when the user manually retries a failed stream. Combined with
        /// `isConnected`, this gives the stream task a stable, explicit identity.
        @State private var streamRetryGeneration = 0

        /// Immutable terminal text shown in the native iOS copy surface.
        @State private var textSnapshot: TerminalTextSnapshot?

        /// Restores toolbar-controlled terminal input after the copy sheet closes.
        /// Parent-controlled multi-pane input is restored by its existing binding.
        @State private var restoresTerminalInputAfterCopy = false

        /// Whether the terminal had no meaningful text when a snapshot was requested.
        @State private var showsEmptySnapshotAlert = false

        init(
            paneId: String,
            responseState: Binding<ResponseState?>,
            terminalTitle: Binding<String?>,
            clipboardContent: Binding<String?> = .constant(nil),
            isConnected: Bool,
            isYoloMode: Bool = false,
            hideNavigationBar: Bool = false,
            showKeyboardButton: Bool = true,
            showCopyButton: Bool = true,
            isActive: Bool = true,
            parentKeyboardRequested: Bool = false,
            settings: IOSSettings,
            telemetry: SessionTelemetry? = nil,
            submitResponse: @escaping ResponseSender,
            onTerminalInput: @escaping @MainActor ([TmuxKey]) -> Void = { _ in },
            onVoiceInputContextProviderChange: @escaping @MainActor (
                TerminalVoiceInputContextProvider?
            ) -> Void = { _ in },
            onCursorNavigationCancellationChange: @escaping @MainActor ((@MainActor () -> Void)?) -> Void = { _ in },
            onTerminalInputReadinessChange: @escaping @MainActor ((@MainActor () -> Bool)?) -> Void = { _ in }
        ) {
            self.paneId = paneId
            self._responseState = responseState
            self._terminalTitle = terminalTitle
            self._clipboardContent = clipboardContent
            self.isConnected = isConnected
            self.isYoloMode = isYoloMode
            self.hideNavigationBar = hideNavigationBar
            self.showKeyboardButton = showKeyboardButton
            self.settings = settings
            self.showCopyButton = showCopyButton
            self.isActive = isActive
            self.parentKeyboardRequested = parentKeyboardRequested
            self.telemetry = telemetry
            self.submitResponse = submitResponse
            self.onTerminalInput = onTerminalInput
            self.onVoiceInputContextProviderChange = onVoiceInputContextProviderChange
            self.onCursorNavigationCancellationChange = onCursorNavigationCancellationChange
            self.onTerminalInputReadinessChange = onTerminalInputReadinessChange
            self.coordinator = StreamCoordinator(
                paneId: paneId,
                fontName: settings.terminalFontName,
                fontSize: CGFloat(settings.terminalFontSize)
            )
        }

        var body: some View {
            VStack(spacing: 0) {
                // Response view above terminal (hidden when terminal keyboard is active)
                // We use isInteractive (explicit terminal input mode) rather than keyboardVisible
                // to avoid hiding when response view's own TextField activates the keyboard
                if
                    !isInteractive,
                    let responseState {
                    responseState.request.responseView(
                        isConnected: isConnected,
                        submit: submitResponse,
                        state: responseState
                    )
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    // Preserve blocking forms for their request lifetime, but
                    // give each synthesized reply turn a fresh TextField.
                    .id(responseState.viewIdentity)

                    Divider()
                }

                // Live OTEL meter strip for the viewed session (issue #597, surface C).
                if let telemetry, telemetry.tokensUsed > 0 || telemetry.costUSD > 0 {
                    mirrorMeterStrip(telemetry)
                }

                // Keep the copy action reachable when the navigation bar is hidden.
                terminalContent
                    .overlay(alignment: .topTrailing) {
                        if hideNavigationBar {
                            HStack(spacing: 8) {
                                if showCopyButton {
                                    copyOverlayButton
                                }
                                if showKeyboardButton, settings.terminalKeyboardControlPosition == .topRight {
                                    TerminalVoiceInputButton(
                                        isDisabled: !canSendTerminalInput,
                                        contextProvider: terminalVoiceInputContext,
                                        sendKeys: sendTerminalKeys
                                    )
                                    keyboardOverlayButton
                                }
                            }
                        }
                    }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showKeyboardButton, settings.terminalKeyboardControlPosition == .bottomBar {
                    TerminalKeyboardBar(
                        keyboardRequested: isInteractive,
                        isEnabled: isConnected && coordinator.streamState == .streaming,
                        action: { isInteractive.toggle() },
                        contextProvider: terminalVoiceInputContext,
                        sendKeys: sendTerminalKeys
                    )
                }
            }
            .toolbar {
                if showCopyButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        copyButton
                    }
                }

                if showKeyboardButton, settings.terminalKeyboardControlPosition == .topRight, !hideNavigationBar {
                    ToolbarItem(placement: .topBarTrailing) {
                        TerminalVoiceInputButton(
                            isDisabled: !canSendTerminalInput,
                            contextProvider: terminalVoiceInputContext,
                            sendKeys: sendTerminalKeys
                        )
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isInteractive.toggle()
                        } label: {
                            Label(
                                isInteractive ? "Hide Keyboard" : "Show Keyboard",
                                symbol: isInteractive ? .keyboardChevronCompactDown : .keyboard
                            )
                        }
                        .disabled(!isConnected || coordinator.streamState != .streaming)
                    }
                }
            }
            .sheet(item: $textSnapshot, onDismiss: restoreTerminalInputAfterCopy) { snapshot in
                TerminalTextCopyView(snapshot: snapshot)
            }
            .alert("No Terminal Text", isPresented: $showsEmptySnapshotAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The terminal buffer does not contain any text to copy.")
            }
            .task(id: StreamTaskID(isConnected: isConnected, retryGeneration: streamRetryGeneration)) {
                await synchronizeStreamingWithConnection()
            }
            .onAppear {
                let coordinator = coordinator
                onVoiceInputContextProviderChange { [weak coordinator] in
                    coordinator?.voiceInputContext()
                }
                onCursorNavigationCancellationChange { [weak coordinator] in
                    coordinator?.terminalState?.cancelCursorNavigation?()
                }
                onTerminalInputReadinessChange { [weak coordinator] in
                    coordinator?.isReadyForAgentCommand == true
                }
            }
            .onDisappear {
                onVoiceInputContextProviderChange(nil)
                onCursorNavigationCancellationChange(nil)
                onTerminalInputReadinessChange(nil)
                coordinator.terminalState?.cancelCursorNavigation?()
                Task { await stopStreaming() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                // The viewport is final now. One deterministic scroll replaces
                // the old uncancelled 350 ms tasks fired by keyboardWillShow.
                coordinator.terminalState?.scrollToBottom?()
            }
            .onChange(of: coordinator.streamState) { _, newState in
                if
                    newState == .ended,
                    coordinator.shouldRetryUnexpectedEnd(isConnected: isConnected) {
                    streamRetryGeneration &+= 1
                }
            }
            .onChange(of: coordinator.terminalTitle) { _, newTitle in
                terminalTitle = newTitle
            }
            .onChange(of: coordinator.pendingClipboardContent) { _, newContent in
                clipboardContent = newContent
            }
        }

        /// Thin meter strip showing the viewed session's live tokens · cost ·
        /// last-turn latency (issue #597, surface C).
        private func mirrorMeterStrip(_ telemetry: SessionTelemetry) -> some View {
            HStack(spacing: 8) {
                SessionMeterView(telemetry: telemetry)
                if let latency = telemetry.lastTurnLatencyMs {
                    Text("· \(latency.latencyString)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }

        private var copyButton: some View {
            Button(action: presentTextSnapshot) {
                Label("Copy Terminal Text", symbol: .docOnClipboard)
            }
            .disabled(coordinator.streamState != .streaming)
        }

        /// Keyboard toggle used when the navigation bar is hidden.
        private var keyboardOverlayButton: some View {
            Button {
                isInteractive.toggle()
            } label: {
                (isInteractive ? Symbols.keyboardChevronCompactDown.image : Symbols.keyboard.image)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel(isInteractive ? "Hide Keyboard" : "Show Keyboard")
            .disabled(!isConnected || coordinator.streamState != .streaming)
            .padding(8)
        }

        private var copyOverlayButton: some View {
            Button(action: presentTextSnapshot) {
                Symbols.docOnClipboard.image
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Copy Terminal Text")
            .disabled(coordinator.streamState != .streaming)
            .padding(8)
        }

        private func presentTextSnapshot() {
            guard let snapshot = coordinator.terminalState?.makeTextSnapshot?() else {
                showsEmptySnapshotAlert = true
                return
            }

            let presentation = terminalInputPresentation(isCopyPresented: false)
            restoresTerminalInputAfterCopy = showKeyboardButton && presentation.keyboardRequested
            isInteractive = false

            // Sheet presentation does not reliably release the terminal's
            // UIKit first responder. Resign synchronously before changing the
            // presentation state; the effective-interactivity guard below
            // prevents a later SwiftUI update from activating it again.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
            textSnapshot = snapshot
        }

        private func terminalVoiceInputContext() -> String? {
            VoiceInputContext.makeTerminalContext(
                terminalText: coordinator.voiceInputContext()
            )
        }

        private func restoreTerminalInputAfterCopy() {
            defer { restoresTerminalInputAfterCopy = false }
            guard restoresTerminalInputAfterCopy, isActive else { return }
            isInteractive = true
        }

        @ViewBuilder
        private var terminalContent: some View {
            switch coordinator.streamState {
            case .idle,
                 .connecting:
                ProgressView("Connecting to terminal...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .streaming:
                if let state = coordinator.terminalState {
                    // A presented copy sheet always wins over both toolbar and
                    // parent-controlled input. This prevents the underlying
                    // UIKit terminal from reclaiming first responder mid-sheet.
                    let inputPresentation = terminalInputPresentation(
                        isCopyPresented: textSnapshot != nil
                    )
                    TerminalStreamContainerView(
                        terminalState: state,
                        inputEnabled: inputPresentation.inputEnabled,
                        keyboardRequested: inputPresentation.keyboardRequested,
                        onInput: { keys in
                            sendTerminalKeys(keys)
                        },
                        onRawInput: { data in
                            coordinator.enqueueRawInput(data: data, relayClient: relayClient)
                        }
                    )
                } else {
                    ProgressView("Initializing terminal...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .ended:
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Terminal Stream Ended",
                        symbol: .exclamationmarkTriangle,
                        description: "The pane still exists, but its terminal stream stopped."
                    )

                    Button("Reconnect") {
                        streamRetryGeneration &+= 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConnected)
                }

            case .error:
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Stream Error",
                        symbol: .exclamationmarkTriangle,
                        description: coordinator.error ?? "Unknown error"
                    )

                    Button("Retry") {
                        streamRetryGeneration &+= 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConnected)
                }
            }
        }

        private var canSendTerminalInput: Bool {
            isConnected && coordinator.streamState == .streaming
        }

        private func terminalInputPresentation(
            isCopyPresented: Bool
        ) -> TerminalInputPresentation.State {
            TerminalInputPresentation.resolve(
                keyboardRequested: showKeyboardButton ? isInteractive : parentKeyboardRequested,
                isActive: isActive,
                isCopyPresented: isCopyPresented
            )
        }

        private func sendTerminalKeys(_ keys: [TmuxKey]) {
            guard canSendTerminalInput, !keys.isEmpty else { return }
            coordinator.enqueueKeySend(keys: keys, relayClient: relayClient)
            onTerminalInput(keys)
        }

        // MARK: - Streaming

        private func synchronizeStreamingWithConnection() async {
            guard isConnected else {
                coordinator.prepareForReconnect()
                return
            }

            await startStreaming()
        }

        private func startStreaming() async {
            var startMode = coordinator.nextStartMode()

            // One retry handles a command response lost during an otherwise
            // successful reconnect. WebSocket reconnection remains responsible
            // for longer outages; this loop must never become an infinite poll.
            for attempt in 0..<2 {
                guard !Task.isCancelled, relayClient.isHostConnected else {
                    coordinator.prepareForReconnect()
                    return
                }

                let previousLeaseId = coordinator.activeLeaseId
                let leaseId = UUID()
                let streamSessionId = coordinator.beginAttempt(leaseId: leaseId)
                let currentCoordinator = coordinator
                let currentPaneId = paneId

                // Install the handler before sending commands. The host sends the
                // initial state before its start response, so registering later can
                // lose the only complete screen snapshot.
                let handlerRegistrationId = relayClient.registerTerminalStreamHandler(
                    for: currentPaneId
                ) { message in
                    guard currentCoordinator.streamSessionId == streamSessionId else { return }
                    currentCoordinator.handleStreamMessage(message)
                }
                coordinator.setHandlerRegistrationId(handlerRegistrationId)

                if startMode == .replaceExisting, let previousLeaseId {
                    _ = await relayClient.sendCommand(
                        StopTerminalStream(leaseId: previousLeaseId),
                        paneId: paneId
                    )

                    guard
                        !Task.isCancelled,
                        relayClient.isHostConnected,
                        coordinator.streamSessionId == streamSessionId
                    else {
                        coordinator.prepareForReconnect()
                        return
                    }
                }

                coordinator.willSendStartRequest()
                let result = await relayClient.sendCommand(
                    StartTerminalStream(leaseId: leaseId),
                    paneId: paneId
                )

                guard coordinator.streamSessionId == streamSessionId else { return }

                switch result {
                case .success:
                    // A Stage 16 host sends every bootstrap byte before this
                    // response. Keep the terminal offscreen until both events
                    // have arrived, matching the macOS viewer.
                    coordinator.receiveStartAcknowledgement()
                    switch TerminalStreamRecoveryPolicy.resolveSuccessfulStart(
                        hasInitialState: coordinator.hasInitialState,
                        canRetry: attempt == 0
                    ) {
                    case .ready:
                        coordinator.revealTerminalIfReady()
                        return
                    case .retryReplacement:
                        startMode = .replaceExisting
                        continue
                    case .failMissingInitialState:
                        coordinator.fail(MissingInitialStateError())
                        return
                    }

                case let .failure(error):
                    guard !Task.isCancelled, relayClient.isHostConnected else {
                        coordinator.prepareForReconnect()
                        return
                    }

                    if attempt == 0 {
                        startMode = .replaceExisting
                        do {
                            try await Task.sleep(for: .milliseconds(500))
                        } catch {
                            return
                        }
                        continue
                    }

                    coordinator.fail(error)
                }
            }
        }

        private struct MissingInitialStateError: LocalizedError {
            var errorDescription: String? {
                "The host accepted the terminal stream, but did not send its initial state."
            }
        }

        private func stopStreaming() async {
            let leaseId = coordinator.endStreaming()
            if let registrationId = coordinator.takeHandlerRegistrationId() {
                relayClient.unregisterTerminalStreamHandler(
                    for: paneId,
                    registrationId: registrationId
                )
            }

            guard let leaseId, isConnected else { return }
            _ = await relayClient.sendCommand(
                StopTerminalStream(leaseId: leaseId),
                paneId: paneId
            )
        }

        private struct StreamTaskID: Equatable {
            let isConnected: Bool
            let retryGeneration: Int
        }
    }

    // MARK: - Stream Coordinator

    /// Observable class that manages stream state.
    /// Uses a session ID to prevent stale callbacks from processing messages.
    @Observable
    @MainActor
    final private class StreamCoordinator {
        let paneId: String
        let fontName: String
        let fontSize: CGFloat

        var streamState: StreamState = .idle
        var terminalState: TerminalState?
        var terminalTitle: String?
        var error: String?

        /// Latest clipboard content received from the host via OSC 52.
        /// The parent view checks focus state before applying to UIPasteboard.
        var pendingClipboardContent: String?

        /// Unique identifier for the current streaming session.
        /// Set when streaming starts, cleared when streaming stops.
        /// Prevents race conditions where old callbacks process messages meant for new sessions.
        var streamSessionId: UUID?

        /// Lease currently authorized to own the host stream for this view.
        private(set) var activeLeaseId: UUID?

        /// Token proving ownership of the relay client's per-pane callback.
        private var handlerRegistrationId: UUID?

        @ObservationIgnored
        private var stabilityTask: Task<Void, Never>?

        @ObservationIgnored
        private var keystrokeDebouncer: KeystrokeDebouncer?

        @ObservationIgnored private var bootstrapPolicy = TerminalStreamBootstrapPolicy()
        @ObservationIgnored private var bootstrapBuffer = TerminalStreamBootstrapBuffer()
        @ObservationIgnored private var bootstrapAccumulator = TerminalStreamSnapshotAccumulator()
        @ObservationIgnored private var recoveryPolicy = TerminalStreamRecoveryPolicy()
        @ObservationIgnored private var resetAccumulator = TerminalStreamSnapshotAccumulator()
        // Command availability must refresh when an atomic reset starts/ends,
        // even while streamState stays .streaming throughout the reset.
        private var pendingResetState: TerminalStreamMessage.InitialState?

        private var bootstrapDimensions: (width: Int, height: Int)?
        private var bootstrapScrollbackLineLimit = TerminalScrollbackPolicy.defaultLineLimit

        init(paneId: String, fontName: String, fontSize: CGFloat) {
            self.paneId = paneId
            self.fontName = fontName
            self.fontSize = fontSize
        }

        /// Cancel any in-flight key-send chain.
        func cancelPendingKeys() {
            terminalState?.cancelCursorNavigation?()
            keystrokeDebouncer?.cancelAll()
        }

        func voiceInputContext() -> String? {
            terminalState?.makeTextSnapshot?()?.text
        }

        var isReadyForAgentCommand: Bool {
            streamState == .streaming && terminalState != nil && pendingResetState == nil
        }

        func nextStartMode() -> TerminalStreamRecoveryPolicy.StartMode {
            recoveryPolicy.nextStartMode()
        }

        func shouldRetryUnexpectedEnd(isConnected: Bool) -> Bool {
            recoveryPolicy.shouldRetryUnexpectedEnd(isConnected: isConnected)
        }

        var hasInitialState: Bool {
            bootstrapPolicy.hasInitialState
        }

        func willSendStartRequest() {
            bootstrapPolicy.willSendStartRequest()
        }

        func receiveStartAcknowledgement() {
            bootstrapPolicy.receiveStartAcknowledgement()
        }

        /// Starts a fresh attempt and invalidates callbacks from every earlier
        /// attempt. Old terminal contents are discarded because output emitted
        /// while disconnected cannot be safely replayed as incremental chunks.
        func beginAttempt(leaseId: UUID) -> UUID {
            cancelPendingKeys()
            stabilityTask?.cancel()
            bootstrapPolicy.beginAttempt()
            bootstrapBuffer.reset()
            bootstrapAccumulator.cancel()
            cancelPendingReset()
            bootstrapDimensions = nil
            bootstrapScrollbackLineLimit = TerminalScrollbackPolicy.defaultLineLimit
            let id = UUID()
            streamSessionId = id
            activeLeaseId = leaseId
            streamState = .connecting
            terminalState = nil
            error = nil
            return id
        }

        func prepareForReconnect() {
            cancelPendingKeys()
            stabilityTask?.cancel()
            bootstrapPolicy.beginAttempt()
            bootstrapBuffer.reset()
            bootstrapAccumulator.cancel()
            cancelPendingReset()
            bootstrapDimensions = nil
            bootstrapScrollbackLineLimit = TerminalScrollbackPolicy.defaultLineLimit
            streamSessionId = nil
            streamState = .connecting
            terminalState = nil
            error = nil
        }

        func fail(_ error: Error) {
            bootstrapPolicy.beginAttempt()
            bootstrapBuffer.reset()
            bootstrapAccumulator.cancel()
            cancelPendingReset()
            bootstrapDimensions = nil
            bootstrapScrollbackLineLimit = TerminalScrollbackPolicy.defaultLineLimit
            streamState = .error
            self.error = error.localizedDescription
        }

        /// Returns the exact lease this view may need to balance with a Stop.
        func endStreaming() -> UUID? {
            cancelPendingKeys()
            stabilityTask?.cancel()
            bootstrapPolicy.beginAttempt()
            bootstrapBuffer.reset()
            bootstrapAccumulator.cancel()
            cancelPendingReset()
            bootstrapDimensions = nil
            bootstrapScrollbackLineLimit = TerminalScrollbackPolicy.defaultLineLimit
            streamSessionId = nil
            defer { activeLeaseId = nil }
            return recoveryPolicy.hasRequestedStream ? activeLeaseId : nil
        }

        func setHandlerRegistrationId(_ id: UUID) {
            handlerRegistrationId = id
        }

        func takeHandlerRegistrationId() -> UUID? {
            defer { handlerRegistrationId = nil }
            return handlerRegistrationId
        }

        /// Accumulates rapid keystrokes and flushes them as a single command after a short delay.
        func enqueueKeySend(keys: [TmuxKey], relayClient: ViewerRelayClient) {
            terminalState?.cancelCursorNavigation?()
            if keystrokeDebouncer == nil {
                keystrokeDebouncer = KeystrokeDebouncer(paneId: paneId, relayClient: relayClient)
            }
            keystrokeDebouncer?.enqueue(keys)
        }

        /// Forwards raw bytes (e.g., SGR mouse escape sequences) to the host via the relay.
        /// Routes through the same debouncer as keystrokes so order is preserved with
        /// any in-flight typed input.
        func enqueueRawInput(data: Data, relayClient: ViewerRelayClient) {
            terminalState?.cancelCursorNavigation?()
            if keystrokeDebouncer == nil {
                keystrokeDebouncer = KeystrokeDebouncer(paneId: paneId, relayClient: relayClient)
            }
            keystrokeDebouncer?.enqueueRawInput(data)
        }

        func handleStreamMessage(_ message: TerminalStreamMessage) {
            switch message.updateType {
            case let .initialState(initial):
                guard let content = initial.content else { return }
                let expectedByteCount = validSnapshotByteCount(
                    initial.contentByteCount,
                    initialContent: content
                )
                guard bootstrapPolicy.receiveInitialState(
                    snapshotIsComplete: expectedByteCount == nil
                ) else { return }

                bootstrapDimensions = (initial.width, initial.height)
                bootstrapScrollbackLineLimit = TerminalScrollbackPolicy.normalizedLineLimit(
                    initial.scrollbackLineLimit ?? TerminalScrollbackPolicy.defaultLineLimit
                )
                bootstrapBuffer.appendDimensions(cols: initial.width, rows: initial.height)
                if let expectedByteCount {
                    beginBootstrapSnapshot(
                        expectedByteCount: expectedByteCount,
                        initialContent: content
                    )
                } else {
                    bootstrapBuffer.appendData(content)
                }
                revealTerminalIfReady()

            case let .resetState(snapshot):
                guard let content = snapshot.content else { return }
                let scrollbackLineLimit = TerminalScrollbackPolicy.normalizedLineLimit(
                    snapshot.scrollbackLineLimit ?? TerminalScrollbackPolicy.defaultLineLimit
                )
                if streamState == .streaming {
                    if !beginAtomicReset(snapshot, initialContent: content) {
                        applyReset(
                            snapshot,
                            content: content,
                            scrollbackLineLimit: scrollbackLineLimit
                        )
                    }
                } else if bootstrapPolicy.hasInitialState {
                    // A high-water resync is authoritative. Drop bootstrap bytes
                    // that precede it, then preserve later live bytes in order.
                    bootstrapBuffer.reset()
                    bootstrapDimensions = (snapshot.width, snapshot.height)
                    bootstrapScrollbackLineLimit = scrollbackLineLimit
                    bootstrapBuffer.appendDimensions(cols: snapshot.width, rows: snapshot.height)
                    if let expectedByteCount = validSnapshotByteCount(
                        snapshot.contentByteCount,
                        initialContent: content
                    ) {
                        bootstrapPolicy.expectSnapshotCompletion()
                        beginBootstrapSnapshot(
                            expectedByteCount: expectedByteCount,
                            initialContent: content
                        )
                    } else {
                        bootstrapAccumulator.cancel()
                        bootstrapPolicy.receiveSnapshotCompletion()
                        bootstrapBuffer.appendData(content)
                    }
                }

            case let .dataChunk(chunk):
                guard bootstrapPolicy.hasInitialState, let data = chunk.data else { return }
                if bootstrapAccumulator.isCollecting {
                    if let completion = bootstrapAccumulator.append(data) {
                        completeBootstrapSnapshot(completion)
                    }
                    return
                }
                if pendingResetState != nil {
                    if let completion = resetAccumulator.append(data) {
                        completeAtomicReset(completion)
                    }
                    return
                }
                if streamState == .streaming {
                    terminalState?.feed(data)
                } else {
                    bootstrapBuffer.appendData(data)
                }

            case let .dimensionChange(dims):
                guard bootstrapPolicy.hasInitialState else { return }
                if streamState == .streaming {
                    terminalState?.resize(width: dims.width, height: dims.height)
                } else {
                    bootstrapBuffer.appendDimensions(cols: dims.width, rows: dims.height)
                }

            case let .titleChange(change):
                terminalTitle = change.title

            case .notification:
                // Terminal notifications are not displayed on iOS yet
                break

            case let .clipboardUpdate(update):
                pendingClipboardContent = update.content

            case .streamEnd:
                // Only process streamEnd if we're actually streaming.
                // Ignore if we're still connecting - this can happen when the host restarts
                // a stale stream (stops old, starts new) and the streamEnd from the old
                // stream arrives before our new initialState.
                guard streamState == .streaming else { return }
                cancelPendingReset()
                streamState = .ended
            }
        }

        private func validSnapshotByteCount(
            _ advertisedByteCount: Int?,
            initialContent: Data
        ) -> Int? {
            guard
                let advertisedByteCount,
                advertisedByteCount >= initialContent.count
            else { return nil }
            return advertisedByteCount
        }

        private func beginBootstrapSnapshot(
            expectedByteCount: Int,
            initialContent: Data
        ) {
            if let completion = bootstrapAccumulator.begin(expectedByteCount: expectedByteCount) {
                completeBootstrapSnapshot(completion)
            } else if
                !initialContent.isEmpty,
                let completion = bootstrapAccumulator.append(initialContent) {
                completeBootstrapSnapshot(completion)
            }
        }

        private func completeBootstrapSnapshot(
            _ completion: TerminalStreamSnapshotAccumulator.Completion
        ) {
            bootstrapBuffer.appendData(completion.content)
            bootstrapBuffer.appendData(completion.remainder)
            bootstrapPolicy.receiveSnapshotCompletion()
            revealTerminalIfReady()
        }

        /// Starts a reset transaction when the Host advertises its byte
        /// boundary. Older Hosts omit the count and retain the legacy immediate
        /// behavior so mixed-version pairs stay usable.
        private func beginAtomicReset(
            _ snapshot: TerminalStreamMessage.InitialState,
            initialContent: Data
        ) -> Bool {
            guard
                let expectedByteCount = validSnapshotByteCount(
                    snapshot.contentByteCount,
                    initialContent: initialContent
                )
            else {
                cancelPendingReset()
                return false
            }

            pendingResetState = snapshot
            if let completion = resetAccumulator.begin(expectedByteCount: expectedByteCount) {
                completeAtomicReset(completion)
            } else if
                !initialContent.isEmpty,
                let completion = resetAccumulator.append(initialContent) {
                completeAtomicReset(completion)
            }
            return true
        }

        private func completeAtomicReset(
            _ completion: TerminalStreamSnapshotAccumulator.Completion
        ) {
            guard let snapshot = pendingResetState else { return }
            pendingResetState = nil
            let scrollbackLineLimit = TerminalScrollbackPolicy.normalizedLineLimit(
                snapshot.scrollbackLineLimit ?? TerminalScrollbackPolicy.defaultLineLimit
            )
            applyReset(
                snapshot,
                content: completion.content,
                scrollbackLineLimit: scrollbackLineLimit
            )
            if !completion.remainder.isEmpty {
                terminalState?.feed(completion.remainder)
            }
        }

        private func applyReset(
            _ snapshot: TerminalStreamMessage.InitialState,
            content: Data,
            scrollbackLineLimit: Int
        ) {
            terminalState?.replace(
                width: snapshot.width,
                height: snapshot.height,
                content: content,
                scrollbackLineLimit: scrollbackLineLimit
            )
        }

        private func cancelPendingReset() {
            pendingResetState = nil
            resetAccumulator.cancel()
        }

        func revealTerminalIfReady() {
            guard
                bootstrapPolicy.isReady,
                streamState != .streaming,
                let bootstrapDimensions
            else { return }

            let state = TerminalState(
                width: bootstrapDimensions.width,
                height: bootstrapDimensions.height,
                fontName: fontName,
                fontSize: fontSize,
                scrollbackLineLimit: bootstrapScrollbackLineLimit
            )
            state.stageInitialEvents(bootstrapBuffer.takeEvents())
            terminalState = state
            streamState = .streaming
            scheduleStableRecoveryReset()
        }

        private func scheduleStableRecoveryReset() {
            stabilityTask?.cancel()
            guard let streamSessionId else { return }
            stabilityTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard
                    let self,
                    self.streamSessionId == streamSessionId,
                    self.streamState == .streaming
                else { return }
                self.recoveryPolicy.markStreamingStable()
            }
        }
    }

    // MARK: - Stream State

    private enum StreamState {
        case idle
        case connecting
        case streaming
        case ended
        case error
    }

    // MARK: - Terminal State

    /// Manages the terminal state for the streaming view.
    @Observable
    @MainActor
    final class TerminalState {
        private(set) var width: Int
        private(set) var height: Int
        let fontName: String
        let fontSize: CGFloat
        private(set) var scrollbackLineLimit: Int

        /// Bootstrap events retained until the UIKit terminal is wired.
        /// Keeping dimensions between data events preserves terminal parsing
        /// order when the host pane changes size during startup.
        private var pendingInitialEvents: [TerminalStreamBootstrapBuffer.Event] = []
        private var pendingDimensions: (width: Int, height: Int)?

        /// Callback to feed data to the terminal view
        var onData: ((Data) -> Void)?

        /// Callback to atomically reset the existing UIKit terminal instance.
        var onReset: ((Int, Int, Int, Data) -> Void)?

        /// Call after wiring data and resize callbacks to replay the complete
        /// bootstrap into the still-offscreen UIKit terminal.
        func flushPendingContent() {
            guard !pendingInitialEvents.isEmpty, let onData else { return }
            let events = pendingInitialEvents
            pendingInitialEvents = []
            pendingDimensions = nil

            for event in events {
                switch event {
                case let .dimensions(cols, rows):
                    width = cols
                    height = rows
                    onResize?(cols, rows)
                case let .data(data):
                    onData(data)
                }
            }
        }

        /// Callback when dimensions change
        var onResize: ((Int, Int) -> Void)?

        /// Scrolls the terminal to the bottom. Set by UIKit side, callable from SwiftUI.
        var scrollToBottom: (() -> Void)?

        /// Captures the local SwiftTerm buffer without a host or relay request.
        var makeTextSnapshot: (() -> TerminalTextSnapshot?)?

        var cancelCursorNavigation: (() -> Void)?

        init(
            width: Int,
            height: Int,
            fontName: String,
            fontSize: CGFloat,
            scrollbackLineLimit: Int = TerminalScrollbackPolicy.defaultLineLimit
        ) {
            self.width = width
            self.height = height
            self.fontName = fontName
            self.fontSize = fontSize
            self.scrollbackLineLimit = TerminalScrollbackPolicy.normalizedLineLimit(scrollbackLineLimit)
        }

        func stageInitialEvents(_ events: [TerminalStreamBootstrapBuffer.Event]) {
            pendingInitialEvents = events
            pendingDimensions = events.reversed().lazy.compactMap { event in
                if case let .dimensions(cols, rows) = event {
                    return (cols, rows)
                }
                return nil
            }.first
        }

        func feed(_ data: Data) {
            if let onData {
                onData(data)
            } else {
                pendingInitialEvents.append(.data(data))
            }
        }

        func replace(width: Int, height: Int, content: Data, scrollbackLineLimit: Int) {
            self.width = width
            self.height = height
            self.scrollbackLineLimit = TerminalScrollbackPolicy.normalizedLineLimit(scrollbackLineLimit)
            pendingInitialEvents = []
            pendingDimensions = nil
            if let onReset {
                onReset(width, height, self.scrollbackLineLimit, content)
            } else {
                pendingInitialEvents = [
                    .dimensions(cols: width, rows: height),
                    .data(content),
                ]
                pendingDimensions = (width, height)
            }
        }

        func resize(width: Int, height: Int) {
            let current = pendingDimensions ?? (self.width, self.height)
            guard current.width != width || current.height != height else { return }
            if let onResize {
                self.width = width
                self.height = height
                onResize(width, height)
            } else {
                pendingInitialEvents.append(.dimensions(cols: width, rows: height))
                pendingDimensions = (width, height)
            }
        }
    }

    // MARK: - Terminal Container View

    /// UIKit container for the streaming terminal.
    ///
    /// Uses `InteractiveTerminalView` which keeps its shortcut accessory available
    /// independently from the software keyboard.
    private struct TerminalStreamContainerView: UIViewRepresentable {
        let terminalState: TerminalState

        /// Whether this terminal owns the input accessory and accepts input.
        let inputEnabled: Bool

        /// Whether the software keyboard should be visible below the accessory.
        let keyboardRequested: Bool

        /// Callback when user types (keys are ready for relay transmission)
        let onInput: @MainActor ([TmuxKey]) -> Void

        /// Callback for raw escape sequences (e.g., SGR mouse events) ready for relay transmission
        let onRawInput: @MainActor (Data) -> Void

        func makeUIView(context: Context) -> UIScrollView {
            // Calculate cell size using FontMetrics (matches SwiftTerm's computeFontDimensions)
            let cellSize = FontMetrics.calculateCellSize(
                fontName: terminalState.fontName,
                fontSize: terminalState.fontSize
            )

            let exactWidth = CGFloat(terminalState.width) * cellSize.width + FontMetrics.horizontalBuffer
            let exactHeight = CGFloat(terminalState.height) * cellSize.height

            // Create font
            let font = UIFont(name: terminalState.fontName, size: terminalState.fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: terminalState.fontSize, weight: .regular)

            // Create interactive terminal view
            let initialFrame = CGRect(x: 0, y: 0, width: exactWidth, height: exactHeight)
            let terminalView = InteractiveTerminalView(frame: initialFrame, font: font)
            terminalView.changeScrollback(terminalState.scrollbackLineLimit)
            terminalView.translatesAutoresizingMaskIntoConstraints = false

            // Configure terminal
            terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = UIColor.black
            terminalView.isScrollEnabled = true
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []

            // Wire up input callback
            terminalView.onInput = onInput
            terminalView.onRawInput = onRawInput

            // Create an outer scroll view and a passive canvas. The canvas may
            // grow to fill the phone, but the SwiftTerm view itself must always
            // retain the Host's exact pixel dimensions; resizing the terminal
            // renderer to fill the viewport silently changes its rows/columns.
            let scrollView = BottomAnchoredTerminalScrollView()
            scrollView.backgroundColor = .black
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
            // Lock to one axis once a drag direction is established so a
            // horizontal scroll can't accidentally start scrolling vertically
            // when the user's finger drifts off-axis mid-pan. Diagonal initial
            // drags fall through to the coordinator's stricter mouse-mode lock.
            scrollView.isDirectionalLockEnabled = true
            scrollView.delegate = context.coordinator
            context.coordinator.outerScrollView = scrollView

            let canvasView = UIView()
            canvasView.backgroundColor = .black
            canvasView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(canvasView)
            canvasView.addSubview(terminalView)

            // Let our mouse-mode pan win over tall-terminal vertical scrolling.
            terminalView.attachOuterScrollPanGesture(scrollView.panGestureRecognizer)
            terminalView.attachInputProxy(to: scrollView)

            let widthConstraint = terminalView.widthAnchor.constraint(equalToConstant: exactWidth)
            let heightConstraint = terminalView.heightAnchor.constraint(equalToConstant: exactHeight)

            let canvasMatchesViewportWidth = canvasView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            )
            canvasMatchesViewportWidth.priority = .defaultHigh
            let canvasMatchesTerminalWidth = canvasView.widthAnchor.constraint(
                equalTo: terminalView.widthAnchor
            )
            canvasMatchesTerminalWidth.priority = .defaultHigh
            let canvasMatchesViewportHeight = canvasView.heightAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.heightAnchor
            )
            canvasMatchesViewportHeight.priority = .defaultHigh
            let canvasMatchesTerminalHeight = canvasView.heightAnchor.constraint(
                equalTo: terminalView.heightAnchor
            )
            canvasMatchesTerminalHeight.priority = .defaultHigh

            NSLayoutConstraint.activate([
                canvasView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                canvasView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                canvasView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                canvasView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                canvasView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
                canvasView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
                canvasView.widthAnchor.constraint(greaterThanOrEqualTo: terminalView.widthAnchor),
                canvasView.heightAnchor.constraint(greaterThanOrEqualTo: terminalView.heightAnchor),
                canvasMatchesViewportWidth,
                canvasMatchesTerminalWidth,
                canvasMatchesViewportHeight,
                canvasMatchesTerminalHeight,
                terminalView.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
                terminalView.trailingAnchor.constraint(lessThanOrEqualTo: canvasView.trailingAnchor),
                terminalView.topAnchor.constraint(greaterThanOrEqualTo: canvasView.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor),
                widthConstraint,
                heightConstraint,
            ])

            // Store references
            context.coordinator.terminalView = terminalView
            context.coordinator.terminalState = terminalState
            context.coordinator.cellSize = cellSize
            context.coordinator.widthConstraint = widthConstraint
            context.coordinator.heightConstraint = heightConstraint

            // Wire up data callbacks
            terminalState.onData = { [weak coordinator = context.coordinator] data in
                coordinator?.enqueue(data)
            }
            terminalState.onReset = { [weak coordinator = context.coordinator] width, height, lineLimit, data in
                coordinator?.replace(
                    width: width,
                    height: height,
                    scrollbackLineLimit: lineLimit,
                    content: data
                )
            }
            terminalState.onResize = { [weak coordinator = context.coordinator] newWidth, newHeight in
                coordinator?.resizeAfterPendingFeed(width: newWidth, height: newHeight)
            }

            // Scroll both the inner terminal (scrollback) and outer scroll view
            // (tall terminal overflow) to the bottom.
            terminalState.scrollToBottom = { [weak terminalView, weak scrollView] in
                guard let terminalView else { return }
                // Inner: scroll SwiftTerm's scrollback to bottom
                terminalView.scrollToBottom()
                // Outer: keep the cursor/prompt anchored through the next real
                // UIKit layout, including safe-area and keyboard changes.
                scrollView?.requestScrollToBottom()
            }

            // Parse the complete bootstrap before returning the native view.
            // UIKit cannot display intermediate terminal states while makeUIView
            // is still executing, which removes the visible replay/flicker.
            terminalState.flushPendingContent()
            context.coordinator.flushPendingFeedNow()

            terminalState.makeTextSnapshot = { [weak terminalView] in
                terminalView?.makeTextSnapshot()
            }
            terminalState.cancelCursorNavigation = { [weak terminalView] in
                terminalView?.cancelCursorNavigation()
            }

            // Record input intent and request the initial native tail reveal.
            // Focus is deferred; the bottom anchor follows later inset changes.
            context.coordinator.finishInitialPresentation(
                scrollView: scrollView,
                inputEnabled: inputEnabled,
                keyboardRequested: keyboardRequested
            )

            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            guard let terminalView = context.coordinator.terminalView else { return }

            // A UIViewRepresentable may outlive many value-type SwiftUI views.
            // Refresh callbacks on every update so the native terminal never
            // sends through the host, pane, or monitoring state captured by its
            // first render.
            terminalView.onInput = onInput
            terminalView.onRawInput = onRawInput

            context.coordinator.updateInteraction(
                inputEnabled: inputEnabled,
                keyboardRequested: keyboardRequested
            )
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
            coordinator.terminalView?.invalidateInput()
        }

        @MainActor
        final class Coordinator: NSObject, UIScrollViewDelegate {
            var terminalView: InteractiveTerminalView?
            weak var terminalState: TerminalState?
            weak var outerScrollView: BottomAnchoredTerminalScrollView?
            var cellSize: CGSize = .zero
            var widthConstraint: NSLayoutConstraint?
            var heightConstraint: NSLayoutConstraint?

            /// Y offset captured at the start of a user drag. Used to lock
            /// vertical scrolling while mouse mode is active — vertical pans
            /// belong to `mouseModePanGesture` (wheel events), so the outer
            /// scroll view should only scroll horizontally during mouse mode.
            /// Diagonal drags would otherwise scroll both axes once the outer
            /// scroll view picks them up (`isDirectionalLockEnabled` doesn't
            /// engage for diagonal starts per Apple's documented behavior).
            private var dragInitialOffsetY: CGFloat?

            private lazy var feedCoalescer = TerminalFeedCoalescer(
                id: "ios:\(ObjectIdentifier(self))"
            ) { [weak self] data in
                guard let terminalView = self?.terminalView else { return }
                terminalView.feedTerminalData([UInt8](data)[...])
            }

            func enqueue(_ data: Data) {
                feedCoalescer.enqueue(data)
            }

            func flushPendingFeedNow() {
                feedCoalescer.flushPendingNow()
            }

            func replace(width: Int, height: Int, scrollbackLineLimit: Int, content: Data) {
                terminalView?.cancelCursorNavigation()
                terminalView?.changeScrollback(scrollbackLineLimit)
                handleResize(width: width, height: height)
                feedCoalescer.replace(with: content) { [weak self] in
                    self?.terminalView?.getTerminal().resetToInitialState()
                }
                terminalView?.scrollToBottom()
                outerScrollView?.requestScrollToBottom()
                terminalView?.setNeedsLayout()
                if let terminalView {
                    terminalView.setNeedsDisplay(terminalView.bounds)
                }
            }

            func handleResize(width: Int, height: Int) {
                guard let terminalView else { return }
                terminalView.cancelCursorNavigation()

                // Constraints update the outer geometry on the next layout
                // pass. Resize SwiftTerm now so following bootstrap bytes are
                // parsed with the dimensions that preceded them on the wire.
                // SwiftTerm also synchronizes its native scroll offset after
                // that layout, even when these rows/columns already match. Do
                // not resize again or force history to the tail from layout.
                terminalView.getTerminal().resize(cols: width, rows: height)

                let newWidth = CGFloat(width) * cellSize.width + FontMetrics.horizontalBuffer
                widthConstraint?.constant = newWidth

                let newHeight = CGFloat(height) * cellSize.height
                heightConstraint?.constant = newHeight
            }

            /// A dimension message is ordered relative to terminal bytes. Drain
            /// earlier bytes before applying the new geometry.
            func resizeAfterPendingFeed(width: Int, height: Int) {
                feedCoalescer.flushPendingNow()
                handleResize(width: width, height: height)
            }

            func finishInitialPresentation(
                scrollView: BottomAnchoredTerminalScrollView,
                inputEnabled: Bool,
                keyboardRequested: Bool
            ) {
                updateInteraction(
                    inputEnabled: inputEnabled,
                    keyboardRequested: keyboardRequested
                )

                // Focus is applied asynchronously outside SwiftUI's update.
                // The native bottom anchor follows the later accessory/inset
                // change, independently of this one-time initial tail reveal.
                scrollView.requestInitialTailPresentation { [weak terminalView] in
                    terminalView?.presentCurrentTail()
                }
            }

            func updateInteraction(inputEnabled: Bool, keyboardRequested: Bool) {
                terminalView?.updateInput(
                    isEnabled: inputEnabled,
                    keyboardRequested: keyboardRequested
                )
            }

            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                dragInitialOffsetY = scrollView.contentOffset.y
                (scrollView as? BottomAnchoredTerminalScrollView)?.userWillBeginScrolling()
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                guard
                    scrollView.isDragging || scrollView.isDecelerating,
                    let initialY = dragInitialOffsetY,
                    terminalView?.isMouseModeActive == true,
                    scrollView.contentOffset.y != initialY
                else { return }
                scrollView.contentOffset.y = initialY
            }

            func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
                dragInitialOffsetY = nil
                (scrollView as? BottomAnchoredTerminalScrollView)?.userDidEndScrolling()
            }

            func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
                if !decelerate {
                    dragInitialOffsetY = nil
                    (scrollView as? BottomAnchoredTerminalScrollView)?.userDidEndScrolling()
                }
            }
        }
    }

    /// UIScrollView does not preserve a bottom content offset when its viewport
    /// height changes. Follow the terminal tail across every automatic layout
    /// until a real user drag takes ownership of the viewport.
    private final class BottomAnchoredTerminalScrollView: UIScrollView {
        private var anchorPolicy = TerminalBottomAnchorPolicy()
        private var initialPresentationPolicy = TerminalInitialTailPresentationPolicy()
        private var initialTailPresentation: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            setNeedsLayout()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            anchorToBottomIfNeeded()
        }

        override func adjustedContentInsetDidChange() {
            super.adjustedContentInsetDidChange()
            anchorToBottomIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            if initialPresentationPolicy.consumeIfReady(
                isAttachedToWindow: window != nil,
                hasUsableBounds: bounds.width > 0 && bounds.height > 0
            ) {
                let presentation = initialTailPresentation
                initialTailPresentation = nil
                presentation?()
            }

            anchorToBottomIfNeeded()
        }

        func requestInitialTailPresentation(_ presentation: @escaping () -> Void) {
            initialTailPresentation = presentation
            initialPresentationPolicy.request()
            requestScrollToBottom()
        }

        private func anchorToBottomIfNeeded() {
            guard let targetOffset = anchorPolicy.targetOffset(
                maximumOffset: Double(bottomOffset)
            ) else {
                return
            }
            let targetY = CGFloat(targetOffset)
            guard abs(contentOffset.y - targetY) > CGFloat(TerminalBottomAnchorPolicy.tolerance) else {
                return
            }
            contentOffset.y = targetY
        }

        func requestScrollToBottom() {
            anchorPolicy.requestScrollToBottom()
            setNeedsLayout()
            if window != nil, bounds.width > 0, bounds.height > 0 {
                anchorToBottomIfNeeded()
            }
        }

        func userWillBeginScrolling() {
            anchorPolicy.userWillBeginScrolling()
        }

        func userDidEndScrolling() {
            anchorPolicy.userDidEndScrolling(
                currentOffset: Double(contentOffset.y),
                maximumOffset: Double(bottomOffset)
            )
        }

        /// UIScrollView offsets include automatically adjusted safe-area and
        /// keyboard insets. Ignoring them leaves the last terminal rows hidden
        /// even when the raw content-size calculation appears to be at bottom.
        private var bottomOffset: CGFloat {
            max(
                -adjustedContentInset.top,
                contentSize.height - bounds.height + adjustedContentInset.bottom
            )
        }
    }

    // MARK: - Preview

    #Preview("Live Terminal") {
        let settings = IOSSettings()
        NavigationStack {
            LiveTerminalView(
                paneId: "%1",
                responseState: .init(get: { nil }, set: { _ in }),
                terminalTitle: .init(get: { nil }, set: { _ in }),
                isConnected: true,
                settings: settings,
                submitResponse: { _ in }
            )
        }
        .environment(ViewerRelayClient())
        .environment(settings)
    }
#endif
