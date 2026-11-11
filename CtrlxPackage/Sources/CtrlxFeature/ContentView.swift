#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI
    import UIKit
    import UserNotifications

    /// Main entry point for the Ctrlx iOS app.
    ///
    /// Manages the app's primary state:
    /// - Shows pairing view if no hosts are paired
    /// - Shows main session view once at least one host is paired
    /// - Handles WebSocket connections for all paired hosts
    public struct ContentView: View {
        @State private var settings = IOSSettings()
        @State private var connectionManager: ViewerConnectionManager?
        @State private var sessionStore = SessionStore()
        @State private var dashboardStore = DashboardStore()
        @State private var fileWorkspaces = IOSFileBrowserWorkspaceStore()
        @State private var initializationError: String?
        @State private var foregroundBadgeHosts: Set<String> = []

        @Environment(\.scenePhase) private var scenePhase
        @State private var pushService = PushNotificationService.shared

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
            .preferredColorScheme(settings.appearanceMode.colorScheme)
            .fileBrowserCacheMaintenance()
            .task {
                #if DEBUG
                    await VoiceCorrectionBenchmarkRunner.shared.runIfRequested(
                        selectedModelID: settings.voiceCorrection.modelID
                    )
                #endif
                await fileWorkspaces.prepareRecovery()
                fileWorkspaces.retainHosts(Set(settings.pairedHosts.map(\.id)))
                await initializeConnectionManager()
                setupConnectionManagerHandlers()
                if settings.isPaired {
                    await requestPushNotificationPermissions()
                }
                await autoConnectIfNeeded()
            }
            .task(id: pushService.tokenString) {
                guard let token = pushService.tokenString, let connectionManager else { return }
                await connectionManager.sendPushTokenToAll(token)
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
            .onChange(of: foregroundBadgeCount, initial: true) { _, count in
                if let count {
                    pushService.applyBadge(count)
                }
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

        private var foregroundBadgeCount: Int? {
            guard scenePhase == .active else { return nil }
            let pairedHostIDs = Set(settings.pairedHosts.map(\.id))
            return IOSDashboardStatus.badgeCount(
                pairedHostIDs: pairedHostIDs, refreshedHostIDs: foregroundBadgeHosts, store: sessionStore
            )
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

        private func handleScenePhaseChange(_ phase: ScenePhase) {
            if phase == .background {
                fileWorkspaces.cancelUploads()
            }
            if phase != .active {
                foregroundBadgeHosts.removeAll()
                Task { await fileWorkspaces.flushRecovery() }
            } else {
                Task {
                    await connectionManager?.reconnectAllImmediately()
                    await connectionManager?.requestAllSessionStates()
                }
            }
        }

        // MARK: - Setup

        private func setupConnectionManagerHandlers() {
            guard let connectionManager else { return }

            // Let notification action taps (permission Yes/Always/No, question
            // answers — issue #710) reuse the app's live sockets instead of
            // spinning up their own connection.
            NotificationActionService.shared.connectionManager = connectionManager

            // High-frequency per-session state updates drive the sidebar badges.
            // The `AgentState` carries the open response form (no separate channel).
            connectionManager.onAgentSessionStatus = { [sessionStore] status in
                Task { @MainActor in
                    sessionStore.handleAgentStatus(status)
                }
            }

            // The complete enabled-plugin presentation set (icons/names/colors).
            connectionManager.onPluginPresentations = { [sessionStore] presentations in
                Task { @MainActor in
                    sessionStore.handlePluginPresentations(presentations)
                }
            }

            #if DEBUG
                // The action E2E harness captures context without displaying a
                // notification. Production iOS alerts arrive only through APNs.
                connectionManager.onAgentNotification = { notification in
                    guard let action = notification.action else { return }
                    NotificationActionService.shared.noteIncomingAgentNotification(
                        title: notification.title,
                        subtitle: notification.subtitle,
                        pairId: notification.pairId,
                        paneId: notification.sessionId,
                        action: action
                    )
                }
            #endif

            connectionManager.onSessionState = { [weak connectionManager, sessionStore, fileWorkspaces] state in
                guard let client = connectionManager?.connection(for: state.pairId)?.relayClient else { return }
                fileWorkspaces.update(state, client: client)
                sessionStore.handleStateUpdate(state)
                if UIApplication.shared.applicationState == .active {
                    foregroundBadgeHosts.insert(state.pairId)
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

            connectionManager.onHostDisconnected = { [sessionStore, fileWorkspaces] hostId in
                fileWorkspaces.suspendHost(hostId)
                sessionStore.clearSessions(for: hostId)
            }

            connectionManager.onTransportInterrupted = { [sessionStore, fileWorkspaces] hostId in
                fileWorkspaces.suspendHost(hostId)
                sessionStore.clearSessions(for: hostId)
            }

            connectionManager.onUnpaired = {
                [settings, sessionStore, fileWorkspaces] hostId in
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
        }

        // MARK: - Connection Manager Initialization

        private func initializeConnectionManager() async {
            guard connectionManager == nil else { return }

            do {
                let manager = try await ViewerConnectionManager()
                manager.configureQuickPhraseSync(store: settings.quickPhrases)
                connectionManager = manager
                if let token = pushService.tokenString {
                    await manager.sendPushTokenToAll(token)
                }
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
        @State private var workflowNavigation = AgentWorkflowNavigation()
        @State private var workflowDestination: SessionNavigation?

        @State private var pushService = PushNotificationService.shared

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
                    onOpenDashboard: { showingDashboard = true },
                    onOpenWorkflows: { workflowNavigation.isPresented = true }
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
                    sessionsNavigationPath = NavigationPath()
                    sessionsNavigationPath.append(destination)
                }
            }) {
                IOSDashboardView { host, session in
                    dashboardDestination = SessionNavigation(sessionName: session, hostId: host)
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $workflowNavigation.isPresented, onDismiss: {
                if let destination = workflowDestination {
                    workflowDestination = nil
                    sessionsNavigationPath = NavigationPath()
                    sessionsNavigationPath.append(destination)
                }
                if pushService.pendingDashboard {
                    openDashboardNotification()
                }
            }) {
                IOSWorkflowsView(openSession: { workflowDestination = $0 }, navigation: workflowNavigation)
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
            .task(id: pushService.pendingDeepLink) {
                guard let deepLink = pushService.pendingDeepLink else { return }
                await handleDeepLink(deepLink)
                if !Task.isCancelled, pushService.pendingDeepLink == deepLink {
                    _ = pushService.consumePendingDeepLink()
                }
            }
            .environment(\.agentWorkflowNavigation, workflowNavigation)
        }

        private func openDashboardNotification() {
            if workflowNavigation.isPresented {
                workflowNavigation.isPresented = false
                return
            }
            if showingSettings {
                showingSettings = false
                return
            }
            pushService.pendingDashboard = false
            showingDashboard = true
        }

        /// Open the exact Host pane once its session metadata is available.
        private func handleDeepLink(_ deepLink: PushNotificationService.DeepLinkInfo) async {
            dashboardDestination = nil
            workflowDestination = nil
            showingSettings = false
            showingDashboard = false
            workflowNavigation.isPresented = false

            var destination = SessionNavigation.notification(
                paneID: deepLink.paneId, hostID: deepLink.hostId, paneStates: sessionStore.paneStates
            )
            // Preserve the bounded cold-start wait; a newer notification or
            // view removal cancels this task instead of appending an old target.
            for _ in 0..<5 {
                guard destination == nil else { break }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                destination = SessionNavigation.notification(
                    paneID: deepLink.paneId, hostID: deepLink.hostId, paneStates: sessionStore.paneStates
                )
            }
            guard !Task.isCancelled, pushService.pendingDeepLink == deepLink, let destination else { return }
            sessionsNavigationPath = NavigationPath([destination])
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
