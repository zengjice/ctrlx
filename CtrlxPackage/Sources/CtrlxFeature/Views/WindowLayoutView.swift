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
        let fileWorkspace: IOSFileBrowserWorkspace
        @Binding var initialSessionFit: NewSessionSizing.InitialFit?
        let automaticallyFitOnEntry: Bool

        @Environment(SessionStore.self) private var sessionStore
        @Environment(IOSFileBrowserWorkspaceStore.self) private var fileWorkspaces
        @Environment(ViewerConnectionManager.self) private var connectionManager
        @Environment(AgentBackgroundMonitoringService.self) private var backgroundMonitoring
        @Environment(\.dismiss) private var dismiss

        /// The currently selected window within the session
        @State private var selectedWindowId: String?
        @State private var pendingFileLink: TerminalFileLinkRequest?
        @State private var artifactPreview: TerminalArtifactPreview?
        @State private var previewFilesLink: TerminalFileLinkRequest?
        @State private var previewKeyboardRestore = ArtifactPreviewKeyboardRestore()
        private struct FilesOpenRequest: Equatable {
            let paneID: String
            let new: Bool
            let inputBinding: ViewerWorkspaceInputBinding
        }

        private struct SimulatorOpenRequest: Equatable {
            let paneID: String
            let inputBinding: ViewerWorkspaceInputBinding
        }

        private enum WindowShortcutScope {
            case terminal
            case linkedTab(sourcePaneID: String)

            var sourcePaneID: String? {
                guard case let .linkedTab(sourcePaneID) = self else { return nil }
                return sourcePaneID
            }

            var includesFork: Bool {
                guard case .terminal = self else { return false }
                return true
            }
        }

        @State private var pendingSimulatorRequest: SimulatorOpenRequest?
        @State private var pendingFilesRequest: FilesOpenRequest?
        @State private var pendingFilesCloseID: UUID?
        @State private var pendingBrowserLink: TerminalBrowserLinkRequest?
        @State private var browserSelection = IOSHostTabSelection()
        @State private var simulatorSelection = IOSHostTabSelection()
        @State private var annotationHandoff = AnnotationTerminalHandoff()
        @State private var showsWindowTabs = false
        @State private var pendingWindowTabAction: WindowTabAction?

        /// The currently selected pane (receives keyboard input)
        @State private var activePaneId: String?
        @State private var mouseReportingPaneIDs: Set<String> = []

        /// Whether the software keyboard is requested for the selected pane.
        /// Terminal shortcuts remain available when this is false.
        @State private var isKeyboardActive: Bool

        /// Ordered sender shared by keyboard and one-shot toolbar input.
        @State private var externalInputSenders: [String: @MainActor ([TmuxKey], Bool, @escaping @MainActor () -> Void) -> Bool] = [:]
        @State private var voiceInputContextProviders: [String: TerminalVoiceInputContextProvider] = [:]
        @State private var cursorNavigationCancellations: [String: @MainActor () -> Void] = [:]
        @State private var terminalInputReadiness: [String: @MainActor () -> Bool] = [:]
        @State private var terminalCopyActions: [String: @MainActor () -> Void] = [:]
        @State private var terminalInputRevision: UInt64 = 0
        @State private var voiceSession = TerminalVoiceInputSession()
        @State private var quickActionPresentation = TerminalQuickActionPresentation()

        /// Service for the active pane's Claude session (nil if no session)
        @State private var activeService: SessionDetailService?

        /// Whether to show the session info popover
        @State private var showSessionInfo = false

        @State private var isResizing = false
        @State private var viewportGrids: [String: TerminalViewportSizing.Grid] = [:]
        @State private var automaticTabFit = TerminalTabFit()
        @State private var wasBackgrounded = false

        @State private var newAgentConfiguration: NewAgentTabConfiguration?
        @State private var agentForkConfiguration: AgentForkConfiguration?
        @State private var creationSheetIsPresented = false
        @State private var isCreatingWindow = false
        /// Follow and fit the returned pane independently of snapshot arrival order.
        @State private var windowCreation = NewSessionCreation()

        /// Width of the navigation bar (measured from the full-width content
        /// area). Used to cap the centered title so it doesn't bleed behind the
        /// bar buttons — see `principalTitleMaxWidth`.
        @State private var barWidth: CGFloat = 0

        /// Terminal titles detected via OSC escape sequences, keyed by pane ID
        @State private var terminalTitles: [String: String] = [:]

        /// Latest clipboard content from each pane, keyed by pane ID
        @State private var clipboardContents: [String: String] = [:]
        @State private var clipboardImagePaste: TerminalImagePasteRequest?

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
        @State private var closeConfirmation: TerminalCloseConfirmation<TmuxWindow>?

        /// Error message from failed window commands
        @State private var commandError: String?

        /// Rename-window alert state: the window being renamed (if any).
        @State private var renamingWindow: TmuxWindow?
        @State private var renamingWindowBinding = ViewerWorkspaceInputBinding.unavailable

        /// Text bound to the rename-window alert field.
        @State private var renameWindowText = ""

        init(
            sessionName: String,
            hostId: String,
            relayClient: ViewerRelayClient,
            settings: IOSSettings,
            fileWorkspace: IOSFileBrowserWorkspace,
            initialSessionFit: Binding<NewSessionSizing.InitialFit?>,
            automaticallyFitOnEntry: Bool = true
        ) {
            self.sessionName = sessionName
            self.hostId = hostId
            self.relayClient = relayClient
            self.settings = settings
            self.fileWorkspace = fileWorkspace
            self._selectedWindowId = State(initialValue: fileWorkspace.restoredWindowID)
            self._activePaneId = State(initialValue: fileWorkspace.restoredPaneID)
            self._initialSessionFit = initialSessionFit
            self.automaticallyFitOnEntry = automaticallyFitOnEntry
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
                    isActive: window.isWindowActive,
                    paneIDs: window.panes.map(\.paneId),
                    stableWindowId: window.stableId
                )
            }
        }

        /// The current window data from the session store
        private var window: TmuxWindow? {
            guard !fileWorkspace.hasPendingTerminalSelection else { return nil }
            // Window indexes change during reordering; the focused pane does not.
            if let activePaneId, let owner = sessionWindows.first(where: { $0.panes.contains { $0.paneId == activePaneId } }) {
                return owner
            }
            if let selectedWindowId {
                return sessionWindows.first { $0.id == selectedWindowId }
            }
            // Default to the active window in the session
            return sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first
        }

        /// Use the displayed window's name, matching the window switcher.
        /// Keep the session name only while window data is unavailable.
        private var navigationTitle: String {
            if let tab = selectedSimulator {
                return tab.title
            }
            if let tab = selectedBrowser {
                return tab.title.isEmpty ? "Browser" : tab.title
            }
            if let tab = fileWorkspace.selected {
                return tab.title
            }
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

        private var linkedTabs: IOSPaneLinkedTabs {
            IOSPaneLinkedTabs(
                files: fileWorkspace.tabs,
                browsers: sessionBrowsers,
                simulators: sessionSimulators,
                windows: sessionWindows,
                storedOrder: fileWorkspace.linkedTabOrder
            )
        }

        private var selectedLinkedTab: PaneLinkedTabID? {
            if let id = simulatorSelection.selectedID {
                return .simulator(id)
            }
            if let id = browserSelection.selectedID {
                return .browser(id)
            }
            return fileWorkspace.selectedID.map(PaneLinkedTabID.file)
        }

        private var selectedLinkedTabSource: (paneID: String, window: TmuxWindow)? {
            selectedLinkedTab.flatMap(linkedTabSource)
        }

        private func linkedTabSource(_ tab: PaneLinkedTabID) -> (paneID: String, window: TmuxWindow)? {
            guard
                let paneID = linkedTabs.sourcePaneID(tab),
                let window = linkedTabs.sourceWindow(for: tab) else { return nil }
            return (paneID, window)
        }

        private func selectAdjacentLinkedTab(_ source: PaneLinkedTabID, direction: Int) {
            guard !showsWindowTabs, !creationSheetIsPresented, !quickActionPresentation.suspendsTerminalInput else { return }
            switch PaneLinkedTabs.adjacent(to: source, direction: direction, groups: linkedTabs.groups) {
            case let .tab(item):
                fileWorkspace.selectedID = nil
                browserSelection.selectedID = nil
                simulatorSelection.selectedID = nil
                switch item {
                case let .file(id): fileWorkspace.selectedID = id
                case let .browser(id): browserSelection.selectedID = id
                case let .simulator(id): simulatorSelection.selectedID = id
                }
            case let .sourcePane(id):
                guard let target = sessionWindows.first(where: { $0.panes.contains { $0.paneId == id } }) else { return }
                selectTerminalWindow(target, preferredPaneID: id)
                if relayClient.isHostConnected {
                    let binding = relayClient.workspaceInputState.binding(paneID: id)
                    Task { await sendCommand(.selectTmuxPane, paneId: id, inputBinding: binding) }
                }
            case nil: break
            }
        }

        private var terminalIsVisible: Bool {
            selectedBrowser == nil && selectedSimulator == nil && fileWorkspace.selected == nil
        }

        private var annotationSource: AnnotationTerminalHandoff.Source? {
            if let tab = selectedSimulator {
                return .simulator(tab.id)
            }
            if let tab = selectedBrowser {
                return .browser(tab.id)
            }
            if let tab = fileWorkspace.selected {
                return .file(tab.id)
            }
            return nil
        }

        private var displayedTerminalWindow: TmuxWindow? {
            if let request = annotationHandoff.request, annotationSource == request.source {
                return sessionWindows.first { $0.id == request.windowID }
            }
            return terminalIsVisible ? window : nil
        }

        private var browserContent: some View {
            ZStack {
                // The destination retains this exact identity when the browser
                // overlay disappears; no second subscription/bootstrap is needed.
                if let terminalWindow = displayedTerminalWindow {
                    windowContent(terminalWindow)
                        .id(terminalWindow.id)
                        .allowsHitTesting(terminalIsVisible)
                        .accessibilityHidden(!terminalIsVisible)
                }
                if let tab = selectedSimulator {
                    RemoteSimulatorView(tab: tab, client: relayClient)
                        .environment(\.browserAnnotationContext, BrowserAnnotationContext.remote(
                            targets: sessionWindows.flatMap(\.panes).compactMap(AgentImageTarget.init(pane:)), client: relayClient,
                            didSend: { target in try await revealAnnotationTarget(target, source: .simulator(tab.id)) }
                        ))
                        .background(Color(.systemBackground))
                        .id(tab.id)
                } else if let tab = selectedBrowser {
                    RemoteBrowserView(tab: tab, client: relayClient) { opened in
                        cancelCreationFollowUp()
                        isKeyboardActive = false
                        quickActionPresentation.dismiss()
                        fileWorkspace.selectedID = nil
                        simulatorSelection.selectedID = nil
                        browserSelection.selectedID = opened.id
                    }
                    .environment(\.browserAnnotationContext, BrowserAnnotationContext.remote(
                        targets: sessionWindows.flatMap(\.panes).compactMap(AgentImageTarget.init(pane:)), client: relayClient,
                        didSend: { target in try await revealAnnotationTarget(target, source: .browser(tab.id)) }
                    ))
                    .background(Color(.systemBackground))
                    .id(tab.id)
                } else if let tab = fileWorkspace.selected, fileWorkspace.unavailableFileSources.contains(tab.id) {
                    ContentUnavailableView(
                        "Files Source Unavailable",
                        symbol: .exclamationmarkTriangle,
                        description: "The saved Files tab will reconnect when its original terminal is available."
                    )
                } else if let tab = fileWorkspace.selected {
                    WorkspaceFileBrowserView(tab: tab, source: .remote(
                        hostID: hostId,
                        paneID: tab.sourcePaneID,
                        connection: connectionManager.connection(for: hostId)
                    ))
                    .environment(\.browserAnnotationContext, BrowserAnnotationContext.remote(
                        targets: sessionWindows.flatMap(\.panes).compactMap(AgentImageTarget.init(pane:)), client: relayClient,
                        didSend: { target in try await revealAnnotationTarget(target, source: .file(tab.id)) }
                    ))
                    .background(Color(.systemBackground))
                    .id(tab.id)
                } else if displayedTerminalWindow == nil {
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
            .modifier(TerminalQuickActionOverlay(
                presentation: $quickActionPresentation,
                store: settings.quickPhrases,
                customButtonStore: settings.customButtons,
                phraseContext: activePhraseContext,
                sendPhrase: sendPhrase,
                commandContext: activeAgentCommandContext,
                sendCommand: sendAgentCommand
            ))
            .modifier(TerminalVoiceInputOverlay(
                session: voiceSession, context: activePhraseContext,
                isSuspended: !terminalIsVisible || artifactPreview != nil || quickActionPresentation.isPresented,
                insert: insertVoiceTranscript
            ))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if terminalIsVisible, window != nil {
                    TerminalKeyboardBar(
                        voiceSession: voiceSession,
                        relayClient: relayClient,
                        clipboardPaste: $clipboardImagePaste,
                        isEnabled: relayClient.isHostConnected && activePaneId != nil,
                        contextProvider: activeVoiceInputContext,
                        sendKeys: sendVoiceKeys,
                        phraseContext: activePhraseContext,
                        quickActionPresentation: $quickActionPresentation,
                        customButtonStore: settings.customButtons,
                        sendCustomButton: sendCustomButton,
                        agentCommandContext: activeAgentCommandContext,
                        showsTerminalControls: settings.terminalKeyboardControlPosition == .bottomBar
                    )
                    .gesture(terminalBarSwipe)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if terminalIsVisible, let window {
                    windowShortcutBar(window)
                } else if let source = selectedLinkedTabSource {
                    windowShortcutBar(source.window, scope: .linkedTab(sourcePaneID: source.paneID))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { windowToolbar }
        }

        private var fileWorkspaceContext: IOSFileBrowserWorkspace.Context? {
            .init(hostID: hostId, windows: sessionWindows)
        }

        private var sessionBrowsers: [RemoteBrowserTab] {
            relayClient.browserTabs.filter { $0.sessionName == sessionName }
        }

        private var sessionSimulators: [RemoteSimulatorTab] {
            relayClient.simulatorTabs.filter { $0.sessionName == sessionName }
        }

        private var selectedSimulator: RemoteSimulatorTab? {
            sessionSimulators.first { $0.id == simulatorSelection.selectedID }
        }

        private var selectedBrowser: RemoteBrowserTab? {
            sessionBrowsers.first { $0.id == browserSelection.selectedID }
        }

        private func revealAnnotationTarget(_ target: AgentImageTarget, source: AnnotationTerminalHandoff.Source) async throws {
            guard
                annotationSource == source, scenePhase == .active, relayClient.isHostConnected,
                let destination = sessionWindows.first(where: { $0.stableId == target.windowID }),
                destination.panes.contains(where: target.matches) else {
                throw AgentImageError.message("The Agent or connection changed. Choose the recipient again.")
            }
            let id = try await annotationHandoff.prepare(
                source: source,
                windowID: destination.id,
                paneIDs: Set(destination.panes.map(\.paneId))
            )
            defer { annotationHandoff.cancel(id: id) }
            try Task.checkCancellation()
            guard
                annotationHandoff.isReady(id), annotationSource == source,
                scenePhase == .active, relayClient.isHostConnected,
                let current = sessionWindows.first(where: { $0.id == destination.id }),
                Set(current.panes.map(\.paneId)) == Set(destination.panes.map(\.paneId)),
                current.panes.contains(where: target.matches) else {
                throw AgentImageError.message("The Agent or connection changed. Try Open Agent again.")
            }
            selectTerminalWindow(current, preferredPaneID: target.paneID)
            annotationHandoff.finish(id)
        }

        private func saveFileWorkspace() {
            fileWorkspace.updateContext(fileWorkspaceContext)
            fileWorkspace.save()
        }

        private func saveRecoverySelection() {
            fileWorkspaces.recordSelection(workspace: fileWorkspace, window: window, paneID: activePaneId)
        }

        private var fileLinkContent: some View {
            browserContent
                .safeAreaInset(edge: .bottom) {
                    if pendingSimulatorRequest != nil {
                        HStack {
                            ProgressView()
                            Text("Opening iOS Simulator on Host…").font(.callout)
                            Spacer()
                            Button("Cancel") { pendingSimulatorRequest = nil }
                        }
                        .padding()
                        .background(.regularMaterial)
                    }
                }
                .task(id: pendingSimulatorRequest) {
                    guard let request = pendingSimulatorRequest else { return }
                    do {
                        let tab = try await RemoteSimulatorSession.open(
                            sessionName: sessionName, sourcePaneID: request.paneID, client: relayClient, inputBinding: request.inputBinding
                        )
                        try Task.checkCancellation()
                        guard pendingSimulatorRequest == request else { return }
                        fileWorkspace.selectedID = nil
                        browserSelection.selectedID = nil
                        simulatorSelection.selectedID = tab.id
                        pendingSimulatorRequest = nil
                    } catch is CancellationError { }
                    catch {
                        guard pendingSimulatorRequest == request else { return }
                        pendingSimulatorRequest = nil
                        commandError = error.localizedDescription
                    }
                }
                .task(id: pendingFilesRequest) {
                    guard let request = pendingFilesRequest else { return }
                    let paneID = request.paneID
                    do {
                        let descriptor = try await HostFileTabClient.open(connection: connectionManager.connection(for: hostId), sessionName: sessionName, paneID: paneID, new: request.new, inputBinding: request.inputBinding)
                        try Task.checkCancellation()
                        guard pendingFilesRequest == request, sessionWindows.contains(where: { $0.panes.contains { $0.paneId == paneID } }) else { return }
                        let tab = fileWorkspace.adopt(descriptor)
                        browserSelection.selectedID = nil
                        simulatorSelection.selectedID = nil
                        fileWorkspace.selectedID = tab.id
                        pendingFilesRequest = nil
                    } catch is CancellationError { }
                    catch { commandError = error.localizedDescription
                        pendingFilesRequest = nil
                    }
                }
                .task(id: pendingFilesCloseID) {
                    guard let id = pendingFilesCloseID else { return }
                    do {
                        try await HostFileTabClient.close(connection: connectionManager.connection(for: hostId), id: id)
                        fileWorkspace.close(id)
                    } catch is CancellationError { }
                    catch { commandError = error.localizedDescription }
                    if pendingFilesCloseID == id {
                        pendingFilesCloseID = nil
                    }
                }
                .environment(\.openTerminalBrowserLink) { request in pendingBrowserLink = request }
                .task(id: pendingBrowserLink) {
                    guard let request = pendingBrowserLink else { return }
                    await openTerminalBrowser(request)
                }
                .environment(\.openTerminalFileLink) { request in pendingFileLink = request }
                .terminalFileLinkTask($pendingFileLink) { request in
                    await openTerminalFile(request)
                }
                .onChange(of: window?.id) { pendingFileLink = nil
                    pendingFilesRequest = nil
                    pendingBrowserLink = nil
                    pendingSimulatorRequest = nil
                }
                .onChange(of: fileWorkspace.selectedID) { pendingFileLink = nil
                    pendingFilesRequest = nil
                    pendingBrowserLink = nil
                    pendingSimulatorRequest = nil
                }
                .onChange(of: browserSelection.selectedID) { pendingFileLink = nil
                    pendingFilesRequest = nil
                    pendingBrowserLink = nil
                    pendingSimulatorRequest = nil
                }
                .onChange(of: simulatorSelection.selectedID) { pendingFileLink = nil
                    pendingFilesRequest = nil
                    pendingBrowserLink = nil
                    pendingSimulatorRequest = nil
                }
        }

        private var presentedContent: some View {
            fileLinkContent
                .onChange(of: fileWorkspaceContext, initial: true) { _, context in
                    fileWorkspace.updateContext(context)
                }
                .onChange(of: fileWorkspace.recoverySnapshots) { _, _ in saveFileWorkspace() }
                .onChange(of: fileWorkspace.selectedID) { _, _ in saveFileWorkspace() }
                .onChange(of: relayClient.simulatorTabs) { _, _ in
                    let shouldFit = simulatorSelection.syncTabs(Set(sessionSimulators.map(\.id)))
                    if shouldFit, terminalIsVisible, relayClient.isHostConnected, scenePhase == .active {
                        requestAutomaticTabFit()
                    }
                }
                .onChange(of: relayClient.browserTabs) { _, _ in
                    let shouldFit = browserSelection.syncTabs(Set(sessionBrowsers.map(\.id)))
                    if shouldFit, terminalIsVisible, relayClient.isHostConnected, scenePhase == .active {
                        requestAutomaticTabFit()
                    }
                }
                .onDisappear(perform: saveFileWorkspace)
                .sheet(item: $artifactPreview, onDismiss: {
                    if let link = previewFilesLink {
                        previewFilesLink = nil
                        pendingFileLink = link
                    } else {
                        restorePreviewKeyboard()
                    }
                }) { preview in
                    TerminalArtifactPreviewSheet(preview: preview) { request in
                        previewFilesLink = request
                        artifactPreview = nil
                    }
                    .preferredColorScheme(settings.appearanceMode.colorScheme)
                }
                .sheet(isPresented: $showsWindowTabs, onDismiss: windowTabsDidDismiss) {
                    WindowTabsPanel(
                        windows: sessionWindows,
                        files: fileWorkspace.tabs,
                        browsers: sessionBrowsers,
                        simulators: sessionSimulators,
                        selectedWindowID: window?.stableId,
                        selectedFileID: fileWorkspace.selectedID,
                        selectedBrowserID: browserSelection.selectedID,
                        selectedSimulatorID: simulatorSelection.selectedID,
                        canCloseSimulator: relayClient.hostSupportsSimulatorClosing,
                        isConnected: relayClient.isHostConnected,
                        isCreatingWindow: isCreatingWindow,
                        onChoose: { action in
                            if pendingWindowTabAction == nil {
                                pendingWindowTabAction = action
                            }
                        },
                        onReorderWindows: reorderWindows,
                        linkedTabOrder: fileWorkspace.linkedTabOrder,
                        onReorderLinkedTabs: fileWorkspace.recordLinkedTabOrder
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .sheet(item: $newAgentConfiguration, onDismiss: creationSheetDidDismiss) { configuration in
                    NewAgentTabPanel(configuration: configuration)
                        .presentationDetents([.large])
                }
                .sheet(item: $agentForkConfiguration, onDismiss: creationSheetDidDismiss) { configuration in
                    AgentForkPanel(configuration: configuration)
                        .presentationDetents([.large])
                }
                .alert(item: $closeConfirmation) { confirmation in
                    Alert(
                        title: Text(confirmation.title),
                        message: Text(confirmation.message),
                        primaryButton: .destructive(Text(confirmation.actionTitle)) {
                            performCloseWindow(confirmation.target, inputBinding: confirmation.inputBinding, closesSession: confirmation.closesSession)
                        },
                        secondaryButton: .cancel()
                    )
                }
                .alert("Error", isPresented: .init(
                    get: { commandError != nil },
                    set: {
                        if !$0 {
                            commandError = nil
                        }
                    }
                )) {
                    Button("OK") { commandError = nil }
                } message: {
                    if let error = commandError {
                        Text(error)
                    }
                }
                // Intentionally inline rather than using `WindowRenamingModifier`:
                // The tab list closes before this enclosing view presents rename.
                .alert("Rename Window", isPresented: .init(
                    get: { renamingWindow != nil },
                    set: {
                        if !$0 {
                            renamingWindow = nil
                        }
                    }
                )) {
                    TextField("Window Name", text: $renameWindowText)
                    Button("Save") {
                        let trimmed = renameWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let target = renamingWindow, !trimmed.isEmpty {
                            let binding = renamingWindowBinding
                            Task {
                                let result = await relayClient.sendCommand(
                                    SetWindowName(windowId: target.stableId, name: trimmed),
                                    paneId: "", inputBinding: binding
                                )
                                if case let .failure(error) = result {
                                    commandError = error.localizedDescription
                                }
                                if case let .success(response) = result, !response.success {
                                    commandError = response.error
                                }
                            }
                        }
                        renamingWindow = nil
                    }
                    Button("Cancel", role: .cancel) { renamingWindow = nil }
                } message: {
                    Text("Enter a new name for this window")
                }
        }

        private func openTerminalFile(_ request: TerminalFileLinkRequest) async {
            guard
                request.hostID == hostId, let origin = window,
                let pane = origin.panes.first(where: { $0.paneId == request.paneID }) else {
                restorePreviewKeyboard()
                return
            }
            let source = FileBrowserSource.remote(
                hostID: hostId,
                paneID: request.paneID,
                connection: connectionManager.connection(for: hostId)
            )
            let fileContext = RepositoryFileContext(pane: pane)
            let inputBinding = relayClient.workspaceInputState.binding(paneID: request.paneID)
            do {
                let destination = try await TerminalFileDestination.resolve(
                    path: request.path, context: fileContext, source: source
                )
                let shouldPreview = request.prefersPreview && TerminalArtifactPreview.supports(path: destination.file)
                let descriptor = shouldPreview ? nil : try await HostFileTabClient.open(connection: connectionManager.connection(for: hostId), sessionName: sessionName, paneID: request.paneID, inputBinding: inputBinding)
                try Task.checkCancellation()
                guard
                    pendingFileLink == request, window?.id == origin.id,
                    window?.panes.contains(where: { $0.paneId == request.paneID && RepositoryFileContext(pane: $0) == fileContext }) == true,
                    fileWorkspace.selectedID == nil, browserSelection.selectedID == nil && simulatorSelection.selectedID == nil else {
                    restorePreviewKeyboard()
                    return
                }
                if shouldPreview, let path = destination.file, let fileContext {
                    if let activePaneId {
                        previewKeyboardRestore.captureIfNeeded(paneID: activePaneId, keyboardIsActive: isKeyboardActive)
                    }
                    artifactPreview = .init(link: request, context: fileContext, source: source, path: path)
                } else if let descriptor {
                    previewKeyboardRestore.discard()
                    let tab = fileWorkspace.adopt(descriptor)
                    tab.openTerminalFile(destination, paneID: request.paneID)
                    fileWorkspace.selectedID = tab.id
                    cancelCreationFollowUp()
                } else {
                    restorePreviewKeyboard()
                }
                isKeyboardActive = false
                quickActionPresentation.dismiss()
            } catch is CancellationError {
                restorePreviewKeyboard()
            } catch {
                restorePreviewKeyboard()
                if pendingFileLink == request {
                    commandError = "Cannot open Host path: \(error.localizedDescription)"
                }
            }
        }

        private func restorePreviewKeyboard() {
            guard
                let keyboardWasActive = previewKeyboardRestore.consume(
                    terminalIsVisible: terminalIsVisible, activePaneID: activePaneId
                ) else { return }
            isKeyboardActive = keyboardWasActive
        }

        private func openTerminalBrowser(_ request: TerminalBrowserLinkRequest) async {
            guard
                request.hostID == hostId,
                sessionWindows.contains(where: { $0.panes.contains { $0.paneId == request.paneID } }) else { return }
            let originWindowID = window?.id
            do {
                let tab = try await RemoteBrowserSession.open(
                    sessionName: sessionName,
                    sourcePaneID: request.paneID,
                    url: request.url,
                    client: relayClient
                )
                try Task.checkCancellation()
                guard pendingBrowserLink == request, window?.id == originWindowID else { return }
                browserSelection.selectedID = tab.id
                simulatorSelection.selectedID = nil
                fileWorkspace.selectedID = nil
                cancelCreationFollowUp()
                isKeyboardActive = false
                quickActionPresentation.dismiss()
            } catch is CancellationError { }
            catch {
                if pendingBrowserLink == request, !Task.isCancelled {
                    commandError = "Cannot open Host browser: \(error.localizedDescription)"
                }
            }
        }

        private var terminalLifecycleContent: some View {
            presentedContent
                .task {
                    saveRecoverySelection()
                    fileWorkspaces.selectSession(fileWorkspace.recoveryReference)
                    if automaticallyFitOnEntry {
                        requestAutomaticTabFit()
                    }
                    updateActiveService()
                    // Mark session as handled when navigating into the view
                    await activeService?.markHandledIfNeeded()
                }
                .onChange(of: windowSelectionCandidates, initial: true) { previous, candidates in
                    mouseReportingPaneIDs.formIntersection(candidates.flatMap(\.paneIDs))
                    reconcileWindowSelection(candidates: candidates, previousCandidates: previous)
                    if
                        let request = annotationHandoff.request,
                        Set(sessionWindows.first(where: { $0.id == request.windowID })?.panes.map(\.paneId) ?? []) != request.paneIDs {
                        annotationHandoff.cancel(error: AgentImageError.message("The Agent window layout changed. Try Open Agent again."))
                    }
                }
                .onChange(of: viewportGrids) {
                    fitTerminalIfReady()
                }
                .onChange(of: window?.windowLayout, initial: true) {
                    fitTerminalIfReady()
                }
                .onChange(of: automaticTabFit) {
                    fitTerminalIfReady()
                }
                .onChange(of: terminalIsVisible) {
                    if !terminalIsVisible {
                        automaticTabFit.cancel()
                    }
                }
                .onChange(of: isResizing) {
                    if !isResizing {
                        fitTerminalIfReady()
                    }
                }
                .onChange(of: relayClient.isHostConnected) {
                    if !relayClient.isHostConnected {
                        pendingBrowserLink = nil
                        browserSelection.cancelPendingCloses()
                        simulatorSelection.cancelPendingCloses()
                        cancelCreationFollowUp()
                        annotationHandoff.cancel(error: AgentImageError.message("The Host disconnected. Reconnect and try Open Agent again."))
                    } else {
                        fitTerminalIfReady()
                    }
                }
                .onChange(of: relayClient.hostSupportsTerminalFit) {
                    fitTerminalIfReady()
                }
        }

        var body: some View {
            terminalLifecycleContent
                .onChange(of: annotationSource) {
                    if let request = annotationHandoff.request, annotationSource != request.source {
                        annotationHandoff.cancel()
                    }
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .background {
                        wasBackgrounded = true
                    }
                    if scenePhase != .active {
                        browserSelection.cancelPendingCloses()
                        simulatorSelection.cancelPendingCloses()
                        annotationHandoff.cancel()
                        pendingBrowserLink = nil
                    } else {
                        if wasBackgrounded {
                            wasBackgrounded = false
                            if terminalIsVisible, automaticTabFit.target == nil {
                                requestAutomaticTabFit(windowID: window?.stableId)
                            }
                        }
                        fitTerminalIfReady()
                    }
                }
                .onDisappear {
                    // A delayed creation reply must not redirect a later visit.
                    cancelCreationFollowUp()
                    browserSelection.cancelPendingCloses()
                    simulatorSelection.cancelPendingCloses()
                    automaticTabFit.cancel()
                    wasBackgrounded = false
                    annotationHandoff.cancel()
                    pendingWindowTabAction = nil
                    pendingBrowserLink = nil
                    pendingFileLink = nil
                    showsWindowTabs = false
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
                        terminalIsVisible,
                        content != lastWrittenClipboardContent
                    else { return }
                    clipboard.setString(content)
                    lastWrittenClipboardContent = content
                }
                .onChange(of: activePaneId) { oldValue, newValue in
                    saveRecoverySelection()
                    terminalInputRevision &+= 1
                    updateActiveService()
                    // Mark session as handled when switching to a pane with attention
                    Task { await activeService?.markHandledIfNeeded() }
                    // Sync pane selection to the tmux session on the host.
                    // When oldValue is nil, it's the initial assignment from onAppear
                    // — skip it to avoid redirecting the host's tmux focus on load.
                    guard oldValue != nil, let newValue else { return }
                    let binding = relayClient.workspaceInputState.binding(paneID: newValue)
                    Task {
                        await sendCommand(.selectTmuxPane, paneId: newValue, inputBinding: binding)
                    }
                }
                .onChange(of: relayClient.workspaceInputState.sessionBinding(name: sessionName)) { _, current in
                    if !windowCreation.validateSessionBinding(current) {
                        initialSessionFit?.cancel(hostID: hostId, sessionName: sessionName)
                    }
                }
                .onChange(of: selectedWindowId) { saveRecoverySelection() }
        }

        @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
            // Title opens the tab picker; actions belong to the displayed window.
            ToolbarItem(placement: .principal) {
                Button(action: openWindowTabs) {
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
                .modifier(PaneLinkedTabTitleSwipe(selected: selectedLinkedTab, onSwitch: selectAdjacentLinkedTab))
                .accessibilityLabel("Tabs: \(navigationTitle)")
                .accessibilityIdentifier("window-tabs-picker")
            }
            if terminalIsVisible, settings.terminalKeyboardControlPosition == .topRight {
                ToolbarItem(placement: .topBarTrailing) {
                    TerminalVoiceInputButton(
                        session: voiceSession, context: activePhraseContext,
                        isDisabled: !relayClient.isHostConnected || activePaneId == nil || quickActionPresentation.isPresented,
                        contextProvider: activeVoiceInputContext
                    )
                    .id(activePhraseContext.target)
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

            if let tab = selectedLinkedTab {
                ToolbarItem(placement: .topBarTrailing) {
                    linkedTabMenu(tab)
                }
            } else if terminalIsVisible, let window {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            activeCopyAction?()
                        } label: {
                            Label("Copy Terminal Text", symbol: .docOnClipboard)
                        }
                        .disabled(activeCopyAction == nil)

                        if let paneID = activePaneId {
                            Menu {
                                Picker("Touch Mode", selection: Binding(
                                    get: { mouseReportingPaneIDs.contains(paneID) },
                                    set: { enabled in
                                        if enabled {
                                            mouseReportingPaneIDs.insert(paneID)
                                        } else {
                                            mouseReportingPaneIDs.remove(paneID)
                                        }
                                    }
                                )) {
                                    Text("Select Text").tag(false)
                                    Text("Send Mouse Events").tag(true)
                                }
                                .pickerStyle(.inline)
                            } label: {
                                Label("Touch Mode", symbol: .handDraw)
                            }
                            .accessibilityHint("Controls whether double and triple taps select text or send mouse events.")
                            .accessibilityIdentifier("terminal-touch-mode")
                        }

                        if let activeService, activeService.session != nil {
                            Divider()

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
                        }
                        Divider()
                        windowActions(window, includesWindowManagement: true)
                    } label: {
                        Label("More", symbol: .ellipsisCircle)
                    }
                    .menuOrder(.fixed)
                    .accessibilityIdentifier("window-actions-\(window.stableId)")
                    .tint(activeService?.isYoloModeEnabled == true ? .red : nil)
                    .popover(isPresented: $showSessionInfo) {
                        sessionInfoPopover
                    }
                }
            }
        }

        private func linkedTabMenu(_ tab: PaneLinkedTabID) -> some View {
            let source = linkedTabSource(tab)
            return Menu {
                Button {
                    if let source {
                        selectTerminalWindow(source.window, preferredPaneID: source.paneID)
                    }
                } label: {
                    Label("Go to Terminal Tab", symbol: .terminal)
                }
                .disabled(source == nil)
                Divider()
                Button(role: .destructive) {
                    switch tab {
                    case let .file(id): performWindowTabAction(.closeFiles(id))
                    case let .browser(id): performWindowTabAction(.closeBrowser(id))
                    case let .simulator(id): performWindowTabAction(.closeSimulator(id))
                    }
                } label: {
                    Label("Close Tab", symbol: .xmark)
                }
                .disabled(!canCloseLinkedTab(tab))
                if case .simulator = tab, relayClient.isHostConnected, !relayClient.hostSupportsSimulatorClosing {
                    Text("Update the Host Mac to close simulator tabs")
                }
            } label: {
                Label("More", symbol: .ellipsisCircle)
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("linked-tab-actions")
        }

        private func canCloseLinkedTab(_ tab: PaneLinkedTabID) -> Bool {
            switch tab {
            case let .file(id):
                guard let file = fileWorkspace.tabs.first(where: { $0.id == id }) else { return false }
                return pendingFilesCloseID == nil && (file.hostTab == nil || relayClient.isHostConnected)
            case let .browser(id):
                return relayClient.isHostConnected && !browserSelection.isClosing(id)
            case let .simulator(id):
                return relayClient.isHostConnected && relayClient.hostSupportsSimulatorClosing && !simulatorSelection.isClosing(id)
            }
        }

        private func windowShortcutBar(_ window: TmuxWindow, scope: WindowShortcutScope = .terminal) -> some View {
            ViewThatFits(in: .horizontal) {
                windowShortcutButtons(window, scope: scope)
                ScrollView(.horizontal) {
                    windowShortcutButtons(window, scope: scope)
                        .padding(.horizontal, 4)
                }
                .scrollIndicators(.visible)
                .frame(height: 44)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }

        private func windowShortcutButtons(_ window: TmuxWindow, scope: WindowShortcutScope) -> some View {
            HStack(spacing: 8) {
                Group {
                    windowActions(window, scope: scope)
                    if case .terminal = scope {
                        Button(action: resizeWindowToFit) {
                            Label("Fit Terminal to Screen", symbol: .arrowUpLeftAndArrowDownRight)
                        }
                        .disabled(!relayClient.isHostConnected || isResizing || resizeToFitRequest == nil)
                        .accessibilityHint("Changes the window size on the Host and all Viewers")
                        .accessibilityIdentifier("terminal-fit-to-screen")
                    }
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
        }

        private func windowActions(
            _ window: TmuxWindow,
            includesWindowManagement: Bool = false,
            scope: WindowShortcutScope = .terminal
        ) -> some View {
            WindowTabActions(
                window: window,
                focusedPaneID: activePaneId,
                simulators: sessionSimulators,
                isConnected: relayClient.isHostConnected,
                canOpenFiles: relayClient.hostSupportsPaneFiles,
                canOpenBrowser: relayClient.hostSupportsPaneBrowser,
                canOpenSimulator: relayClient.hostSupportsSimulatorViewing,
                canCreateSimulator: relayClient.hostSupportsPaneSimulator,
                isCreatingWindow: isCreatingWindow,
                forkUnavailableReason: agentForkUnavailableReason(),
                includesWindowManagement: includesWindowManagement,
                includesFork: scope.includesFork,
                choose: { action in
                    performWindowTabAction(action, preferredPaneID: scope.sourcePaneID)
                }
            )
        }

        private func openWindowTabs() {
            pendingWindowTabAction = nil
            showsWindowTabs = true
        }

        private var terminalBarSwipe: TerminalBarSwipeGesture {
            TerminalBarSwipeGesture(
                isEnabled: terminalIsVisible && !showsWindowTabs && !creationSheetIsPresented
                    && !quickActionPresentation.isPresented && !voiceSession.isPresented
            ) { direction in
                switch direction {
                case .up:
                    openWindowTabs()
                case .down:
                    isKeyboardActive = false
                }
            }
        }

        private func windowTabsDidDismiss() {
            guard let action = pendingWindowTabAction else {
                fitTerminalIfReady()
                return
            }
            pendingWindowTabAction = nil
            performWindowTabAction(action)
        }

        private func performWindowTabAction(_ action: WindowTabAction, preferredPaneID: String? = nil) {
            pendingSimulatorRequest = nil
            switch action {
            case let .window(_, operation):
                guard let target = action.targetWindow(in: sessionWindows) else {
                    commandError = "This window has been closed. Reopen the tab list."
                    return
                }
                if operation != .select, !relayClient.isHostConnected {
                    commandError = "Host is offline. Reconnect before operating on this window."
                    return
                }
                switch operation {
                case .select:
                    selectTerminalWindow(target)
                case .openFiles,
                     .openAnotherFiles:
                    guard
                        relayClient.hostSupportsPaneFiles,
                        let paneID = actionPaneID(in: target, preferredPaneID: preferredPaneID) else {
                        commandError = "Files is unavailable for this window. Check the Host and tab limit."
                        return
                    }
                    cancelCreationFollowUp()
                    isKeyboardActive = false
                    quickActionPresentation.dismiss()
                    pendingFilesRequest = .init(paneID: paneID, new: operation == .openAnotherFiles, inputBinding: relayClient.workspaceInputState.binding(paneID: paneID))
                case .openSimulator:
                    guard
                        relayClient.hostSupportsPaneSimulator,
                        let paneID = actionPaneID(in: target, preferredPaneID: preferredPaneID) else {
                        commandError = "Update the Host to open iOS Simulator for this window."
                        return
                    }
                    cancelCreationFollowUp()
                    isKeyboardActive = false
                    quickActionPresentation.dismiss()
                    pendingFileLink = nil
                    pendingFilesRequest = nil
                    pendingBrowserLink = nil
                    pendingSimulatorRequest = .init(paneID: paneID, inputBinding: relayClient.workspaceInputState.binding(paneID: paneID))
                case .openBrowser:
                    guard let paneID = actionPaneID(in: target, preferredPaneID: preferredPaneID) else {
                        commandError = "This window no longer has a source pane."
                        return
                    }
                    pendingBrowserLink = .init(paneID: paneID, hostID: hostId)
                case let .fork(usingWorktree):
                    guard !isCreatingWindow else { return }
                    if let reason = agentForkUnavailableReason() {
                        commandError = reason
                        return
                    }
                    creationSheetIsPresented = true
                    agentForkConfiguration = forkConfiguration(window: target, usingWorktree: usingWorktree)
                case .rename:
                    renameWindowText = target.windowName
                    renamingWindowBinding = relayClient.workspaceInputState.windowBinding(target: target.stableId)
                    renamingWindow = target
                case .close:
                    requestCloseWindow(target)
                }
            case let .selectFiles(id):
                browserSelection.selectedID = nil
                simulatorSelection.selectedID = nil
                guard fileWorkspace.tabs.contains(where: { $0.id == id }) else { return }
                cancelCreationFollowUp()
                isKeyboardActive = false
                quickActionPresentation.dismiss()
                fileWorkspace.selectedID = id
            case let .closeFiles(id):
                guard canCloseLinkedTab(.file(id)) else { return }
                if
                    id == fileWorkspace.selectedID,
                    let sourcePaneID = fileWorkspace.selected?.sourcePaneID,
                    let sourceWindow = sessionWindows.first(where: { $0.panes.contains { $0.paneId == sourcePaneID } }) {
                    selectTerminalWindow(sourceWindow, preferredPaneID: sourcePaneID)
                }
                if fileWorkspace.tabs.first(where: { $0.id == id })?.hostTab != nil {
                    pendingFilesCloseID = id
                } else {
                    fileWorkspace.close(id)
                }
            case .newTerminal:
                browserSelection.selectedID = nil
                simulatorSelection.selectedID = nil
                guard relayClient.isHostConnected, !isCreatingWindow else { return }
                fileWorkspace.selectedID = nil
                createTerminalWindow()
            case .newAgent:
                browserSelection.selectedID = nil
                simulatorSelection.selectedID = nil
                guard relayClient.isHostConnected, !isCreatingWindow else { return }
                fileWorkspace.selectedID = nil
                creationSheetIsPresented = true
                newAgentConfiguration = agentTabConfiguration()
            case let .selectSimulator(id):
                guard sessionSimulators.contains(where: { $0.id == id }) else { return }
                cancelCreationFollowUp()
                isKeyboardActive = false
                quickActionPresentation.dismiss()
                fileWorkspace.selectedID = nil
                browserSelection.selectedID = nil
                simulatorSelection.selectedID = id
            case let .selectBrowser(id):
                guard sessionBrowsers.contains(where: { $0.id == id }) else { return }
                cancelCreationFollowUp()
                isKeyboardActive = false
                quickActionPresentation.dismiss()
                fileWorkspace.selectedID = nil
                browserSelection.selectedID = id
                simulatorSelection.selectedID = nil
            case let .closeSimulator(id):
                guard canCloseLinkedTab(.simulator(id)), let tab = sessionSimulators.first(where: { $0.id == id }) else { return }
                simulatorSelection.beginClosing(id)
                Task {
                    do {
                        try await RemoteSimulatorSession.close(tab: tab, client: relayClient)
                    } catch {
                        simulatorSelection.cancelClosing(id)
                        commandError = error.localizedDescription
                    }
                }
            case let .closeBrowser(id):
                guard canCloseLinkedTab(.browser(id)), let tab = sessionBrowsers.first(where: { $0.id == id }) else { return }
                browserSelection.beginClosing(id)
                Task {
                    do {
                        try await RemoteBrowserSession.close(tab: tab, client: relayClient)
                    } catch {
                        browserSelection.cancelClosing(id)
                        commandError = error.localizedDescription
                    }
                }
            }
        }

        private func actionPaneID(in window: TmuxWindow, preferredPaneID: String?) -> String? {
            FileBrowserTab.sourcePaneID(
                in: window.panes.map(\.paneId),
                focusedPaneID: preferredPaneID ?? activePaneId,
                activePaneID: window.activePane?.paneId
            )
        }

        private func reorderWindows(_ ids: [String]) async throws {
            guard relayClient.isHostConnected else {
                throw NSError(domain: "WindowTabs", code: 1, userInfo: [NSLocalizedDescriptionKey: "Host is offline. Reconnect before reordering tabs."])
            }
            guard ids.count == sessionWindows.count, Set(ids) == Set(sessionWindows.map(\.stableId)) else {
                throw NSError(domain: "WindowTabs", code: 2, userInfo: [NSLocalizedDescriptionKey: "The tabs changed during the drag. Try again."])
            }
            let binding = relayClient.workspaceInputState.sessionBinding(name: sessionName)
            let response = try await relayClient.sendCommand(
                MoveTmuxWindows(sessionName: sessionName, windowIds: ids), paneId: "", inputBinding: binding
            ).get()
            guard response.success else {
                throw NSError(domain: "WindowTabs", code: 3, userInfo: [NSLocalizedDescriptionKey: response.error ?? "The Host could not reorder the tabs."])
            }
            // The acknowledgement and refreshed snapshot may arrive in either order.
            for _ in 0..<20 {
                try Task.checkCancellation()
                _ = try binding.expectedPane(current: relayClient.workspaceInputState.sessionBinding(name: sessionName))
                if sessionWindows.map(\.stableId) == ids {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NSError(domain: "WindowTabs", code: 4, userInfo: [NSLocalizedDescriptionKey: "The Host reordered the tabs, but its refreshed state has not arrived yet."])
        }

        private func selectTerminalWindow(_ target: TmuxWindow, preferredPaneID: String? = nil) {
            pendingSimulatorRequest = nil
            fileWorkspace.hasPendingTerminalSelection = false
            browserSelection.selectedID = nil
            simulatorSelection.selectedID = nil
            fileWorkspace.selectedID = nil
            cancelCreationFollowUp()
            selectedWindowId = target.id
            activePaneId = FileBrowserTab.sourcePaneID(
                in: target.panes.map(\.paneId), focusedPaneID: preferredPaneID, activePaneID: target.activePane?.paneId
            )
            requestAutomaticTabFit(windowID: target.stableId)
            if relayClient.isHostConnected {
                let binding = relayClient.workspaceInputState.windowBinding(target: target.stableId)
                Task { await sendCommand(.selectTmuxWindow, paneId: target.stableId, inputBinding: binding) }
            }
        }

        private func selectAdjacentWindow(from sourceWindowID: String, direction: TerminalWindowSwipePolicy.Direction) {
            guard
                window?.id == sourceWindowID, fileWorkspace.selectedID == nil, browserSelection.selectedID == nil && simulatorSelection.selectedID == nil,
                !showsWindowTabs, !creationSheetIsPresented, !quickActionPresentation.suspendsTerminalInput,
                let targetID = WindowSelectionReconciliation.adjacentWindowID(
                    from: sourceWindowID, direction: direction, in: windowSelectionCandidates
                ),
                let target = sessionWindows.first(where: { $0.id == targetID }) else { return }
            selectTerminalWindow(target)
        }

        /// Inherit the pane the iPhone is actually controlling, which may not
        /// yet match the Host's active-pane flag during a state round trip.
        private var newWindowDirectory: String {
            let pane = window?.panes.first(where: { $0.paneId == activePaneId }) ?? window?.activePane
            return pane?.currentPath.flatMap { SessionDirectoryPath.isValid($0) ? $0 : nil } ?? "~/"
        }

        private func agentTabConfiguration() -> NewAgentTabConfiguration {
            let binding = relayClient.workspaceInputState.sessionBinding(name: sessionName)
            return NewAgentTabConfiguration(
                id: .init(hostID: hostId, sessionName: sessionName),
                initialDirectory: newWindowDirectory,
                agents: sessionStore.launchAgents(for: hostId),
                directorySource: .remote(
                    hostID: hostId, connection: connectionManager.connection(for: hostId),
                    supportsBrowsing: sessionStore.hostsSupportingDirectoryBrowsing.contains(hostId),
                    supportsCreation: sessionStore.hostsSupportingDirectoryCreation.contains(hostId)
                ),
                unavailableReason: sessionStore.agentWindowLaunchUnavailableReason(
                    hostID: hostId, isConnected: relayClient.isHostConnected
                ),
                start: { request in try await createWindow(request, binding: binding) }
            )
        }

        private func createTerminalWindow() {
            let request = CreateTmuxWindow(sessionName: sessionName, workingDirectory: newWindowDirectory)
            let binding = relayClient.workspaceInputState.sessionBinding(name: sessionName)
            Task {
                do {
                    try await createWindow(request, binding: binding)
                } catch {
                    commandError = error.localizedDescription
                }
            }
        }

        private func agentForkUnavailableReason(requiresDirectory: Bool = false) -> String? {
            sessionStore.agentForkUnavailableReason(
                hostID: hostId, isConnected: relayClient.isHostConnected, requiresDirectory: requiresDirectory
            )
        }

        private func forkConfiguration(window: TmuxWindow, usingWorktree: Bool) -> AgentForkConfiguration {
            let inputState = relayClient.workspaceInputState
            let directorySource: SessionDirectorySource? = sessionStore.hostsSupportingAgentForkDirectory.contains(hostId) ? .remote(
                hostID: hostId, connection: connectionManager.connection(for: hostId),
                supportsBrowsing: sessionStore.hostsSupportingDirectoryBrowsing.contains(hostId),
                supportsCreation: sessionStore.hostsSupportingDirectoryCreation.contains(hostId)
            ) : nil
            return AgentForkConfiguration(
                sources: AgentForkConfiguration.orderedSources(panes: window.panes, focusedPaneID: activePaneId),
                usingWorktree: usingWorktree, directorySource: directorySource,
                prepare: { source in
                    if let reason = agentForkUnavailableReason() {
                        throw AgentForkError(reason)
                    }
                    let response = try await connectionManager.sendCommand(
                        PrepareAgentFork(source: source), paneId: "", hostId: hostId, timeout: 30, inputBinding: inputState.binding(paneID: source.paneID)
                    ).get()
                    guard let preparation = response.forkPreparation else {
                        throw AgentForkError("Host returned no Fork preparation.")
                    }
                    return preparation
                },
                fork: { request in try await createAgentFork(request, inputState: inputState) }
            )
        }

        private func createAgentFork(_ request: ForkAgentSession, inputState: ViewerWorkspaceInputState) async throws {
            guard !isCreatingWindow else { throw AgentForkError("A window is already being created. Please wait.") }
            if let reason = agentForkUnavailableReason(requiresDirectory: request.workingDirectory != nil) {
                throw AgentForkError(reason)
            }
            guard request.source.sessionName == sessionName else { throw AgentForkError("Reopen Fork in the source session.") }
            isCreatingWindow = true
            automaticTabFit.cancel()
            initialSessionFit?.cancel(hostID: hostId, sessionName: sessionName)
            let sessionBinding = inputState.sessionBinding(name: sessionName)
            let revision = windowCreation.begin(hostID: hostId, automaticFit: settings.newSessionAutoFit, sessionBinding: sessionBinding)
            defer {
                isCreatingWindow = false
                if windowCreation.revision == revision, windowCreation.paneID == nil {
                    windowCreation.cancel()
                }
            }
            let response = try await connectionManager.sendCommand(request, paneId: "", hostId: hostId, timeout: 180, inputBinding: inputState.binding(paneID: request.source.paneID)).get()
            _ = try sessionBinding.expectedPane(current: relayClient.workspaceInputState.sessionBinding(name: sessionName))
            guard let paneId = response.paneId else {
                throw AgentForkError("Host returned no new pane. Check its windows before retrying.")
            }
            if windowCreation.receivePaneID(paneId, revision: revision) {
                fileWorkspace.selectedID = nil
                reconcileWindowSelection(candidates: windowSelectionCandidates)
            }
            await connectionManager.requestSessionState(for: hostId)
        }

        private func createWindow(_ request: CreateTmuxWindow, binding: ViewerWorkspaceInputBinding) async throws {
            automaticTabFit.cancel()
            guard !isCreatingWindow else {
                throw NewAgentTabConfiguration.LaunchError("A window is already being created. Please wait.")
            }
            // Recheck on Start: the Host can disconnect/downgrade while the
            // sheet is open. The Host still validates the plugin and directory.
            if
                request.pluginID != nil,
                let reason = sessionStore.agentWindowLaunchUnavailableReason(
                    hostID: hostId, isConnected: relayClient.isHostConnected
                ) {
                throw NewAgentTabConfiguration.LaunchError(reason)
            }
            isCreatingWindow = true
            initialSessionFit?.cancel(hostID: hostId, sessionName: sessionName)
            let revision = windowCreation.begin(hostID: hostId, automaticFit: settings.newSessionAutoFit, sessionBinding: binding)
            defer {
                isCreatingWindow = false
                if windowCreation.revision == revision, windowCreation.paneID == nil {
                    windowCreation.cancel()
                }
            }
            let response = try await relayClient.sendCommand(request, paneId: "", inputBinding: binding).get()
            _ = try binding.expectedPane(current: relayClient.workspaceInputState.sessionBinding(name: sessionName))
            guard let paneId = response.paneId else {
                throw NewAgentTabConfiguration.LaunchError("Host returned no new pane. Check its windows before retrying.")
            }
            if windowCreation.receivePaneID(paneId, revision: revision) {
                // State may arrive before or after the command response.
                reconcileWindowSelection(candidates: windowSelectionCandidates)
            }
            await relayClient.requestSessionState()
        }

        private func reconcileWindowSelection(
            candidates: [WindowSelectionCandidate], previousCandidates: [WindowSelectionCandidate] = []
        ) {
            if !windowCreation.validateSessionBinding(relayClient.workspaceInputState.sessionBinding(name: sessionName)) {
                initialSessionFit?.cancel(hostID: hostId, sessionName: sessionName)
            }
            guard !fileWorkspace.hasPendingTerminalSelection else { return }
            if
                let restored = fileWorkspace.restoredWindowID,
                selectedWindowId == nil || (selectedWindowId == restored && activePaneId == nil),
                candidates.contains(where: { $0.windowId == restored }) {
                selectedWindowId = restored
                activePaneId = fileWorkspace.restoredPaneID
                return
            }
            let decision = WindowSelectionReconciliation.resolve(
                selectedWindowId: selectedWindowId,
                candidates: candidates,
                createdPaneId: windowCreation.paneID,
                selectedPaneId: activePaneId,
                previousCandidates: previousCandidates
            )

            switch decision {
            case .unchanged:
                return

            case let .select(windowId, paneId):
                selectedWindowId = windowId
                activePaneId = paneId
                if
                    let destination = windowCreation.takeWindowDestination(
                        selectedPaneID: paneId, paneStates: sessionStore.paneStates,
                        isConnected: relayClient.isHostConnected
                    ) {
                    initialSessionFit = destination.initialFit
                    fitCreatedTerminalIfReady()
                }
            }
        }

        private func windowContent(_ window: TmuxWindow) -> some View {
            VStack(spacing: 0) {
                if let activePaneId {
                    IOSWorkspaceDraftView(
                        paneID: activePaneId,
                        hostID: hostId,
                        activeDraftID: activeService?.responseState?.recoveryDraftID
                    )
                }
                // Response view for active pane's Claude session (full width, above layout)
                if
                    terminalIsVisible,
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
                            if !succeeded {
                                commandError = "Couldn't send the response. Check the current request and try again."
                            }
                            return succeeded
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
                            paneTerminal(pane: pane, windowName: window.windowName, windowID: window.id)
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
                    paneTerminal(pane: pane.paneState, windowName: window.windowName, windowID: window.id)
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

        private var activeCopyAction: (@MainActor () -> Void)? {
            guard let activePaneId else { return nil }
            return terminalCopyActions[activePaneId]
        }

        private func paneTerminal(pane: PaneState, windowName: String, windowID: String) -> some View {
            let preparationID = annotationHandoff.request?.id
            return LiveTerminalView(
                paneId: pane.paneId,
                hostId: hostId,
                scrollingAgentID: pane.agentSession?.pluginID,
                codexQuestionID: pane.codexQuestionID,
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
                showCopyButton: false,
                isActive: terminalIsVisible && pane.paneId == activePaneId,
                isInputSuspended: !terminalIsVisible || artifactPreview != nil || quickActionPresentation.suspendsTerminalInput,
                parentKeyboardRequested: isKeyboardActive,
                mouseReportingEnabled: mouseReportingPaneIDs.contains(pane.paneId),
                onKeyboardRequest: { isKeyboardActive = $0 },
                settings: settings,
                telemetry: pane.telemetry,
                // Tiled panes pass `responseState: .constant(nil)`, so no response
                // form is shown here and the submit closure is never invoked.
                submitResponse: { _ in false },
                onTerminalInput: { keys in
                    observeTerminalInput(
                        keys,
                        paneId: pane.paneId,
                        windowName: windowName
                    )
                },
                onTerminalInputQueued: { terminalInputRevision &+= 1 },
                onCancelVoiceInput: {
                    guard terminalIsVisible, pane.paneId == activePaneId else { return false }
                    return voiceSession.cancelIfPresented()
                },
                onTerminalPaste: { text in
                    guard settings.agentBackgroundMonitoringEnabled, relayClient.isHostConnected else { return }
                    backgroundMonitoring.handleTerminalPaste(text, hostId: hostId, paneId: pane.paneId)
                },
                onPasteImage: { image in
                    guard terminalIsVisible, activePaneId == pane.paneId else { return }
                    clipboardImagePaste = TerminalImagePasteRequest(paneId: pane.paneId, image: image)
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
                onExternalInputSenderChange: { sender in
                    externalInputSenders[pane.paneId] = sender
                },
                onTerminalInputReadinessChange: { readiness in
                    terminalInputReadiness[pane.paneId] = readiness
                },
                onCopyActionChange: { action in
                    terminalCopyActions[pane.paneId] = action
                },
                onViewportGridChange: { grid in
                    if viewportGrids[pane.paneId] != grid {
                        viewportGrids[pane.paneId] = grid
                    }
                },
                onSwitchWindow: { selectAdjacentWindow(from: windowID, direction: $0) },
                preparationID: preparationID,
                onPresentationChange: { status in
                    if let preparationID {
                        annotationHandoff.update(status, paneID: pane.paneId, requestID: preparationID)
                    }
                }
            )
            .environment(relayClient)
        }

        private func observeTerminalInput(
            _ keys: [TmuxKey],
            paneId: String,
            windowName: String
        ) {
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .contentShape(.rect)
            .gesture(terminalBarSwipe)
        }

        // MARK: - Tmux Controls

        private var resizeToFitRequest: ResizeTmuxPane? {
            guard
                relayClient.hostSupportsTerminalFit,
                let window, let layout = TmuxLayoutParser.parse(window.windowLayout),
                relayClient.workspaceInputState.windowBinding(target: window.stableId) != .unavailable else { return nil }
            return TerminalViewportSizing.request(layout: layout, paneGrids: viewportGrids)
        }

        private func resizeWindowToFit() {
            automaticTabFit.cancel()
            cancelCreationFollowUp()
            guard
                relayClient.isHostConnected, !isResizing,
                let windowID = window?.stableId, let request = resizeToFitRequest else { return }
            resizeWindow(request, windowID: windowID)
        }

        private func cancelCreationFollowUp() {
            windowCreation.cancel()
            initialSessionFit?.cancel(hostID: hostId, sessionName: sessionName)
        }

        private func creationSheetDidDismiss() {
            creationSheetIsPresented = false
            fitTerminalIfReady()
        }

        private func requestAutomaticTabFit(windowID: String? = nil) {
            automaticTabFit.request(.init(hostID: hostId, sessionName: sessionName, windowID: windowID))
        }

        private func fitTerminalIfReady() {
            guard artifactPreview == nil else { return }
            fitCreatedTerminalIfReady()
            guard terminalIsVisible, !isResizing else { return }
            let request = automaticTabFit.takeRequest(
                for: .init(hostID: hostId, sessionName: sessionName, windowID: window?.stableId),
                isAvailable: relayClient.isHostConnected && relayClient.hostSupportsTerminalFit,
                isPresentationReady: !creationSheetIsPresented && !showsWindowTabs && scenePhase == .active,
                measuredRequest: resizeToFitRequest
            )
            guard let request, let windowID = window?.stableId else { return }
            resizeWindow(request, windowID: windowID)
        }

        private func fitCreatedTerminalIfReady() {
            guard
                terminalIsVisible, !isResizing, var fit = initialSessionFit,
                fit.matches(hostID: hostId, sessionName: sessionName) else { return }
            let request = fit.takeRequest(
                isAvailable: relayClient.isHostConnected && relayClient.hostSupportsTerminalFit,
                paneIDs: window?.panes.map(\.paneId),
                measuredRequest: resizeToFitRequest,
                isPresentationReady: !creationSheetIsPresented && !showsWindowTabs,
                currentSessionBinding: relayClient.workspaceInputState.sessionBinding(name: sessionName)
            )
            // Consume before dispatch, including failures; never retry on later
            // keyboard, rotation, reconnect or geometry changes.
            if fit != initialSessionFit {
                initialSessionFit = fit
            }
            guard let request, let windowID = window?.stableId else { return }
            automaticTabFit.cancel()
            resizeWindow(request, windowID: windowID)
        }

        private func resizeWindow(_ request: ResizeTmuxPane, windowID: String) {
            isResizing = true
            let binding = relayClient.workspaceInputState.windowBinding(target: windowID)
            Task {
                defer { isResizing = false }
                let result = await relayClient.sendCommand(request, paneId: windowID, inputBinding: binding)
                do { _ = try binding.expectedPane(current: relayClient.workspaceInputState.windowBinding(target: windowID)) }
                catch { return }
                if case let .failure(error) = result {
                    commandError = "Failed to resize: \(error.localizedDescription)"
                }
            }
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
                let reference = fileWorkspaces.catalogs[hostId]?.reference(paneID: activePaneId)
                activeService = SessionDetailService(
                    paneId: activePaneId,
                    hostId: hostId,
                    sessionStore: sessionStore,
                    relayClient: relayClient,
                    onDraftChange: { [fileWorkspaces] id, text in
                        if let reference {
                            fileWorkspaces.recordDraft(id: id, pane: reference, text: text)
                        }
                    },
                    onDraftSubmitted: { [fileWorkspaces] id, text in fileWorkspaces.discardDraft(id, submittedText: text) }
                )
            }
        }

        @ViewBuilder private var sessionInfoPopover: some View {
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

        private var activePhraseContext: TerminalPhraseContext {
            let pane = window?.panes.first { $0.paneId == activePaneId }
            return TerminalPhraseContext(
                hostID: hostId,
                paneID: pane?.paneId,
                inputRevision: terminalInputRevision,
                isConnected: relayClient.isHostConnected,
                isInputAvailable: scenePhase == .active
                    && pane.map { terminalInputReadiness[$0.paneId]?() == true } == true,
                hasExternalEditor: pane?.editorSession != nil,
                hasBlockingForm: pane?.agentSession?.state.openForm?.request.isBlocking == true
            )
        }

        private func sendPhrase(_ request: TerminalPhraseRequest) -> Bool {
            guard
                request.isValid(in: activePhraseContext, savedPhrases: settings.quickPhrases.phrases),
                let paneId = request.context.target.paneID
            else { return false }
            let windowName = window?.windowName ?? ""
            guard
                enqueueToolbarKeys(request.phrase.keys, paneId: paneId, immediately: true, onSent: {
                    // Phrases are ordinary user input; retain normal prompt monitoring.
                    observeTerminalInput(request.phrase.keys, paneId: paneId, windowName: windowName)
                }) else { return false }
            return true
        }

        private func sendCustomButton(_ request: TerminalCustomButtonRequest) -> Bool {
            guard
                !quickActionPresentation.suspendsTerminalInput,
                request.isValid(in: activePhraseContext, savedButtons: settings.customButtons.buttons),
                let paneId = request.context.target.paneID else { return false }
            let keys = request.button.action.keys
            let windowName = window?.windowName ?? ""
            return enqueueToolbarKeys(keys, paneId: paneId, immediately: true, onSent: {
                observeTerminalInput(keys, paneId: paneId, windowName: windowName)
            })
        }

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
                inputRevision: terminalInputRevision
            )
        }

        private func sendAgentCommand(_ request: AgentCommandRequest) -> Bool {
            guard request.isValid(in: activeAgentCommandContext) else { return false }

            // Update the draft only after the ordered input succeeds. Executing
            // a bare command does not arm the background-turn monitor.
            let windowName = window?.windowName ?? ""
            guard
                enqueueToolbarKeys(request.keys, paneId: request.context.target.paneID, immediately: true, onSent: {
                    if request.submission == .execute {
                        backgroundMonitoring.resetTerminalInput(hostId: hostId, paneId: request.context.target.paneID)
                    } else {
                        observeTerminalInput(request.keys, paneId: request.context.target.paneID, windowName: windowName)
                    }
                })
            else { return false }
            return true
        }

        private func sendCommand(_ command: CommandType, paneId: String, inputBinding: ViewerWorkspaceInputBinding? = nil) async {
            cursorNavigationCancellations[paneId]?()
            await relayClient.send(command, paneId: paneId, inputBinding: inputBinding)
        }

        private func sendVoiceKeys(_ keys: [TmuxKey]) {
            if keys == [.escape], voiceSession.cancelIfPresented() {
                return
            }
            guard
                !keys.isEmpty,
                relayClient.isHostConnected,
                let activePaneId
            else { return }

            let windowName = window?.windowName ?? ""
            enqueueToolbarKeys(keys, paneId: activePaneId, onSent: {
                observeTerminalInput(keys, paneId: activePaneId, windowName: windowName)
            })
        }

        private func insertVoiceTranscript(_ text: String) -> Bool {
            guard
                terminalIsVisible, !quickActionPresentation.isPresented,
                activePhraseContext.canSend, let activePaneId else { return false }
            let keys: [TmuxKey] = [.text(text)]
            let windowName = window?.windowName ?? ""
            return enqueueToolbarKeys(keys, paneId: activePaneId, immediately: true, onSent: {
                observeTerminalInput(keys, paneId: activePaneId, windowName: windowName)
            })
        }

        @discardableResult
        private func enqueueToolbarKeys(
            _ keys: [TmuxKey], paneId: String, immediately: Bool = false,
            onSent: @escaping @MainActor () -> Void = { }
        ) -> Bool {
            guard externalInputSenders[paneId]?(keys, immediately, onSent) == true else { return false }
            terminalInputRevision &+= 1
            return true
        }

        private func activeVoiceInputContext() -> VoiceInputContextSnapshot? {
            guard let activePaneId else { return nil }

            var metadata: [String] = []
            if let pane = window?.panes.first(where: { $0.paneId == activePaneId }) {
                metadata = VoiceInputContext.paneMetadata(
                    sessionName: sessionName, windowName: pane.windowName,
                    command: pane.command, currentPath: pane.currentPath
                )
            }

            return VoiceInputContextSnapshot(
                paneMetadata: metadata,
                terminalText: voiceInputContextProviders[activePaneId]?()?.terminalText
            )
        }

        // MARK: - Close Window

        private func requestCloseWindow(_ window: TmuxWindow) {
            let binding = relayClient.workspaceInputState.windowBinding(target: window.stableId)
            let sessionBinding = relayClient.workspaceInputState.sessionBinding(name: window.sessionName)
            Task {
                let spec = CheckRunningProcesses(target: .window(window.stableId))
                let result = await relayClient.sendCommand(spec, paneId: "", inputBinding: binding)
                if case let .success(response) = result {
                    let processes = response.runningProcesses ?? []
                    let closesSession = sessionWindows.count == 1 && sessionWindows.first?.stableId == window.stableId
                    if processes.isEmpty, !closesSession {
                        performCloseWindow(window, inputBinding: binding)
                    } else {
                        closeConfirmation = TerminalCloseConfirmation(
                            target: window,
                            runningProcesses: processes,
                            inputBinding: closesSession ? sessionBinding : binding,
                            closesSession: closesSession
                        )
                    }
                } else if case let .failure(error) = result {
                    commandError = error.localizedDescription
                }
            }
        }

        private func performCloseWindow(_ window: TmuxWindow, inputBinding: ViewerWorkspaceInputBinding, closesSession: Bool = false) {
            let previousCandidates = windowSelectionCandidates
            Task {
                if closesSession {
                    let result = await relayClient.sendCommand(
                        KillTmuxSession(sessionName: window.sessionName), paneId: "", inputBinding: inputBinding
                    )
                    if case .success = result {
                        // Identity-aware destinations leave when the Host removes
                        // the session from its catalog, including external closes.
                        if fileWorkspace.recoveryReference == nil {
                            dismiss()
                        }
                    } else if case let .failure(error) = result {
                        commandError = error.localizedDescription
                    }
                    return
                }
                let spec = KillTmuxWindow(windowId: window.stableId)
                let result = await relayClient.sendCommand(spec, paneId: "", inputBinding: inputBinding)
                if case .success = result {
                    // The push may precede the reply and reuse the closed index.
                    // Reconcile by the pre-command identities, preserving a new manual selection.
                    reconcileWindowSelection(
                        candidates: windowSelectionCandidates.filter { $0.stableWindowId != window.stableId },
                        previousCandidates: previousCandidates
                    )
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

#endif
