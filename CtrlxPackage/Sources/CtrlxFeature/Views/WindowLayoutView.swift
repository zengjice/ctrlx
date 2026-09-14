#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import SwiftUI

    /// Renders a multi-pane tmux window on iOS.
    ///
    /// Parses the window's layout string using `TmuxLayoutParser` to arrange
    /// `LiveTerminalView` instances in the correct split arrangement,
    /// matching the macOS `WindowPaneLayoutView`.
    struct WindowLayoutView: View {
        let sessionName: String
        let hostId: String
        let relayClient: ViewerRelayClient
        let settings: IOSSettings

        @Environment(SessionStore.self) private var sessionStore
        @Environment(AgentBackgroundMonitoringService.self) private var backgroundMonitoring
        @Environment(\.dismiss) private var dismiss

        /// The currently selected window within the session
        @State private var selectedWindowId: String?

        /// The currently selected pane (receives keyboard input)
        @State private var activePaneId: String?

        /// Whether the software keyboard is requested for the selected pane.
        /// Terminal shortcuts remain available when this is false.
        @State private var isKeyboardActive: Bool

        /// Ordered sender for partial speech-recognition edits to the selected pane.
        @State private var voiceKeystrokeDebouncer: KeystrokeDebouncer?
        @State private var voiceKeystrokePaneId: String?
        @State private var voiceInputContextProviders: [String: TerminalVoiceInputContextProvider] = [:]
        @State private var cursorNavigationCancellations: [String: @MainActor () -> Void] = [:]
        @State private var terminalInputReadiness: [String: @MainActor () -> Bool] = [:]
        @State private var agentCommandInputRevision: UInt64 = 0

        /// Service for the active pane's Claude session (nil if no session)
        @State private var activeService: SessionDetailService?

        /// Whether to show the session info popover
        @State private var showSessionInfo = false

        /// Guards against double-splits from rapid taps
        @State private var isSplitting = false

        /// Width of the navigation bar (measured from the full-width content
        /// area). Used to cap the centered title so it doesn't bleed behind the
        /// bar buttons — see `principalTitleMaxWidth`.
        @State private var barWidth: CGFloat = 0

        /// Terminal titles detected via OSC escape sequences, keyed by pane ID
        @State private var terminalTitles: [String: String] = [:]

        /// Latest clipboard content from each pane, keyed by pane ID
        @State private var clipboardContents: [String: String] = [:]

        /// The last value this view wrote to the system pasteboard.
        ///
        /// Used to dedupe redundant writes when `clipboardContents` republishes
        /// the same value. Reading the clipboard back to compare would trigger
        /// iOS's paste-permission prompt whenever a different process owns the
        /// pasteboard, so we track the last write locally instead.
        @State private var lastWrittenClipboardContent: String?

        /// Tracks app foreground state for clipboard sync
        @Environment(\.scenePhase) private var scenePhase

        @Dependency(ClipboardClient.self) private var clipboard

        /// Close confirmation state for showing alert with running processes
        @State private var closeConfirmation: CloseConfirmation?

        /// Error message from failed commands (close window/session)
        @State private var commandError: String?

        /// Rename-window alert state: the window being renamed (if any).
        @State private var renamingWindow: TmuxWindow?

        /// Text bound to the rename-window alert field.
        @State private var renameWindowText = ""

        init(
            sessionName: String,
            hostId: String,
            relayClient: ViewerRelayClient,
            settings: IOSSettings
        ) {
            self.sessionName = sessionName
            self.hostId = hostId
            self.relayClient = relayClient
            self.settings = settings
            self._isKeyboardActive = State(initialValue: settings.showTerminalKeyboardOnEntry)
        }

        /// All windows in this session
        private var sessionWindows: [TmuxWindow] {
            sessionStore.windows(for: hostId).filter { $0.sessionName == sessionName }
                .sorted { $0.windowIndex < $1.windowIndex }
        }

        private var windowSelectionCandidates: [WindowSelectionCandidate] {
            sessionWindows.map { window in
                WindowSelectionCandidate(
                    windowId: window.id,
                    paneId: window.activePane?.paneId ?? window.panes.first?.paneId,
                    isActive: window.isWindowActive
                )
            }
        }

        /// The current window data from the session store
        private var window: TmuxWindow? {
            if let selectedWindowId {
                return sessionStore.window(id: selectedWindowId, hostId: hostId)
            }
            // Default to the active window in the session
            return sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first
        }

        /// Use the displayed window's name, matching the window switcher.
        /// Keep the session name only while window data is unavailable.
        private var navigationTitle: String {
            guard let window else { return sessionName }
            return windowTabLabel(for: window)
        }

        /// Upper bound for the centered title in the navigation bar.
        ///
        /// SwiftUI sizes a `.principal` toolbar item to its intrinsic width and
        /// centers it, so a long title must be explicitly capped or it draws
        /// behind the leading back button and the trailing toolbar buttons
        /// (#600). Reserve room on each side for the circular bar buttons (and
        /// their insets); the title then truncates with a trailing ellipsis.
        /// Returns `nil` until the width is measured, leaving the title uncapped
        /// for that first layout pass.
        private var principalTitleMaxWidth: CGFloat? {
            guard barWidth > 0 else { return nil }
            // ~44pt circular bar button hit area + ~28pt inset on each side.
            // May need tuning if button sizes change or on iPad slide-over.
            let reservedPerSide: CGFloat = 72
            return max(120, barWidth - reservedPerSide * 2)
        }

        var body: some View {
            Group {
                if let window {
                    windowContent(window)
                } else {
                    ContentUnavailableView(
                        "Window Not Found",
                        symbol: .exclamationmarkTriangle,
                        description: "This window may have been closed."
                    )
                }
            }
            // Measure the full-width content area to learn the navigation bar's
            // width, which `principalTitleMaxWidth` uses to keep a long title
            // from overflowing behind the bar buttons.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
                barWidth = newWidth
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if window != nil, settings.terminalKeyboardControlPosition == .bottomBar {
                    TerminalKeyboardBar(
                        keyboardRequested: isKeyboardActive,
                        isEnabled: relayClient.isHostConnected && activePaneId != nil,
                        action: { isKeyboardActive.toggle() },
                        contextProvider: activeVoiceInputContext,
                        sendKeys: sendVoiceKeys,
                        agentCommandContext: activeAgentCommandContext,
                        sendAgentCommand: sendAgentCommand
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Window switcher as title menu (placement: .principal replaces the title)
                ToolbarItem(placement: .principal) {
                    Menu {
                        let windows = sessionWindows
                        ForEach(windows) { win in
                            Button {
                                selectedWindowId = win.id
                                activePaneId = win.activePane?.paneId ?? win.panes.first?.paneId
                                Task {
                                    await sendCommand(.selectTmuxWindow, paneId: win.id)
                                }
                            } label: {
                                if win.id == (selectedWindowId ?? window?.id) {
                                    Label(windowTabLabel(for: win), symbol: .checkmark)
                                } else {
                                    Text(windowTabLabel(for: win))
                                }
                            }
                        }

                        Divider()

                        Button {
                            Task {
                                let workingDir = window?.activePane?.currentPath
                                let spec = CreateTmuxWindow(sessionName: sessionName, workingDirectory: workingDir)
                                let result = await relayClient.sendCommand(spec, paneId: "")
                                if case let .success(response) = result, let paneId = response.paneId {
                                    await relayClient.requestSessionState()
                                    try? await Task.sleep(for: .milliseconds(500))
                                    if let newWindow = sessionWindows.first(where: { $0.panes.contains(where: { $0.paneId == paneId }) }) {
                                        selectedWindowId = newWindow.id
                                        activePaneId = paneId
                                    }
                                }
                            }
                        } label: {
                            Label("New Window", symbol: .plus)
                        }
                        .disabled(!relayClient.isHostConnected)

                        if let window {
                            Button {
                                renameWindowText = window.windowName
                                renamingWindow = window
                            } label: {
                                Label("Rename Window", symbol: .pencil)
                            }
                            .disabled(!relayClient.isHostConnected)
                        }

                        if let window, sessionWindows.count > 1 {
                            Divider()

                            Button(role: .destructive) {
                                requestCloseWindow(window)
                            } label: {
                                Label("Close Window", symbol: .rectangleBadgeMinus)
                            }
                            .disabled(!relayClient.isHostConnected)
                        }

                        Divider()

                        Button(role: .destructive) {
                            requestCloseSession()
                        } label: {
                            Label("Close Session", symbol: .rectangleStackBadgeMinus)
                        }
                        .disabled(!relayClient.isHostConnected)
                    } label: {
                        HStack(spacing: 4) {
                            Text(navigationTitle)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Symbols.chevronDown.image
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        // Cap the centered title so a long one truncates instead
                        // of bleeding behind the bar buttons (#600).
                        .frame(maxWidth: principalTitleMaxWidth)
                    }
                }
                if settings.terminalKeyboardControlPosition == .topRight {
                    ToolbarItem(placement: .topBarTrailing) {
                        TerminalVoiceInputButton(
                            isDisabled: !relayClient.isHostConnected || activePaneId == nil,
                            contextProvider: activeVoiceInputContext,
                            sendKeys: sendVoiceKeys
                        )
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isKeyboardActive.toggle()
                        } label: {
                            Label(
                                isKeyboardActive ? "Hide Keyboard" : "Show Keyboard",
                                symbol: isKeyboardActive ? .keyboardChevronCompactDown : .keyboard
                            )
                        }
                        .disabled(!relayClient.isHostConnected || activePaneId == nil)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    ImageUploadToolbarButton(
                        paneId: activePaneId,
                        relayClient: relayClient
                    )
                }

                if let activeService, activeService.session != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                let newValue = !activeService.isYoloModeEnabled
                                Task {
                                    await activeService.sendCommand(.setYoloMode(enabled: newValue))
                                }
                            } label: {
                                Label(
                                    activeService.isYoloModeEnabled ? "Disable Yolo Mode" : "Enable Yolo Mode",
                                    symbol: .bolt
                                )
                            }

                            Button {
                                showSessionInfo = true
                            } label: {
                                Label("Session Info", symbol: .infoCircle)
                            }
                            .tint(nil)
                        } label: {
                            Label("Commands", symbol: .ellipsisCircle)
                        }
                        .tint(activeService.isYoloModeEnabled ? .red : nil)
                        .popover(isPresented: $showSessionInfo) {
                            sessionInfoPopover
                        }
                    }
                }
            }
            .alert(
                closeConfirmation?.title ?? "Close?",
                isPresented: .init(
                    get: { closeConfirmation != nil },
                    set: { if !$0 { closeConfirmation = nil } }
                )
            ) {
                if let confirmation = closeConfirmation {
                    Button("Close Anyway", role: .destructive) {
                        switch confirmation.target {
                        case let .window(window):
                            performCloseWindow(window)
                        case .session:
                            performCloseSession()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Cancel", role: .cancel) { closeConfirmation = nil }
            } message: {
                if let confirmation = closeConfirmation {
                    Text(confirmation.message)
                }
            }
            .alert("Error", isPresented: .init(
                get: { commandError != nil },
                set: { if !$0 { commandError = nil } }
            )) {
                Button("OK") { commandError = nil }
            } message: {
                if let error = commandError {
                    Text(error)
                }
            }
            // Intentionally inline rather than using `WindowRenamingModifier`:
            // iOS attaches rename via a `Menu` inside the tab (see WindowTabBar),
            // not a `contextMenu`, so the alert lives on the enclosing view and
            // `renamingWindow`/`renameWindowText` bridge the Menu tap to it.
            .alert("Rename Window", isPresented: .init(
                get: { renamingWindow != nil },
                set: { if !$0 { renamingWindow = nil } }
            )) {
                TextField("Window Name", text: $renameWindowText)
                Button("Save") {
                    let trimmed = renameWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let target = renamingWindow, !trimmed.isEmpty {
                        Task {
                            _ = await relayClient.sendCommand(
                                SetWindowName(windowId: target.id, name: trimmed),
                                paneId: ""
                            )
                        }
                    }
                    renamingWindow = nil
                }
                Button("Cancel", role: .cancel) { renamingWindow = nil }
            } message: {
                Text("Enter a new name for this window")
            }
            .task {
                updateActiveService()
                // Mark session as handled when navigating into the view
                await activeService?.markHandledIfNeeded()
            }
            .task(id: windowSelectionCandidates) {
                reconcileWindowSelection(candidates: windowSelectionCandidates)
            }
            .onChange(of: activeService?.session?.state) {
                if activeSessionHasBlockingForm {
                    isKeyboardActive = false
                }
                if activeService?.session?.needsAttention == true {
                    Task { await activeService?.markHandledIfNeeded() }
                }
            }
            .onChange(of: clipboardContents) {
                guard
                    let activePaneId,
                    let content = clipboardContents[activePaneId],
                    scenePhase == .active,
                    content != lastWrittenClipboardContent
                else { return }
                clipboard.setString(content)
                lastWrittenClipboardContent = content
            }
            .onChange(of: activePaneId) { oldValue, newValue in
                agentCommandInputRevision &+= 1
                voiceKeystrokeDebouncer?.cancelAll()
                voiceKeystrokeDebouncer = nil
                voiceKeystrokePaneId = nil
                updateActiveService()
                // Mark session as handled when switching to a pane with attention
                Task { await activeService?.markHandledIfNeeded() }
                // Sync pane selection to the tmux session on the host.
                // When oldValue is nil, it's the initial assignment from onAppear
                // — skip it to avoid redirecting the host's tmux focus on load.
                guard oldValue != nil, let newValue else { return }
                Task {
                    await sendCommand(.selectTmuxPane, paneId: newValue)
                }
            }
            .onDisappear {
                voiceKeystrokeDebouncer?.cancelAll()
            }
        }

        private func reconcileWindowSelection(candidates: [WindowSelectionCandidate]) {
            let decision = WindowSelectionReconciliation.resolve(
                selectedWindowId: selectedWindowId,
                candidates: candidates
            )

            switch decision {
            case .unchanged:
                return

            case let .select(windowId, paneId):
                selectedWindowId = windowId
                activePaneId = paneId
            }
        }

        private func windowContent(_ window: TmuxWindow) -> some View {
            VStack(spacing: 0) {
                // Response view for active pane's Claude session (full width, above layout)
                if
                    let activeService,
                    let responseState = activeService.responseState,
                    AgentInputPresentation.showsResponseForm(
                        isBlocking: responseState.request.isBlocking,
                        quickInputEnabled: settings.agentQuickInputEnabled,
                        keyboardActive: isKeyboardActive
                    ) {
                    responseState.request.responseView(
                        isConnected: relayClient.isHostConnected,
                        submit: { response in
                            let shouldMonitor = settings.agentBackgroundMonitoringEnabled
                                && AgentBackgroundMonitoringPolicy.shouldStart(for: response)
                            if shouldMonitor {
                                backgroundMonitoring.startIfNeeded(
                                    for: response,
                                    hostId: hostId,
                                    paneId: activeService.paneId,
                                    sessionName: sessionName,
                                    windowName: window.windowName
                                )
                            }
                            let succeeded = await activeService.submitResponse(
                                response,
                                pluginID: responseState.pluginID,
                                requestID: responseState.requestID
                            )
                            if !succeeded, shouldMonitor {
                                backgroundMonitoring.removePane(
                                    hostId: hostId,
                                    paneId: activeService.paneId
                                )
                            }
                        },
                        state: responseState
                    )
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    // Preserve blocking forms for their request lifetime, but
                    // give each synthesized reply turn a fresh TextField.
                    .id(responseState.viewIdentity)

                    Divider()
                }

                if let layout = TmuxLayoutParser.parse(window.windowLayout) {
                    tiledLayout(window: window, layout: layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    statusBar(window)
                } else {
                    // Fallback: list panes vertically if layout parsing fails
                    VStack(spacing: 1) {
                        ForEach(window.panes) { pane in
                            paneTerminal(pane: pane, windowName: window.windowName)
                        }
                    }
                }
            }
        }

        // MARK: - Tiled Layout

        private func tiledLayout(window: TmuxWindow, layout: LayoutNode) -> some View {
            let totalWidth = CGFloat(layout.width)
            let totalHeight = CGFloat(layout.height)
            var positioned: [PositionedPaneState] = []
            flattenNode(
                layout, window: window, origin: .zero,
                totalWidth: totalWidth, totalHeight: totalHeight,
                into: &positioned
            )
            let isMultiPane = positioned.count > 1

            return ProportionalTileLayout(rects: positioned.map(\.rect)) {
                ForEach(positioned) { pane in
                    let isSelected = pane.id == activePaneId
                    paneTerminal(pane: pane.paneState, windowName: window.windowName)
                        .overlay {
                            if isMultiPane {
                                // Border: accent for selected, subtle for others
                                Rectangle()
                                    .strokeBorder(
                                        isSelected ? Color.accentColor : Color.white.opacity(0.3),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            }
                            // Transparent tap target for non-active panes.
                            // UIKit terminal views absorb touches, so this overlay
                            // intercepts taps to allow pane selection.
                            if !isSelected && isMultiPane {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        activePaneId = pane.id
                                    }
                            }
                        }
                }
            }
        }

        private func flattenNode(
            _ node: LayoutNode,
            window: TmuxWindow,
            origin: CGPoint,
            totalWidth: CGFloat,
            totalHeight: CGFloat,
            into result: inout [PositionedPaneState]
        ) {
            switch node {
            case let .pane(id, width, height):
                let paneIdString = "%\(id)"
                if let paneState = window.panes.first(where: { $0.paneId == paneIdString }) {
                    let rect = CGRect(
                        x: origin.x,
                        y: origin.y,
                        width: CGFloat(width) / totalWidth,
                        height: CGFloat(height) / totalHeight
                    )
                    result.append(PositionedPaneState(id: paneIdString, paneState: paneState, rect: rect))
                }

            case let .horizontal(children, _, _):
                var xOffset = origin.x
                for child in children {
                    flattenNode(
                        child, window: window,
                        origin: CGPoint(x: xOffset, y: origin.y),
                        totalWidth: totalWidth, totalHeight: totalHeight,
                        into: &result
                    )
                    xOffset += CGFloat(child.width) / totalWidth
                }

            case let .vertical(children, _, _):
                var yOffset = origin.y
                for child in children {
                    flattenNode(
                        child, window: window,
                        origin: CGPoint(x: origin.x, y: yOffset),
                        totalWidth: totalWidth, totalHeight: totalHeight,
                        into: &result
                    )
                    yOffset += CGFloat(child.height) / totalHeight
                }
            }
        }

        // MARK: - Pane Terminal

        private func paneTerminal(pane: PaneState, windowName: String) -> some View {
            LiveTerminalView(
                paneId: pane.paneId,
                responseState: .constant(nil),
                terminalTitle: Binding(
                    get: { terminalTitles[pane.paneId] },
                    set: { terminalTitles[pane.paneId] = $0 }
                ),
                clipboardContent: Binding(
                    get: { clipboardContents[pane.paneId] },
                    set: { clipboardContents[pane.paneId] = $0 }
                ),
                isConnected: relayClient.isHostConnected,
                hideNavigationBar: false,
                showKeyboardButton: false,
                showCopyButton: pane.paneId == activePaneId,
                isActive: pane.paneId == activePaneId,
                parentKeyboardRequested: isKeyboardActive,
                settings: settings,
                telemetry: pane.telemetry,
                // Tiled panes pass `responseState: .constant(nil)`, so no response
                // form is shown here and the submit closure is never invoked.
                submitResponse: { _ in },
                onTerminalInput: { keys in
                    observeTerminalInput(
                        keys,
                        paneId: pane.paneId,
                        windowName: windowName
                    )
                },
                onVoiceInputContextProviderChange: { provider in
                    if let provider {
                        voiceInputContextProviders[pane.paneId] = provider
                    } else {
                        voiceInputContextProviders.removeValue(forKey: pane.paneId)
                    }
                },
                onCursorNavigationCancellationChange: { cancellation in
                    cursorNavigationCancellations[pane.paneId] = cancellation
                },
                onTerminalInputReadinessChange: { readiness in
                    terminalInputReadiness[pane.paneId] = readiness
                }
            )
            .environment(relayClient)
        }

        private func observeTerminalInput(
            _ keys: [TmuxKey],
            paneId: String,
            windowName: String
        ) {
            agentCommandInputRevision &+= 1
            guard
                settings.agentBackgroundMonitoringEnabled,
                relayClient.isHostConnected
            else {
                backgroundMonitoring.resetTerminalInput(
                    hostId: hostId,
                    paneId: paneId
                )
                return
            }

            backgroundMonitoring.handleTerminalInput(
                keys,
                hostId: hostId,
                paneId: paneId,
                sessionName: sessionName,
                windowName: windowName,
                currentState: sessionStore.session(for: paneId, hostId: hostId)?.state
            )
        }

        // MARK: - Status Bar

        private func statusBar(_ window: TmuxWindow) -> some View {
            HStack {
                Text("\(window.sessionName):\(window.windowIndex)")
                    .font(.system(.caption, design: .monospaced))

                if window.panes.count > 1 {
                    Divider()
                        .frame(height: 12)

                    Text("\(window.panes.count) panes")
                }

                Spacer()

                tmuxControls
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }

        // MARK: - Tmux Controls

        private var tmuxControls: some View {
            HStack(spacing: 12) {
                // Send tmux prefix key (Ctrl+B)
                Button {
                    guard let activePaneId else { return }
                    Task {
                        await sendCommand(.sendKeystroke([.ctrl("b")]), paneId: activePaneId)
                    }
                } label: {
                    Label("Tmux Prefix", symbol: .terminal)
                }

                // Split pane horizontally (left-right)
                Button {
                    guard let activePaneId, !isSplitting else { return }
                    isSplitting = true
                    Task {
                        await sendCommand(.splitTmuxPane(direction: .horizontal), paneId: activePaneId)
                        isSplitting = false
                    }
                } label: {
                    Label("Split Horizontal", symbol: .rectangleSplit2x1Fill)
                }

                // Split pane vertically (top-bottom)
                Button {
                    guard let activePaneId, !isSplitting else { return }
                    isSplitting = true
                    Task {
                        await sendCommand(.splitTmuxPane(direction: .vertical), paneId: activePaneId)
                        isSplitting = false
                    }
                } label: {
                    Label("Split Vertical", symbol: .rectangleSplit1x2Fill)
                }
            }
            .labelStyle(.iconOnly)
            .disabled(!relayClient.isHostConnected || activePaneId == nil)
        }

        // MARK: - Active Pane Service

        private var activeSessionHasBlockingForm: Bool {
            activeService?.session?.state.openForm?.request.isBlocking == true
        }

        /// Creates or clears the SessionDetailService when the active pane changes
        private func updateActiveService() {
            guard let activePaneId else {
                activeService = nil
                return
            }
            // Only recreate if the pane changed
            if activeService?.paneId != activePaneId {
                activeService = SessionDetailService(
                    paneId: activePaneId,
                    hostId: hostId,
                    sessionStore: sessionStore,
                    relayClient: relayClient
                )
            }
        }

        @ViewBuilder
        private var sessionInfoPopover: some View {
            if let activeService {
                NavigationStack {
                    SessionInfoView(
                        session: activeService.session,
                        paneId: activeService.paneId,
                        isPaneActive: activeService.isPaneActive,
                        telemetry: activeService.telemetry,
                        permissionMode: activeService.permissionMode,
                        permissionModeTrigger: activeService.permissionModeTrigger,
                        recap: activeService.recap
                    )
                    .navigationTitle("Session Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showSessionInfo = false
                            }
                        }
                    }
                }
            }
        }

        // MARK: - Window Tab Label

        private func windowTabLabel(for win: TmuxWindow) -> String {
            if !win.windowName.isEmpty {
                return win.windowName
            }
            return "Window \(win.windowIndex)"
        }

        // MARK: - Command Sending

        private var activeAgentCommandContext: AgentCommandContext? {
            let pane = window?.panes.first { $0.paneId == activePaneId }
            return AgentCommandContext(
                hostID: hostId,
                paneID: activePaneId,
                session: pane?.agentSession,
                isConnected: relayClient.isHostConnected,
                isInputAvailable: scenePhase == .active
                    && pane.map { terminalInputReadiness[$0.paneId]?() == true } == true,
                hasExternalEditor: pane?.editorSession != nil,
                inputRevision: agentCommandInputRevision
            )
        }

        private func sendAgentCommand(_ request: AgentCommandRequest) -> Bool {
            guard request.isValid(in: activeAgentCommandContext) else { return false }

            // Same queue as the other toolbar controls. Do not treat a slash
            // command as a new prompt or arm the background-turn monitor.
            enqueueToolbarKeys(request.command.keys, paneId: request.context.target.paneID, immediately: true)
            agentCommandInputRevision &+= 1
            backgroundMonitoring.resetTerminalInput(hostId: hostId, paneId: request.context.target.paneID)
            return true
        }

        private func sendCommand(_ command: CommandType, paneId: String) async {
            cursorNavigationCancellations[paneId]?()
            await relayClient.send(command, paneId: paneId)
        }

        private func sendVoiceKeys(_ keys: [TmuxKey]) {
            guard
                !keys.isEmpty,
                relayClient.isHostConnected,
                let activePaneId
            else { return }

            enqueueToolbarKeys(keys, paneId: activePaneId)
            observeTerminalInput(
                keys,
                paneId: activePaneId,
                windowName: window?.windowName ?? ""
            )
        }

        private func enqueueToolbarKeys(_ keys: [TmuxKey], paneId: String, immediately: Bool = false) {
            cursorNavigationCancellations[paneId]?()
            if voiceKeystrokePaneId != paneId {
                voiceKeystrokeDebouncer?.cancelAll()
                voiceKeystrokeDebouncer = KeystrokeDebouncer(
                    paneId: paneId,
                    relayClient: relayClient
                )
                voiceKeystrokePaneId = paneId
            }

            if immediately {
                voiceKeystrokeDebouncer?.enqueueImmediately(keys)
            } else {
                voiceKeystrokeDebouncer?.enqueue(keys)
            }
        }

        private func activeVoiceInputContext() -> String? {
            guard let activePaneId else { return nil }

            var metadata: [String] = []
            if let pane = window?.panes.first(where: { $0.paneId == activePaneId }) {
                metadata.append("Session: \(sessionName)")
                if !pane.windowName.isEmpty {
                    metadata.append("Window: \(pane.windowName)")
                }
                if let command = pane.command, !command.isEmpty {
                    metadata.append("Running command: \(command)")
                }
                if let currentPath = pane.currentPath, !currentPath.isEmpty {
                    metadata.append("Current path: \(currentPath)")
                }
            }

            return VoiceInputContext.makeTerminalContext(
                terminalText: voiceInputContextProviders[activePaneId]?(),
                metadata: metadata
            )
        }

        // MARK: - Close Window/Session

        private func requestCloseWindow(_ window: TmuxWindow) {
            Task {
                let spec = CheckRunningProcesses(target: .window(window.id))
                let result = await relayClient.sendCommand(spec, paneId: "")
                if case let .success(response) = result {
                    let processes = response.runningProcesses ?? []
                    if processes.isEmpty {
                        performCloseWindow(window)
                    } else {
                        closeConfirmation = CloseConfirmation(
                            target: .window(window),
                            runningProcesses: processes
                        )
                    }
                }
            }
        }

        private func requestCloseSession() {
            Task {
                let spec = CheckRunningProcesses(target: .session(sessionName))
                let result = await relayClient.sendCommand(spec, paneId: "")
                if case let .success(response) = result {
                    let processes = response.runningProcesses ?? []
                    if processes.isEmpty {
                        performCloseSession()
                    } else {
                        closeConfirmation = CloseConfirmation(
                            target: .session(sessionName),
                            runningProcesses: processes
                        )
                    }
                }
            }
        }

        private func performCloseWindow(_ window: TmuxWindow) {
            Task {
                let spec = KillTmuxWindow(windowId: window.id)
                let result = await relayClient.sendCommand(spec, paneId: "")
                if case .success = result {
                    // Select another window if the closed one was selected
                    // (the host will push updated state via pushSessionStateToAll)
                    if selectedWindowId == window.id {
                        let remaining = sessionWindows.filter { $0.id != window.id }
                        selectedWindowId = remaining.first(where: \.isWindowActive)?.id ?? remaining.first?.id
                        activePaneId = sessionWindows.first(where: { $0.id == selectedWindowId })?.activePane?.paneId
                    }
                } else if case let .failure(error) = result {
                    commandError = error.localizedDescription
                }
            }
        }

        private func performCloseSession() {
            Task {
                let spec = KillTmuxSession(sessionName: sessionName)
                let result = await relayClient.sendCommand(spec, paneId: "")
                if case .success = result {
                    dismiss()
                } else if case let .failure(error) = result {
                    commandError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Layout Helpers

    /// A positioned pane state within the layout
    private struct PositionedPaneState: Identifiable {
        let id: String
        let paneState: PaneState
        let rect: CGRect
    }

    // MARK: - Close Confirmation

    private struct CloseConfirmation {
        enum Target {
            case window(TmuxWindow)
            case session(String)
        }

        let target: Target
        let runningProcesses: [RunningProcessInfo]

        var title: String {
            switch target {
            case .window: "Close Window?"
            case .session: "Close Session?"
            }
        }

        var message: String {
            let grouped = Dictionary(grouping: runningProcesses) { $0.paneIndex }
            let descriptions = grouped.sorted(by: { $0.key < $1.key }).map { paneIndex, processes in
                let names = Set(processes.map(\.name)).sorted().joined(separator: ", ")
                return "Terminal \(paneIndex): \(names)"
            }
            return "The following processes are still running:\n\(descriptions.joined(separator: "\n"))"
        }
    }

#endif
