#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI
    import UserNotifications

    /// Main entry point for the Ctrlx iOS app.
    ///
    /// Manages the app's primary state:
    /// - Shows pairing view if no hosts are paired
    /// - Shows main session view once at least one host is paired
    /// - Handles WebSocket connections for all paired hosts
    /// - Manages background task to keep connections alive when backgrounded
    public struct ContentView: View {
        @State private var settings = IOSSettings()
        @State private var connectionManager: ViewerConnectionManager?
        @State private var sessionStore = SessionStore()
        @State private var dashboardStore = DashboardStore()
        @State private var fileWorkspaces = IOSFileBrowserWorkspaceStore()
        @State private var initializationError: String?

        @Environment(\.scenePhase) private var scenePhase
        @State private var pushService = PushNotificationService.shared
        @State private var backgroundTaskService = BackgroundTaskService.shared
        @State private var agentBackgroundMonitoring = AgentBackgroundMonitoringService.shared

        public init() { }

        public var body: some View {
            Group {
                if let error = initializationError {
                    ContentUnavailableView(
                        "Initialization Failed",
                        image: Symbols.exclamationmarkTriangle.rawValue,
                        description: Text(error)
                    )
                } else if let connectionManager {
                    if settings.isPaired {
                        MainView()
                            .environment(connectionManager)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                DashboardQuotaRecoveryBanner(store: dashboardStore)
                            }
                    } else if let e2ee = connectionManager.pairingService {
                        NavigationStack {
                            PairingView { pairedHost in
                                handlePairingComplete(pairedHost)
                            }
                            .e2eeService(e2ee)
                        }
                    } else {
                        // Key pair not available - shouldn't happen
                        ContentUnavailableView(
                            "Encryption Error",
                            image: Symbols.lockTriangleBadgeExclamationmark.rawValue,
                            description: Text("Unable to initialize encryption. Please restart the app.")
                        )
                    }
                } else {
                    ProgressView("Initializing...")
                }
            }
            .environment(settings)
            .environment(sessionStore)
            .environment(dashboardStore)
            .environment(fileWorkspaces)
            .environment(agentBackgroundMonitoring)
            .preferredColorScheme(settings.appearanceMode.colorScheme)
            .fileBrowserCacheMaintenance()
            .task {
                #if DEBUG
                    await VoiceCorrectionBenchmarkRunner.shared.runIfRequested(
                        selectedModelID: settings.voiceCorrection.modelID
                    )
                #endif
                agentBackgroundMonitoring.noteSceneActive(scenePhase == .active)
                agentBackgroundMonitoring.prepare()
                await fileWorkspaces.prepareRecovery()
                fileWorkspaces.retainHosts(Set(settings.pairedHosts.map(\.id)))
                await initializeConnectionManager()
                setupConnectionManagerHandlers()
                await autoConnectIfNeeded()
            }
            .task(id: dashboardMonitorHosts) {
                guard scenePhase == .active else { return }
                await dashboardStore.monitor {
                    settings.pairedHosts.map {
                        .remote($0, manager: connectionManager, usage: sessionStore.usageOverview(for: $0.id))
                    }
                }
            }
            .onChange(of: connectionManager?.managedHostIDs ?? []) {
                fileWorkspaces.retainHosts(Set(settings.pairedHosts.map(\.id)))
            }
            .onChange(of: settings.pairedHosts.map(\.id)) { _, hostIDs in
                fileWorkspaces.retainHosts(Set(hostIDs))
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onChange(of: settings.agentBackgroundMonitoringEnabled) { _, enabled in
                handleAgentBackgroundMonitoringPreferenceChange(enabled)
            }
            .alert("Workspace Recovery", isPresented: .init(
                get: { fileWorkspaces.recoveryError != nil },
                set: {
                    if !$0 {
                        fileWorkspaces.dismissRecoveryError()
                    }
                }
            )) {
                Button("OK") { fileWorkspaces.dismissRecoveryError() }
            } message: {
                Text(fileWorkspaces.recoveryError ?? "")
            }
        }

        /// Only foreground/readiness changes restart polling; ordinary session
        /// updates must not restart the timer or repeatedly query the Host.
        private var dashboardMonitorHosts: [String: Bool]? {
            guard scenePhase == .active else { return nil }
            return Dictionary(uniqueKeysWithValues: settings.pairedHosts.map { host in
                let connection = connectionManager?.connection(for: host.id)
                return (host.id, connection?.isHostConnected == true && connection?.relayClient.hostSupportsDashboard == true)
            })
        }

        private func handleAgentBackgroundMonitoringPreferenceChange(_ enabled: Bool) {
            // Enabling stores intent only. The next foreground Agent submission
            // starts the user-initiated system task; disabling still stops now.
            guard !enabled else { return }
            agentBackgroundMonitoring.stopAll()
        }

        /// Handle scene phase changes to manage background task lifecycle.
        ///
        /// When the app enters the background, we start a background task to keep
        /// the WebSocket connections alive for ~30 seconds. This allows receiving
        /// any pending events before iOS suspends the app.
        ///
        /// When returning to foreground, we immediately attempt reconnection to avoid
        /// waiting for exponential backoff timers.
        private func handleScenePhaseChange(_ phase: ScenePhase) {
            if phase != .active {
                Task { await fileWorkspaces.flushRecovery() }
            }
            // Keep the notification service's foreground flag in sync so the
            // backgrounded-only local-notification fallback fires correctly.
            pushService.setAppActive(phase == .active)
            switch phase {
            case .background:
                agentBackgroundMonitoring.noteSceneActive(false)
                // Bridge the foreground-to-background transition immediately.
                // A continued-processing task may launch later and therefore
                // cannot replace this short lease for fast Agent completions.
                if connectionManager?.anyHostConnected == true {
                    backgroundTaskService.startBackgroundTask()
                }
            case .active:
                agentBackgroundMonitoring.noteSceneActive(true)
                // End background task when returning to foreground
                backgroundTaskService.endBackgroundTask()

                // Immediately try to reconnect all connections
                Task {
                    await connectionManager?.reconnectAllImmediately()
                }
            case .inactive:
                // Transitional state - no action needed
                break
            @unknown default:
                break
            }
        }

        // MARK: - Setup

        private func setupConnectionManagerHandlers() {
            guard let connectionManager else { return }

            // Let notification action taps (permission Yes/Always/No, question
            // answers — issue #710) reuse the app's live sockets instead of
            // spinning up their own connection.
            NotificationActionService.shared.connectionManager = connectionManager
            agentBackgroundMonitoring.connectionManager = connectionManager

            // High-frequency per-session state updates drive the sidebar badges.
            // The `AgentState` carries the open response form (no separate channel).
            connectionManager.onAgentSessionStatus = {
                [pushService, sessionStore, agentBackgroundMonitoring] status in
                Task { @MainActor in
                    sessionStore.handleAgentStatus(status)
                    agentBackgroundMonitoring.handle(status) { notification in
                        guard
                            agentBackgroundMonitoring.reserveNotificationDelivery(
                                for: notification
                            ) else { return }
                        pushService.scheduleLocalNotification(
                            title: notification.title,
                            subtitle: notification.subtitle,
                            body: notification.body,
                            paneId: notification.paneId,
                            hostId: notification.hostId,
                            delay: 1,
                            backgroundOnly: true
                        )
                    }
                }
            }

            // The complete enabled-plugin presentation set (icons/names/colors).
            connectionManager.onPluginPresentations = { [sessionStore] presentations in
                Task { @MainActor in
                    sessionStore.handlePluginPresentations(presentations)
                }
            }

            // Backgrounded fallback: the relay drops the APNs push while we're
            // WS-connected, so a host's live-socket notification is the only
            // alert during the backgrounded-but-connected window. Questions also
            // alert while active, including when the user is viewing another pane.
            // Notifications carrying an open-form action context become
            // actionable local notifications, mirroring the NSE's push path.
            connectionManager.onAgentNotification = {
                [pushService, sessionStore, agentBackgroundMonitoring] notification in
                Task { @MainActor in
                    agentBackgroundMonitoring.noteNotificationReceived(notification)
                    let paneState = notification.sessionId.flatMap {
                        sessionStore.paneStates[PaneKey(pairId: notification.pairId, paneId: $0)]
                    }
                    let presentation = AgentNotificationPresentation(
                        title: notification.title,
                        subtitle: notification.subtitle,
                        body: notification.body,
                        paneState: paneState
                    )
                    // Record actionable notifications even while active — the
                    // E2E harness simulates action-button taps off this record
                    // (the notification UI itself lives in SpringBoard).
                    if let action = notification.action {
                        NotificationActionService.shared.noteIncomingAgentNotification(
                            title: presentation.title,
                            subtitle: presentation.subtitle,
                            pairId: notification.pairId,
                            paneId: notification.sessionId,
                            action: action
                        )
                    }
                    guard notification.shouldPresent(isAppActive: pushService.isAppActive) else { return }
                    guard
                        agentBackgroundMonitoring.reserveNotificationDelivery(
                            for: notification
                        ) else { return }
                    if let action = notification.action {
                        await NotificationActionService.shared.scheduleActionableLocalNotification(
                            title: presentation.title,
                            subtitle: presentation.subtitle,
                            body: presentation.body,
                            paneId: notification.sessionId,
                            hostId: notification.pairId,
                            action: action
                        )
                    } else {
                        pushService.scheduleLocalNotification(
                            title: presentation.title,
                            subtitle: presentation.subtitle,
                            body: presentation.body,
                            paneId: notification.sessionId,
                            hostId: notification.pairId
                        )
                    }
                    agentBackgroundMonitoring.noteLocalNotificationScheduled(notification)
                }
            }

            connectionManager.onSessionState = {
                [weak connectionManager, pushService, sessionStore, fileWorkspaces, agentBackgroundMonitoring] state in
                guard let client = connectionManager?.connection(for: state.pairId)?.relayClient else { return }
                fileWorkspaces.update(state, client: client)
                sessionStore.handleStateUpdate(state)
                agentBackgroundMonitoring.handle(state) { notification in
                    guard
                        agentBackgroundMonitoring.reserveNotificationDelivery(
                            for: notification
                        ) else { return }
                    pushService.scheduleLocalNotification(
                        title: notification.title,
                        subtitle: notification.subtitle,
                        body: notification.body,
                        paneId: notification.paneId,
                        hostId: notification.hostId,
                        delay: 1,
                        backgroundOnly: true
                    )
                }
            }

            connectionManager.onPartnerKeyReceived = { [settings] hostId, publicKey, keyId in
                if let host = settings.getPairing(id: hostId) {
                    let updatedHost = PairedHost(
                        id: host.id,
                        hostName: host.hostName,
                        username: host.username,
                        partnerPublicKey: publicKey,
                        partnerPublicKeyId: keyId,
                        pairedAt: host.pairedAt,
                        customName: host.customName
                    )
                    settings.updatePairing(updatedHost)
                }
            }

            connectionManager.onHostDisconnected = { [sessionStore, fileWorkspaces, agentBackgroundMonitoring] hostId in
                agentBackgroundMonitoring.removeHost(hostId)
                fileWorkspaces.suspendHost(hostId)
                sessionStore.clearSessions(for: hostId)
            }

            connectionManager.onTransportInterrupted = { [sessionStore, fileWorkspaces] hostId in
                // The Host may still be running. Clear stale UI state, but leave
                // the finite Agent monitor alive so it can drive reconnection.
                fileWorkspaces.suspendHost(hostId)
                sessionStore.clearSessions(for: hostId)
            }

            connectionManager.onUnpaired = {
                [settings, sessionStore, fileWorkspaces, agentBackgroundMonitoring] hostId in
                agentBackgroundMonitoring.removeHost(hostId)
                fileWorkspaces.removeHost(hostId)
                sessionStore.clearSessions(for: hostId)
                settings.removePairing(id: hostId)
            }
        }

        private func autoConnectIfNeeded() async {
            guard
                settings.isPaired,
                settings.autoReconnect,
                let connectionManager,
                let serverURL = URL(string: settings.externalServerURL)
            else {
                return
            }

            await connectionManager.connectAll(
                pairedHosts: settings.pairedHosts,
                serverURL: serverURL,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName
            )

            // Request push permissions if not already authorized
            if pushService.permissionStatus != .authorized {
                await requestPushNotificationPermissions()
            }

            // Send push token to all connected hosts
            if let token = pushService.tokenString {
                await connectionManager.sendPushTokenToAll(token)
            }
        }

        // MARK: - Connection Manager Initialization

        private func initializeConnectionManager() async {
            guard connectionManager == nil else { return }

            do {
                let manager = try await ViewerConnectionManager()
                manager.configureQuickPhraseSync(store: settings.quickPhrases)
                connectionManager = manager
            } catch {
                initializationError = "Failed to initialize encryption: \(error.localizedDescription)"
            }
        }

        // MARK: - Pairing

        private func handlePairingComplete(_ pairedHost: PairedHost) {
            // Add the new pairing to settings
            settings.addPairing(pairedHost)

            // Connect to the new host
            Task {
                guard let connectionManager, let serverURL = URL(string: settings.externalServerURL) else { return }

                await connectionManager.connect(
                    to: pairedHost,
                    serverURL: serverURL,
                    deviceId: settings.deviceId,
                    deviceName: settings.deviceName
                )

                // Request push notification permissions after successful pairing
                await requestPushNotificationPermissions()
            }
        }

        /// Request push notification permissions and register token with server
        private func requestPushNotificationPermissions() async {
            do {
                try await pushService.requestAuthorization()

                // Wait a brief moment for the token to be received from APNs
                try? await Task.sleep(for: .milliseconds(500))

                // If we have a token and have connections, send it to all servers
                if let token = pushService.tokenString, let connectionManager {
                    await connectionManager.sendPushTokenToAll(token)
                }
            } catch {
                // Permission denied or error - not critical, app still works without push
                print("Push notification authorization failed: \(error)")
            }
        }
    }

    // MARK: - Main View

    /// The main interface after pairing.
    ///
    /// Shows a session list with a Settings button in the toolbar that
    /// presents the SettingsView as a sheet.
    struct MainView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager
        @Environment(SessionStore.self) private var sessionStore

        @State private var sessionsNavigationPath = NavigationPath()
        @State private var showingSettings = false
        @State private var showingDashboard = false
        @State private var dashboardDestination: SessionNavigation?

        @State private var pushService = PushNotificationService.shared
        /// Tracks the currently displayed session pane ID for deep link deduplication.
        /// Set when navigating to a session, cleared when popping back to the list.
        @State private var currentlyDisplayedPaneId: String?

        var body: some View {
            // Wrapping the NavigationStack in a Group lets the `.sheet`
            // modifier sit at a peer level of the navigation transition,
            // so dismissing the Settings sheet and pushing onto the nav
            // stack don't fight each other (avoids a sleep workaround in
            // handleDeepLink).
            NavigationStack(path: $sessionsNavigationPath) {
                SessionListView(
                    navigationPath: $sessionsNavigationPath,
                    onOpenSettings: { showingSettings = true },
                    onOpenDashboard: { showingDashboard = true }
                )
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                if pushService.pendingDashboard {
                    openDashboardNotification()
                }
            }) {
                NavigationStack {
                    SettingsView(onDone: { showingSettings = false })
                }
                // Sheets present in a separate window context, so the
                // root view's `.preferredColorScheme` doesn't always
                // re-propagate after the sheet is on screen. Re-apply
                // here so toggling the picker updates the sheet's chrome.
                .preferredColorScheme(settings.appearanceMode.colorScheme)
            }
            .sheet(isPresented: $showingDashboard, onDismiss: {
                if let destination = dashboardDestination {
                    dashboardDestination = nil
                    // Replacing a one-entry path does not trigger the count observer.
                    currentlyDisplayedPaneId = nil
                    sessionsNavigationPath = NavigationPath()
                    sessionsNavigationPath.append(destination)
                }
            }) {
                IOSDashboardView { host, session in
                    dashboardDestination = SessionNavigation(sessionName: session, hostId: host)
                }
                .presentationDetents([.large])
            }
            .onChange(of: pushService.pendingDashboard) { _, pending in
                if pending {
                    openDashboardNotification()
                }
            }
            .task {
                if pushService.pendingDashboard {
                    openDashboardNotification()
                }
                await connectIfNeeded()
            }
            .onChange(of: pushService.pendingDeepLink) { _, _ in
                // Consume so the value resets to nil — a subsequent notification
                // with an identical payload would otherwise be suppressed by
                // Equatable and never re-trigger this onChange.
                if let deepLink = pushService.consumePendingDeepLink() {
                    handleDeepLink(deepLink)
                }
            }
            .onChange(of: sessionsNavigationPath.count) { _, count in
                // Clear the currently displayed pane ID when user pops back to session list
                if count == 0 {
                    currentlyDisplayedPaneId = nil
                }
            }
            .onAppear {
                // Check for pending deep link when view appears (e.g., app launched from notification)
                if let deepLink = pushService.consumePendingDeepLink() {
                    handleDeepLink(deepLink)
                }
            }
        }

        private func openDashboardNotification() {
            if showingSettings {
                showingSettings = false
                return
            }
            pushService.pendingDashboard = false
            showingDashboard = true
        }

        /// Navigate to a specific session when a deep link is received.
        ///
        /// Note: If the session no longer exists (e.g., notification was delayed and session ended),
        /// ClaudeSessionTerminalView will show an appropriate empty state.
        private func handleDeepLink(_ deepLink: PushNotificationService.DeepLinkInfo?) {
            guard let deepLink else { return }

            // Dismiss Settings sheet if open so the deep link target is visible
            showingSettings = false

            // If we're already displaying this session, don't navigate again.
            // This prevents redundant navigation when receiving multiple push
            // notifications for the same session.
            guard currentlyDisplayedPaneId != deepLink.paneId else {
                return
            }

            // We reset the navigation path first to ensure only one session detail view
            // exists in the stack. Multiple push notifications would otherwise pile up
            // session views indefinitely.
            Task { @MainActor in
                sessionsNavigationPath = NavigationPath()

                // Pane state may not be synced yet on cold start (e.g., launched via
                // push notification). Retry briefly to allow the session store to populate.
                var paneState = sessionStore.paneState(for: deepLink.paneId, hostId: deepLink.hostId)
                if paneState == nil {
                    for _ in 0..<5 {
                        try? await Task.sleep(for: .milliseconds(500))
                        paneState = sessionStore.paneState(for: deepLink.paneId, hostId: deepLink.hostId)
                        if paneState != nil {
                            break
                        }
                    }
                }

                if let paneState {
                    sessionsNavigationPath.append(SessionNavigation(sessionName: paneState.sessionName, hostId: deepLink.hostId))
                    currentlyDisplayedPaneId = deepLink.paneId
                }
            }
        }

        private func connectIfNeeded() async {
            // Connect all paired hosts if not already connected
            guard
                !connectionManager.isConnecting,
                let serverURL = URL(string: settings.externalServerURL)
            else { return }

            await connectionManager.connectAll(
                pairedHosts: settings.pairedHosts,
                serverURL: serverURL,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName
            )
        }
    }

    #Preview {
        ContentView()
    }
#endif
