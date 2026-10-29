import AppKit
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import GitWorkbench
import SwiftUI

/// The main application view showing available tmux windows in a sidebar layout
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(PairingManager.self) private var pairingManager
    @Environment(MarkdownOpenSuggestionStore.self) private var markdownOpenSuggestionStore
    @Environment(\.e2eeService) private var e2eeService: E2EEService?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive

    private let detachedWorkspace: DetachedTerminalWorkspace?
    @State private var rejectedTabDropID: UUID?

    public init() {
        self.detachedWorkspace = nil
    }

    init(detachedWorkspace: DetachedTerminalWorkspace) {
        self.detachedWorkspace = detachedWorkspace
    }

    private var tabStore: WorkbenchTabStore {
        detachedWorkspace?.tabs ?? coordinator.detachedWindows.mainTabs
    }

    private func ownsTerminal(hostID: String?, windowID: String) -> Bool {
        coordinator.detachedWindows.owner(hostID: hostID, windowID: windowID) == detachedWorkspace?.id
    }

    private func terminalSession(_ target: DetachedTerminalTarget) -> String? {
        if let host = target.hostID {
            return coordinator.remoteSessionStore?.windows(for: host).first { $0.stableId == target.windowID }?.sessionName
        }
        return tmuxService.windows.first { $0.stableId == target.windowID }?.sessionName
    }

    private func adoptCreatedWindow(hostID: String?, windowID: String) {
        guard
            let detachedWorkspace, coordinator.detachedWindows.workspaces[detachedWorkspace.id] != nil,
            let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID) else { return }
        coordinator.detachedWindows.merge(target, into: detachedWorkspace.id, session: terminalSession)
    }

    private func selectDetachedWorkspace() {
        guard let workspace = detachedWorkspace else { return }
        defer {
            if let windowID = workspace.selection.windowId {
                requestAutomaticTabFit(windowID: windowID)
            } else {
                automaticTabFit.cancel()
            }
        }
        let target = workspace.members.first { $0.windowID == workspace.selection.windowId }
            ?? workspace.members.first ?? workspace.anchor
        guard let session = workspace.resolvedSession(using: terminalSession) else { return }
        workspace.sessionName = session
        let tabs = tabStore.tabs(hostID: workspace.hostID, session: session)
        if let host = workspace.hostID {
            selectedWindow = nil
            selectedRemoteSession = RemoteSessionSelection(
                hostId: host,
                hostName: settings.pairedHosts.first { $0.id == host }?.displayName ?? host,
                sessionName: session
            )
            selectedRemoteWindowId = coordinator.remoteSessionStore?.windows(for: host).first { $0.stableId == target?.windowID }?.id
        } else {
            selectedRemoteSession = nil
            selectedLocalSessionName = session
            selectedWindow = tmuxService.windows.first { $0.stableId == target?.windowID }
        }
        if tabs.rightSide.contains(workspace.selection) {
            tabs.selectedRight = workspace.selection
            repairWorkspaceSelection()
            return
        }
        tabs.selectedBrowserTabId = nil
        tabs.selectedFileTabId = nil
        switch workspace.selection {
        case let .window(id): _ = tabs.selectLeftTerminalWindow(id)
        case let .file(id): tabs.selectedFileTabId = id
        case let .browser(id): tabs.selectedBrowserTabId = id
        default: break
        }
        repairWorkspaceSelection()
    }

    private func recordWorkspacePresentation() {
        guard coordinator.workspaceRecoveryReady, tabStore.restoredSelection == nil else { return }
        if let remote = selectedRemoteSession {
            if coordinator.remoteSessionStore?.hasReceivedState(for: remote.hostId) == true {
                tabStore.recoverySelection = .init(hostID: remote.hostId, sessionName: remote.sessionName, windowID: selectedRemoteWindow?.stableId)
            }
        } else if let name = currentLocalSession()?.sessionName {
            tabStore.recoverySelection = .init(hostID: nil, sessionName: name, windowID: selectedWindow?.stableId)
        }
        for (name, browser) in fileBrowserStates {
            tabStore.recoveryFileTrees[name] = SavedFileTree(sidebarWidth: browser.sidebarWidth)
        }
        for (name, git) in gitWorkbenchStores {
            tabStore.recordGitState(git.snapshot, for: name)
        }
    }

    private func recordUserTabSelection() {
        guard
            coordinator.workspaceRecoveryReady, coordinator.workspaceRecovery?.phase != .restoring,
            let session = selectedRemoteSession?.sessionName ?? currentLocalSession()?.sessionName else { return }
        tabStore.userDidSelectTab(hostID: selectedRemoteSession?.hostId, session: session)
    }

    private func applyRecoveredWorkspacePresentation() {
        guard
            coordinator.workspaceRecoveryReady,
            let selection = tabStore.restoredSelection else { return }
        if let hostID = selection.hostID {
            selectedWindow = nil
            selectedRemoteSession = .init(hostId: hostID, hostName: settings.pairedHosts.first { $0.id == hostID }?.displayName ?? hostID, sessionName: selection.sessionName)
            selectedRemoteWindowId = remoteSessionWindows(hostId: hostID, sessionName: selection.sessionName).first { $0.stableId == selection.windowID }?.id
            tabStore.recoverySelection = selection
            tabStore.restoredSelection = nil
            return
        }
        guard
            tmuxService.sessions.contains(where: { $0.sessionName == selection.sessionName }) else { return }
        selectedRemoteSession = nil
        selectedLocalSessionName = selection.sessionName
        selectedWindow = tmuxService.windows.first { $0.sessionName == selection.sessionName && $0.stableId == selection.windowID }
        for (name, saved) in tabStore.recoveryFileTrees {
            if fileBrowserStates[name] == nil {
                fileBrowserStates[name] = FileBrowserState()
            }
            fileBrowserStates[name]?.sidebarWidth = saved.sidebarWidth
        }
        for (name, path) in tabStore.recoveryGitPaths {
            ensureGitStore(sessionName: name, directoryPath: path)
        }
        tabStore.recoverySelection = selection
        tabStore.restoredSelection = nil
        repairWorkspaceSelection()
    }

    private func repairWorkspaceSelection() {
        if let remote = selectedRemoteSession {
            reconcileRemoteRightPaneSelection(
                hostId: remote.hostId,
                sessionName: remote.sessionName,
                sessionWindows: selectedRemoteSessionWindows
            )
            selectedRemoteWindowId = selectedRemoteWindow?.id
        } else if let session = currentLocalSession() {
            reconcileRightPaneSelection(sessionName: session.sessionName)
        }
    }

    private func repairLocalLeftSelection(sessionName: String, followsActive: Bool = false) {
        selectedLocalSessionName = sessionName
        detachedWorkspace?.sessionName = sessionName
        let windows = tmuxService.windows.filter { $0.sessionName == sessionName }
        let tabs = sessionFileTabsStates[sessionName]
        let id = WorkspaceTerminalSelection.leftWindowID(
            current: selectedWindow?.stableId, orderedIDs: windows.map(\.stableId),
            activeID: windows.first(where: \.isWindowActive)?.stableId,
            rightSide: tabs?.rightSideWindowIds ?? [], followsActive: followsActive && detachedWorkspace == nil,
            owns: { ownsTerminal(hostID: nil, windowID: $0) }
        )
        selectedWindow = windows.first { $0.stableId == id }
        tabs?.repairLeftContent(hasTerminal: selectedWindow != nil)
    }

    private func tabContext(hostID: String?, session: String) -> WorkbenchTabContext {
        var context = WorkbenchTabContext(workspaceID: detachedWorkspace?.id, hostID: hostID, sessionName: session, onRejected: {
            rejectedTabDropID = UUID()
        }) { drag, before, right in
            guard
                drag.hostID == hostID, drag.sessionName == session,
                coordinator.detachedWindows.transfer(drag, to: detachedWorkspace?.id, session: terminalSession) else { return false }
            tabStore.userDidSelectTab(hostID: hostID, session: session)
            let tabs = tabStore.tabs(hostID: hostID, session: session)
            tabs.tabOrder.removeAll { $0 == drag.tab }
            let index = before.flatMap { tabs.tabOrder.firstIndex(of: $0) } ?? tabs.tabOrder.endIndex
            tabs.tabOrder.insert(drag.tab, at: index)
            if right || before.map({ tabs.rightSide.contains($0) }) == true {
                tabs.rightSide.insert(drag.tab)
                tabs.selectedRight = drag.tab
            } else {
                switch drag.tab {
                case let .window(id): selectTerminalWindow(stableId: id)
                case let .file(id):
                    tabs.selectedFileTabId = id
                    tabs.selectedBrowserTabId = nil
                case let .browser(id):
                    tabs.selectedBrowserTabId = id
                    tabs.selectedFileTabId = nil
                default: break
                }
            }
            coordinator.agentBrowser.register(agentBrowserWorkspace)
            return true
        }
        let ids: [String]
        if let hostID {
            ids = remoteSessionWindows(hostId: hostID, sessionName: session).map(\.stableId)
        } else {
            ids = tmuxService.windows.filter { $0.sessionName == session }.map(\.stableId)
        }
        let anchor = ids.compactMap { DetachedTerminalTarget(hostID: hostID, windowID: $0) }.first
        if anchor != nil || hasIndependentResources(hostID: hostID, sessionName: session) {
            if detachedWorkspace != nil {
                context.returnToMain = { drag in
                    guard
                        drag.workspaceID == detachedWorkspace?.id,
                        coordinator.detachedWindows.returnToMain(drag, anchor: anchor, session: terminalSession) else { return }
                    openWindow(id: "panes")
                    coordinator.detachedWindows.focusNativeWindow(workspaceID: nil)
                }
            }
            context.detach = { drag, point in
                guard
                    drag.workspaceID == detachedWorkspace?.id,
                    let workspace = coordinator.detachedWindows.detach(drag, anchor: anchor, position: point, session: terminalSession) else { return }
                openWindow(id: "detached-terminal", value: workspace.id)
            }
        }
        return context
    }

    private func claimBrowser(_ id: UUID, hostID: String?, session: String, windowID: String?) {
        let owner = coordinator.detachedWindows.browserOwner(hostID: hostID, session: session, id: id, windowID: windowID)
        guard owner != detachedWorkspace?.id else { return }
        let drag = WorkbenchTabDrag(workspaceID: owner, hostID: hostID, sessionName: session, tab: .browser(id))
        coordinator.detachedWindows.transfer(drag, to: detachedWorkspace?.id, session: terminalSession)
        coordinator.agentBrowser.register(agentBrowserWorkspace)
    }

    private func hasDetachedTabs(hostID: String?, session: String) -> Bool {
        coordinator.detachedWindows.workspaces.values.contains { workspace in
            workspace.hostID == hostID && (
                workspace.tabs.existing(hostID: hostID, session: session) != nil
                    || workspace.members.contains { terminalSession($0) == session }
            )
        }
    }

    /// Selection state: either a local window or a remote session (hostId + sessionName)
    @State private var selectedWindow: LocalTmuxWindow?
    @State private var selectedLocalSessionName: String?
    @State private var terminalQuickActions = TerminalQuickActionRouter()
    @State private var agentBrowserWorkspace = AgentBrowserWorkspace()
    @State private var simulatorWorkspace = SimulatorWorkspace()
    @State private var selectedRemoteSession: RemoteSessionSelection?
    @State private var selectedRemoteWindowId: String?
    @State private var localSessionRenameRequest: String?
    @State private var attachError: String?
    @State private var pendingFileLink: TerminalFileLinkRequest?
    @State private var artifactPreviewWindow: TerminalArtifactPreviewWindowController?
    @State private var browserOpenTask: Task<Void, Never>?
    @State private var filesOpenTask: Task<Void, Never>?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var projects: [AgentProject] = []
    @State private var isLoadingProjects = false
    @State private var creatingSelection: NewSessionCreatingState?
    @State private var isCreatingAgentTab = false
    @State private var isCreatingTerminal = false
    @State private var showingSessionSwitcher = false
    @State private var pendingAgentFork: AgentForkConfiguration?
    @State private var showingNewLocalSession = false
    @State private var detailPaneSize: CGSize = .zero
    @State private var automaticTabFit = TerminalTabFit()
    @State private var closeConfirmation: CloseConfirmation?

    @State private var showingDisconnectConfirmation = false

    /// The local session whose info sheet is open, keyed by its agent pane id.
    /// The sheet reads live state from `windowManager.paneStates[id]`, so the
    /// recap / token counts keep updating while it's open.
    @State private var sessionInfoSheet: SessionInfoSheetTarget?

    /// Tracks active session pane IDs for detecting section changes
    @State private var trackedActiveSessionPaneIds: Set<String> = []
    /// ID to scroll to in the sidebar when a window moves between sections
    @State private var scrollToWindowId: String?

    /// Global frames let the remote Host drag handle resolve a destination
    /// without relying on data-drop support from `List` section headers.
    @State private var remoteHostHeaderFrames: [String: CGRect] = [:]
    @State private var remoteHostDragSourceID: String?
    @State private var remoteHostDropTargetID: String?

    /// Debounces shared terminal-layout publication while the divider moves.
    @State private var sharedLayoutSyncTask: Task<Void, Never>?

    /// Window IDs that have the file browser tab active (persists across tab/session switches)
    @State private var fileBrowserActiveWindowIds: Set<String> = []
    /// Cached file browser state per session name (tree, selection, sidebar width).
    /// Keyed by session, not window, so the explorer's selection/expansion/scroll
    /// state survives switching between windows in the same session — `loadTree`
    /// already invalidates and rebuilds the tree when `directoryPath` changes,
    /// and stale selections are cleared in that path.
    @State private var fileBrowserStates: [String: FileBrowserState] = [:]
    /// Cached open-file-tab strip per session (keyed by `sessionName`).
    private var sessionFileTabsStates: [String: SessionFileTabsState] {
        get { tabStore.local }
        nonmutating set { tabStore.local = newValue }
    }

    /// Client-private file/browser tabs per remote session. A typed key keeps
    /// identical session names on different Hosts isolated.
    private var remoteSessionTabsStates: [RemoteSessionTabsKey: SessionFileTabsState] {
        get { tabStore.remote }
        nonmutating set { tabStore.remote = newValue }
    }

    /// Cached GitWorkbench store per session name, paired with the repository
    /// path it was built for so a working-directory change rebuilds it.
    /// Retaining the store keeps the git UI state (selected workspace view,
    /// file, diff) across tab/session switches, like `fileBrowserStates`.
    @State private var gitWorkbenchStores: [String: GitStoreEntry] = [:]

    /// Vends the GitWorkbench provider (live `git` CLI, or a stable mock under
    /// `--e2e-test`). Read here to build per-session stores on demand.
    @Dependency(GitWorkbenchProviderClient.self) private var gitProviderClient

    /// UserDefaults-backed preferences (in-memory under E2E). Passed into each
    /// session's GitWorkbench config so the package can persist the diff style and
    /// column widths through the host (it never touches `UserDefaults` itself).
    @Dependency(PreferencesService.self) private var preferences

    /// In-flight terminal-link confirmation, shown when
    /// `settings.browserLinkBehavior == .ask` and the user clicks a web URL.
    @State private var pendingBrowserURLPrompt: PendingBrowserURLPrompt?

    /// Per-folder workbench persistence (see
    /// `docs/folder-layout-persistence-plan.md`). Restores open file/browser
    /// tabs + split layout when a session is first viewed.
    @Dependency(LayoutStore.self) private var layoutStore
    /// Layout pruning must finish before either the private workbench or the
    /// Host-owned terminal layout reads from disk. This also gives a cold-start
    /// Viewer a precise intermediate state: no per-session layout means
    /// "initializing", never "unsplit".
    @State private var isLayoutStoreReady = false
    /// Sessions whose workbench has already been seeded from persisted layout
    /// this app run, so seeding happens at most once per session (and re-fires
    /// for a recycled session name only after cleanup clears it).
    @State private var seededSessions: Set<String> = []
    /// Sessions currently waiting on the layout store. Auto-save must not run
    /// until that read completes, or an early shared terminal snapshot can
    /// overwrite the private file/browser layout we are about to restore.
    @State private var seedingSessions: Set<String> = []
    /// Last layout snapshot persisted per session, so an unchanged workbench
    /// doesn't trigger a redundant disk write on every tmux refresh.
    @State private var lastPersistedLayouts: [String: SavedFolderLayout] = [:]
    /// In-flight save per session, chained so rapid writes for the same session
    /// reach the store in order (avoids a stale older snapshot landing last).
    @State private var pendingLayoutSaves: [String: Task<Void, Never>] = [:]

    /// Remote counterparts of the three bookkeeping dictionaries above, keyed by
    /// `(hostId, sessionName)` so a viewer persists each remote session's
    /// private browser-tab layout the same way local sessions persist theirs
    /// (issue #608 — Scope A, viewer-local). Kept parallel to (not merged with)
    /// the local dictionaries so a remote session name can't collide with a
    /// local one, and so the host-keyed lifecycle (cleared on unpair) stays
    /// independent of the local session-name lifecycle.
    @State private var seededRemoteSessions: Set<RemoteSessionTabsKey> = []
    /// Remote sessions currently awaiting their persisted browser layout. This
    /// prevents the auto-save loop from treating a terminal-only intermediate
    /// state as the completed Viewer workbench.
    @State private var seedingRemoteSessions: Set<RemoteSessionTabsKey> = []
    @State private var lastPersistedRemoteLayouts: [RemoteSessionTabsKey: SavedFolderLayout] = [:]
    @State private var pendingRemoteLayoutSaves: [RemoteSessionTabsKey: Task<Void, Never>] = [:]

    @ViewBuilder private var workspaceContent: some View {
        if detachedWorkspace != nil {
            detailContent
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { detailPaneSize = $0 }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarContent
                    .background(settings.theme.sidebarBackgroundColor)
            } detail: {
                detailContent
                    .background(settings.theme.workspaceBackgroundColor)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { newSize in
                        if detailPaneSize != newSize {
                            detailPaneSize = newSize
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var fileLinkWorkspace: some View {
        let tabs = currentSessionTabs
        return workspaceContent
            .background(WorkbenchWindowRegistration(
                workspaceID: detachedWorkspace?.id,
                windows: coordinator.detachedWindows,
                diagnosticContext: AppKitWindowDiagnosticContext(
                    kind: detachedWorkspace == nil ? .main : .detached,
                    connection: coordinator.connectedViewerManager?.combinedState ?? .disconnected,
                    paired: settings.isPaired,
                    remote: selectedRemoteSession != nil,
                    split: tabs?.isSplit == true,
                    browserSelected: tabs?.selectedBrowserTabId != nil,
                    fileSelected: tabs?.selectedFileTabId != nil,
                    rightPaneFocused: tabs?.isRightPaneFocused == true,
                    rightBrowserSelected: tabs?.selectedRight?.kind == .browser,
                    orderedTabCount: tabs?.tabOrder.count ?? 0,
                    browserTabCount: tabs?.openBrowserTabs.count ?? 0,
                    fileTabCount: tabs?.openFileTabs.count ?? 0
                )
            ))
            .environment(\.workbenchWindowID, detachedWorkspace?.id)
            .environment(\.terminalQuickActions, terminalQuickActions)
            .environment(\.terminalViewportInteraction, fitTerminalIfViewportChanged)
            .environment(\.openTerminalFileLink) { request in pendingFileLink = request }
            .terminalFileLinkTask($pendingFileLink) { request in
                await openTerminalFile(request)
            }
            .task(id: coordinator.detachedWindows.mainRequest?.id) {
                guard detachedWorkspace == nil, let request = coordinator.detachedWindows.mainRequest else { return }
                await handleDetachedWindowRequest(request)
                if coordinator.detachedWindows.mainRequest?.id == request.id {
                    coordinator.detachedWindows.mainRequest = nil
                }
            }
            .onChange(of: coordinator.detachedWindows.sourcePaneRequest?.id) { consumeSourcePaneRequest() }
            .onChange(of: selectedWindow?.id) { pendingFileLink = nil }
            .onChange(of: selectedRemoteWindowId) { pendingFileLink = nil }
            .onChange(of: selectedRemoteSession) { pendingFileLink = nil }
            .onDisappear {
                artifactPreviewWindow?.close()
                artifactPreviewWindow = nil
            }
            .onChange(of: automaticTabFitInput) { fitSelectedTerminalIfReady() }
            .onChange(of: coordinator.pendingAgentCLILaunch, initial: true) { launchInstalledAgentIfNeeded() }
            .onChange(of: creatingSelection) { launchInstalledAgentIfNeeded() }
            .onChange(of: appearsActive) {
                guard appearsActive else { return }
                launchInstalledAgentIfNeeded()
                if automaticTabFit.target == nil {
                    requestAutomaticTabFit(windowID: focusedTerminalWindowID)
                }
                fitSelectedTerminalIfReady()
            }
            .onDisappear { automaticTabFit.cancel() }
    }

    private func launchInstalledAgentIfNeeded() {
        guard
            detachedWorkspace == nil, appearsActive, creatingSelection == nil,
            let pluginID = coordinator.pendingAgentCLILaunch else { return }
        coordinator.pendingAgentCLILaunch = nil
        createNewSession(request: .directory(
            path: FileManager.default.homeDirectoryForCurrentUser.path,
            pluginID: pluginID,
            worktree: nil,
            providerID: nil
        ))
    }

    @ViewBuilder private var workspaceLifecycle: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 0) {
            if detachedWorkspace == nil {
                AgentCLIStartupPrompt()
                DashboardQuotaRecoveryBanner(store: coordinator.dashboardStore)
                CtrlXAppUpdateBanner()
                AgentCLIUpdateBanner()
                AgentPluginUpdateBanner()
                WorkspaceRecoveryStatusView()
            }
            fileLinkWorkspace
                .fileBrowserCacheMaintenance()
        }
        .environment(\.browserAnnotationContext, browserAnnotationContext)
        .environment(\.resourceTabActions, resourceTabActions)
        .background(settings.theme.workspaceBackgroundColor)
        .containerBackground(settings.theme.workspaceBackgroundColor, for: .window)
        .toolbarBackground(settings.theme.chromeBackgroundColor, for: .windowToolbar)
        .preferredColorScheme(settings.theme.workspaceColorScheme)
        .foregroundStyle(settings.theme.workspacePrimaryTextColor)
        .tint(settings.theme.workspaceAccentColor)
        .navigationTitle(workspaceTitle)
        .toolbar(removing: .title)
        .toolbar {
            toolbarContent
        }
        .modifier(WorkbenchTabDropNotice(presentationID: $rejectedTabDropID))
        .sheet(isPresented: $showingSessionSwitcher) {
            SessionSwitcherView(items: sessionSwitcherItems, current: sidebarSessionSelection.wrappedValue) { selection in
                guard sessionSwitcherItems.contains(where: { $0.id == selection && $0.isAvailable }) else { return }
                sidebarSessionSelection.wrappedValue = selection
            }
        }
        .sheet(isPresented: $showingNewLocalSession) {
            VStack(spacing: 0) {
                localNewSessionPopover
                HStack {
                    Spacer()
                    Button("Cancel") { showingNewLocalSession = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding()
            }
        }
        .disabled(!coordinator.workspaceRecoveryReady || coordinator.workspaceRecovery?.phase == .restoring)
        .background(WorkspaceRecoveryWindowAnchor(windows: coordinator.detachedWindows, isMain: detachedWorkspace == nil))
        .background(AgentBrowserWorkspaceAnchor(workspace: agentBrowserWorkspace))
        .onChange(of: tabStore.restorationRevision, initial: true) { applyRecoveredWorkspacePresentation() }
        .onChange(of: coordinator.workspaceRecoveryReady) { applyRecoveredWorkspacePresentation() }
        .onChange(of: coordinator.detachedWindows.restoredWindowIDs, initial: true) {
            guard detachedWorkspace == nil else { return }
            let ids = coordinator.detachedWindows.restoredWindowIDs
            coordinator.detachedWindows.restoredWindowIDs = []
            for id in ids {
                openWindow(id: "detached-terminal", value: id)
            }
        }
        .background(SimulatorWorkspaceAnchor(workspace: simulatorWorkspace))
        .onAppear {
            tabStore.capturePresentation = { recordWorkspacePresentation() }
            if let detachedWorkspace {
                detachedWorkspace.onClose = { [weak service = coordinator.agentBrowser, weak workspace = agentBrowserWorkspace, weak simulator = coordinator.agentSimulator, weak simulatorWorkspace] in
                    guard let service, let workspace else { return }
                    service.unregister(workspace)
                    workspace.acceptsPane = { _ in false }
                    workspace.acceptsSession = { _ in false }
                    workspace.acceptsTab = nil
                    workspace.onCreate = { _, _ in }
                    workspace.onChange = { _ in }
                    workspace.onSelect = { _ in }
                    workspace.onClose = { _ in }
                    workspace.onDetach = { _ in }
                    if let simulator, let simulatorWorkspace {
                        simulator.unregister(simulatorWorkspace)
                        simulatorWorkspace.acceptsPane = { _ in false }
                        simulatorWorkspace.acceptsTab = nil
                    }
                }
                if tabStore.restorationRevision == 0 {
                    selectDetachedWorkspace()
                } else {
                    applyRecoveredWorkspacePresentation()
                }
            }
            if detachedWorkspace != nil {
                consumeSourcePaneRequest()
            }
            registerAgentBrowserWorkspace()
            registerSimulatorWorkspace()
        }
        .onChange(of: detachedWorkspace?.selectionRevision) {
            recordUserTabSelection()
            selectDetachedWorkspace()
        }
        .onChange(of: detachedWorkspace?.tabs.isEmpty) {
            coordinator.detachedWindows.closeEmptyWorkspaces()
        }
        .onChange(of: coordinator.hostFileTabs.tabs, initial: true) { _, tabs in
            syncHostFiles(hostID: nil, descriptors: tabs)
        }
        .onChange(of: remoteFileCatalogs, initial: true) { _, catalogs in
            for (hostID, descriptors) in catalogs {
                syncHostFiles(hostID: hostID, descriptors: descriptors)
            }
        }
        .onChange(of: coordinator.detachedWindows.presentationRevision) {
            coordinator.agentBrowser.register(agentBrowserWorkspace)
            coordinator.agentSimulator.register(simulatorWorkspace)
            repairWorkspaceSelection()
            if
                let remote = selectedRemoteSession,
                let client = coordinator.viewerConnectionManager?.connection(for: remote.hostId)?.relayClient {
                syncHostBrowserTabs(hostId: remote.hostId, sessionName: remote.sessionName, client: client)
            }
        }
        .onChange(of: tmuxService.windows.map(\.id)) { _, _ in
            coordinator.agentBrowser.register(agentBrowserWorkspace)
            coordinator.agentSimulator.register(simulatorWorkspace)
        }
        .onChange(of: coordinator.detachedWindows.targets) { _, _ in
            repairWorkspaceSelection()
            coordinator.agentBrowser.register(agentBrowserWorkspace)
            coordinator.agentSimulator.register(simulatorWorkspace)
            if
                let remote = selectedRemoteSession,
                let client = coordinator.viewerConnectionManager?.connection(for: remote.hostId)?.relayClient {
                syncHostBrowserTabs(hostId: remote.hostId, sessionName: remote.sessionName, client: client)
            }
        }
        .onDisappear {
            recordWorkspacePresentation()
            tabStore.capturePresentation = nil
            browserOpenTask?.cancel()
            filesOpenTask?.cancel()
            if detachedWorkspace == nil {
                coordinator.agentBrowser.unregister(agentBrowserWorkspace)
                coordinator.agentSimulator.unregister(simulatorWorkspace)
            }
        }
        .task(id: coordinator.workspaceRecoveryReady) {
            guard coordinator.workspaceRecoveryReady, detachedWorkspace == nil else { return }
            // Initial load only - periodic refresh is handled by MirrorWindowManager
            await refreshPanes()
            applyRecoveredWorkspacePresentation()
            await loadProjects()
            trackedActiveSessionPaneIds = windowManager.activeSessionPaneIds
            // Consume any pending menu bar selection that was set before this view appeared
            applyPendingMenuBarSelection()
            // Garbage-collect stale layout records, then seed whatever session is
            // already selected (e.g. on a cold launch re-attaching to tmux).
            await layoutStore.prune(LayoutStore.defaultMaxAge, LayoutStore.defaultMaxCount)
            // Also drop remote records for hosts we're no longer paired with;
            // local records (host `layoutHost`) are always kept (issue #608).
            await layoutStore.pruneHosts(Set(settings.pairedHosts.map(\.id)).union([layoutHost]))
            isLayoutStoreReady = true
            windowManager.initializeSharedTerminalLayoutsIfNeeded()
            seedLayoutIfNeeded()
            seedRemoteLayoutIfNeeded()
            consumeSourcePaneRequest()
        }
        .task {
            // Silently rescan every 60s so new projects appear without restarting.
            guard detachedWorkspace == nil else { return }
            while true {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                await loadProjects(showLoadingIndicator: false)
            }
        }
        .task {
            // Auto-save the live workbench layout on a steady cadence. The
            // `.onChange(of: tmuxService.panes)` hook only fires on structural
            // pane changes, but opening a file/browser tab or splitting doesn't
            // touch tmux — so persist on a timer too. The per-session change
            // check keeps the disk write rare.
            guard detachedWorkspace == nil else { return }
            while true {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                persistChangedLayouts()
                persistChangedRemoteLayouts()
            }
        }
        .modifier(AlertsModifier(
            attachError: $attachError,
            closeConfirmation: $closeConfirmation,
            onPerformClose: { performClose($0) }
        ))
        .sheet(item: $pendingBrowserURLPrompt) { prompt in
            BrowserURLConfirmationView(
                url: prompt.url,
                onResolve: { choice, rememberScope in
                    pendingBrowserURLPrompt = nil
                    resolveBrowserURLPrompt(prompt, choice: choice, rememberScope: rememberScope)
                },
                onCancel: {
                    pendingBrowserURLPrompt = nil
                }
            )
        }
        .sheet(item: $pendingAgentFork) { configuration in
            AgentForkPanel(configuration: configuration)
        }
        // Consent dialog for the editor-override conflict (issue #591). Deferred
        // to the first session so "Ctrl-G" has context; fires on whichever of
        // {session appears, probe finishes} happens last.
        .sheet(isPresented: Binding(
            get: { detachedWorkspace == nil && coordinator.isShowingEditorOverrideDialog },
            set: { coordinator.isShowingEditorOverrideDialog = $0 }
        )) {
            EditorOverrideDialog()
        }
        // Session info sheet (right-click a local session → "Session Info"),
        // the macOS counterpart to the iOS detail popover.
        .sheet(item: $sessionInfoSheet) { target in
            LocalSessionInfoSheet(paneId: target.id) {
                sessionInfoSheet = nil
            }
        }
        .onChange(of: tmuxService.sessions.isEmpty) { _, isEmpty in
            if detachedWorkspace == nil, !isEmpty {
                coordinator.maybePresentEditorOverrideDialog()
            }
        }
        .onChange(of: coordinator.editorOverrideProbeResult) {
            if detachedWorkspace == nil {
                coordinator.maybePresentEditorOverrideDialog()
            }
        }
    }

    private var paneLifecycle: some View {
        workspaceLifecycle
            .onChange(of: tmuxService.panes) { oldPanes, newPanes in
                let selectedWasClosed = selectedWindow.map { selected in
                    !newPanes.contains { $0.sessionName == selected.sessionName && $0.stableWindowId == selected.stableId }
                } ?? false
                // Ensure pane states exist for all known panes so the detail view
                // can render immediately when a window is selected (without waiting
                // for the periodic validation timer).
                windowManager.updatePaneStates(from: newPanes)

                // A session rename keeps the exact pane set but changes every
                // session/window textual ID. Migrate private view state before the
                // stale-session cleanup below can interpret the old key as deleted.
                for rename in SessionRenameMapping.detect(from: oldPanes, to: newPanes) {
                    migrateLocalSessionState(rename)
                }

                // A reorder changes executable `session:index` targets even when
                // it was initiated by a remote viewer or directly in tmux. Migrate
                // target-keyed UI state before stale-window cleanup can discard it.
                let reindexedWindowIDs = WindowReindexMapping.detect(from: oldPanes, to: newPanes)
                if !reindexedWindowIDs.isEmpty {
                    for tabs in sessionFileTabsStates.values {
                        tabs.remapWindowIDs(reindexedWindowIDs)
                    }
                    fileBrowserActiveWindowIds = Set(fileBrowserActiveWindowIds.map {
                        reindexedWindowIDs[$0] ?? $0
                    })
                }

                // Clean up explorer-active flags for windows that no longer exist
                let currentWindows = tmuxService.windows
                let currentWindowIds = Set(currentWindows.map(\.id))
                for key in fileBrowserActiveWindowIds where !currentWindowIds.contains(key) {
                    fileBrowserActiveWindowIds.remove(key)
                }

                // Prune any right-side window entries that point at terminals
                // that tmux has just removed (user typed `exit`, hit the X
                // button, killed the window, etc.). Without this, isSplit stays
                // true and the right pane shows "No Tab Selected" forever even
                // though there's no real tab on the right anymore.
                for (sessionName, tabs) in sessionFileTabsStates {
                    let liveStableIds = Set(currentWindows.lazy
                        .filter { $0.sessionName == sessionName }
                        .map(\.stableId))
                    let stale = tabs.rightSide.filter {
                        if case let .window(id) = $0 {
                            !liveStableIds.contains(id)
                        } else {
                            false
                        }
                    }
                    if !stale.isEmpty {
                        tabs.rightSide.subtract(stale)
                        if let sel = tabs.selectedRight, stale.contains(sel) {
                            tabs.selectedRight = nil
                        }
                        reconcileRightPaneSelection(sessionName: sessionName)
                    }
                }

                // Restore Host authority for every live session, not only the
                // selected one. A Viewer may open a background session first after
                // the Host restarts, so every session needs an explicit canonical
                // layout before it can accept Viewer layout requests.
                if isLayoutStoreReady {
                    windowManager.initializeSharedTerminalLayoutsIfNeeded()
                }

                // Retry seeding the selected session's private workbench in case its
                // folder only became resolvable now that panes have loaded. Cheap: a
                // no-op once the session is in `seededSessions`.
                seedLayoutIfNeeded()

                // Auto-save each session's live workbench layout (skips unchanged
                // ones). Runs before cleanup so a session still present this refresh
                // gets its final state captured.
                persistChangedLayouts()

                // Clean up session-scoped state for sessions that no longer exist
                let currentSessionNames = Set(tmuxService.sessions.map(\.sessionName))
                for key in fileBrowserStates.keys where !currentSessionNames.contains(key) {
                    fileBrowserStates.removeValue(forKey: key)
                }
                for key in sessionFileTabsStates.keys where !currentSessionNames.contains(key) {
                    sessionFileTabsStates[key]?.cancelActiveBrowserDownloads()
                    sessionFileTabsStates.removeValue(forKey: key)
                }
                // Forget seed/persist bookkeeping for removed sessions so a recycled
                // session name re-seeds from scratch next time.
                seededSessions.formIntersection(currentSessionNames)
                seedingSessions.formIntersection(currentSessionNames)
                for key in lastPersistedLayouts.keys where !currentSessionNames.contains(key) {
                    lastPersistedLayouts.removeValue(forKey: key)
                }
                // Drop the save-chain reference (not cancelled — let the final write
                // for a torn-down session land).
                for key in pendingLayoutSaves.keys where !currentSessionNames.contains(key) {
                    pendingLayoutSaves.removeValue(forKey: key)
                }
                for key in gitWorkbenchStores.keys where !currentSessionNames.contains(key) {
                    gitWorkbenchStores.removeValue(forKey: key)
                }

                // Clear pending markdown-open suggestions for removed sessions.
                for sessionName in markdownOpenSuggestionStore.suggestionsBySession.keys
                    where !currentSessionNames.contains(sessionName) {
                    markdownOpenSuggestionStore.sessionRemoved(sessionName: sessionName)
                }

                guard let sessionName = currentLocalSession()?.sessionName ?? selectedWindow?.sessionName else { return }
                // Metadata refreshes must not overwrite a restored or optimistic
                // selection with tmux's unchanged active-window value.
                let previousActive = oldPanes.first { $0.sessionName == sessionName && $0.isWindowActive }?.stableWindowId
                let active = newPanes.first { $0.sessionName == sessionName && $0.isWindowActive }?.stableWindowId
                let previousIDs = Set(oldPanes.filter { $0.sessionName == sessionName }.map(\.stableWindowId))
                let currentIDs = Set(newPanes.filter { $0.sessionName == sessionName }.map(\.stableWindowId))
                repairLocalLeftSelection(
                    sessionName: sessionName,
                    followsActive: !selectedWasClosed && previousIDs.isSubset(of: currentIDs) && previousActive != nil && previousActive != active
                )
            }
    }

    public var body: some View {
        paneLifecycle
            .modifier(RemoteSessionStructureModifier(
                structure: RemoteSessionStructure(panes: coordinator.remoteSessionStore?.paneStates ?? [:], scopes: coordinator.remoteSessionStore?.workspaceCatalogsByHost.mapValues(\.scope) ?? [:]),
                browserCatalogs: remoteBrowserCatalogs,
                simulatorCatalogs: remoteSimulatorCatalogs,
                selection: selectedRemoteSession,
                onRename: { hostID, rename in
                    migrateRemoteSessionState(hostId: hostID, from: rename.oldName, to: rename.newName, windowIDs: rename.windowIDs)
                },
                onSyncBrowserTabs: syncRemoteBrowserCatalogs,
                onPrune: pruneStaleRemoteRightSideEntries
            ))
            .onChange(of: selectedWindow) { previous, current in
                if let current {
                    selectedLocalSessionName = current.sessionName
                }
                if
                    let current,
                    !ownsTerminal(hostID: nil, windowID: current.stableId)
                    || sessionFileTabsStates[current.sessionName]?.rightSide.contains(.window(current.stableId)) == true {
                    repairLocalLeftSelection(sessionName: current.sessionName)
                    return
                }
                let changedSelection = previous?.stableId != current?.stableId
                    || previous?.sessionName != current?.sessionName
                if previous?.sessionName != current?.sessionName {
                    applySelectedLocalSharedTerminalLayout()
                }
                // Pane dimensions, titles and process state refresh inside the same
                // selected window too. Treating those metadata updates as a user
                // selection used to make the Host resize straight back to its own
                // viewport after honoring a Viewer's resize command.
                if changedSelection {
                    handleSelectionChanged()
                }
            }
            .onChange(of: selectedRemoteSession) {
                if selectedRemoteSession == nil {
                    applySelectedLocalSharedTerminalLayout()
                } else {
                    applySelectedRemoteSharedTerminalLayout()
                }
                handleSelectionChanged()
            }
            .onChange(of: selectedRemoteWindowId) { handleSelectionChanged() }
            .onChange(of: selectedRemoteWindowSelection, initial: true) { previous, current in
                reconcileRemoteWindowSelection(previous: previous, current: current)
                if
                    let remote = selectedRemoteSession,
                    coordinator.remoteSessionStore?.hasReceivedState(for: remote.hostId) == true {
                    remoteSessionTabsStates[remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)]?
                        .repairLeftContent(hasTerminal: selectedRemoteWindow != nil)
                }
                // Retry seeding once the remote session's window (and thus its
                // folder) first resolves after panes sync — the analogue of the
                // local `onChange(of: tmuxService.panes)` seed retry. No-op once
                // the session is already seeded (issue #608).
                seedRemoteLayoutIfNeeded()
            }
            .onChange(of: settings.pairedHosts.map(\.id)) { _, currentHostIds in
                coordinator.retainWorkspaceRecoveryHosts()
                remoteHostHeaderFrames = remoteHostHeaderFrames.filter { currentHostIds.contains($0.key) }
                if let targetID = remoteHostDropTargetID, !currentHostIds.contains(targetID) {
                    remoteHostDropTargetID = nil
                }
                if let sourceID = remoteHostDragSourceID, !currentHostIds.contains(sourceID) {
                    remoteHostDragSourceID = nil
                }

                // Drop browser-tab state for hosts that are no longer paired so
                // the live `WKWebView` instances in `browserStates` aren't held
                // forever. Per-session cleanup for sessions killed on a still-
                // *connected* host is handled by `pruneStaleRemoteSessionBookkeeping`;
                // this host-level pass covers full unpair.
                let currentHostIdsSet = Set(currentHostIds)
                for key in remoteSessionTabsStates.keys where !currentHostIdsSet.contains(key.hostId) {
                    remoteSessionTabsStates[key]?.cancelActiveBrowserDownloads()
                    remoteSessionTabsStates.removeValue(forKey: key)
                }
                // Drop the per-session layout bookkeeping for unpaired hosts in
                // lockstep with `remoteSessionTabsStates` above, so it doesn't leak.
                // The on-disk records for those hosts are GC'd by `pruneHosts` on the
                // next launch (issue #608). The save-chain tasks aren't cancelled —
                // a final write for a just-unpaired host is allowed to land.
                for key in seededRemoteSessions where !currentHostIdsSet.contains(key.hostId) {
                    seededRemoteSessions.remove(key)
                }
                for key in seedingRemoteSessions where !currentHostIdsSet.contains(key.hostId) {
                    seedingRemoteSessions.remove(key)
                }
                for key in lastPersistedRemoteLayouts.keys where !currentHostIdsSet.contains(key.hostId) {
                    lastPersistedRemoteLayouts.removeValue(forKey: key)
                }
                for key in pendingRemoteLayoutSaves.keys where !currentHostIdsSet.contains(key.hostId) {
                    pendingRemoteLayoutSaves.removeValue(forKey: key)
                }
            }
            .modifier(SharedTerminalLayoutSyncModifier(
                splitSignal: currentSessionSplitSignal,
                onSplitChanged: {
                    scheduleSharedTerminalLayoutSync()
                }
            ))
            .modifier(SharedTerminalLayoutObserversModifier(
                local: selectedLocalSharedTerminalLayout,
                remote: selectedRemoteSharedTerminalLayout,
                onLocalChanged: applySelectedLocalSharedTerminalLayout,
                onRemoteChanged: applySelectedRemoteSharedTerminalLayout,
                onDisappear: {
                    sharedLayoutSyncTask?.cancel()
                }
            ))
            .focusedSceneValue(\.closeCurrentTabAction, handleCloseCurrentTab)
            .onChange(of: terminalQuickActions.active?.id) {
                guard
                    let endpoint = terminalQuickActions.active, endpoint.isAvailable,
                    endpoint.hostID == selectedRemoteSession?.hostId else { return }
                let windowID: String?
                if let hostID = endpoint.hostID {
                    windowID = coordinator.remoteSessionStore?.paneState(for: endpoint.paneID, hostId: hostID)?.stableWindowId
                } else {
                    windowID = windowManager.paneStates[endpoint.paneID]?.stableWindowId
                }
                if let windowID {
                    currentSessionTabs?.isRightPaneFocused = currentSessionTabs?.rightSide.contains(.window(windowID)) == true
                }
            }
            .modifier(menuCommands)
            .onChange(of: coordinator.pendingMenuBarSelection) {
                applyPendingMenuBarSelection()
            }
    }

    private func openSessionSwitcher() {
        showingSessionSwitcher = true
    }

    private var isPresentingSessionPicker: Bool {
        showingSessionSwitcher || showingNewLocalSession
    }

    private var menuCommands: MenuCommandsModifier {
        let newTerminal: (@MainActor () -> Void)? = canCreateTerminal && !isPresentingSessionPicker ? createTerminalTab : nil
        let switchSession: (@MainActor () -> Void)? = detachedWorkspace == nil && !isPresentingSessionPicker ? openSessionSwitcher : nil
        let voice: (@MainActor () -> Void)? = settings.showStatusBar && terminalQuickActions.active?.isAvailable == true && !isPresentingSessionPicker
            ? terminalQuickActions.toggleVoiceInput : nil
        return MenuCommandsModifier(
            onOpenContentSearch: { handleOpenContentSearch() },
            tabCount: navigableTabCount,
            canSelectAdjacentTab: canSelectAdjacentTab,
            onSelectTabAtIndex: { selectTab(at: $0) },
            onSelectPreviousTab: { selectAdjacentTab(direction: -1) },
            onSelectNextTab: { selectAdjacentTab(direction: 1) },
            onSelectPreviousSession: { selectAdjacentSession(direction: -1) },
            onSelectNextSession: { selectAdjacentSession(direction: 1) },
            onNewLocalSession: {
                showingNewLocalSession = true
            },
            onNewTerminal: newTerminal,
            onSwitchSession: switchSession,
            onToggleVoiceInput: voice,
            allowsSessionNavigation: detachedWorkspace == nil && !isPresentingSessionPicker
        )
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        Group {
            if tmuxService.isRefreshing && tmuxService.panes.isEmpty && !settings.hasRemoteHosts {
                loadingView
            } else if let error = tmuxService.lastError, tmuxService.panes.isEmpty, !settings.hasRemoteHosts {
                errorView(error)
            } else if tmuxService.panes.isEmpty && !settings.hasRemoteHosts {
                emptyView
            } else {
                windowList
            }
        }
        .frame(minWidth: 200)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading sessions...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView(
            "Error Loading Sessions",
            symbol: .exclamationmarkTriangle,
            description: message
        )
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No Sessions",
            symbol: .terminal
        )
    }

    /// Sidebar-ordered local sessions, via the shared entry point (also used
    /// by the menu bar dropdown so both surfaces cannot drift apart).
    private var sortedLocalSessions: [LocalTmuxSession] {
        SessionSortData.sortedLocalSessions(
            tmuxService.sessions,
            mode: settings.sidebarSortMode,
            paneStates: windowManager.paneStates,
            lastActivity: { windowManager.lastActivity(for: $0) },
            sidebarFields: settings.sidebarFields,
            sidebarTerminalFields: settings.sidebarTerminalFields,
            preferredSessionNames: settings.localSessionOrder
        )
    }

    private var windowList: some View {
        let sortedSessions = sortedLocalSessions

        return ScrollViewReader { proxy in
            List(selection: sidebarSessionSelection) {
                localSessionsSection(sessions: sortedSessions)
                remoteHostSections
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(settings.theme.sidebarBackgroundColor)
            .refreshable {
                await refreshPanes()
                await coordinator.viewerConnectionManager?.requestAllSessionStates()
            }
            .onChange(of: scrollToWindowId) { _, windowId in
                guard let windowId else { return }
                withAnimation {
                    proxy.scrollTo(windowId, anchor: .center)
                }
                Task { @MainActor in scrollToWindowId = nil }
            }
            .onChange(of: windowManager.activeSessionPaneIds) {
                handleActiveSessionsChanged()
            }
        }
    }

    private var sidebarSessionSelection: Binding<SidebarSessionSelection?> {
        Binding {
            if let remote = selectedRemoteSession {
                return .remote(hostID: remote.hostId, sessionName: remote.sessionName)
            }
            return currentLocalSession().map { .local(sessionName: $0.sessionName) }
        } set: { selection in
            // List can echo a programmatically restored selection. Treat only
            // an actual session change as navigation back to tmux's active tab.
            guard let selection, selection != sidebarSessionSelection.wrappedValue else { return }
            switch selection {
            case let .local(name):
                guard let session = tmuxService.sessions.first(where: { $0.sessionName == name }) else { return }
                selectLocalSession(session)
            case let .remote(hostID, name):
                guard let host = settings.pairedHosts.first(where: { $0.id == hostID }) else { return }
                selectRemoteSession(.init(hostId: hostID, hostName: host.displayName, sessionName: name))
                selectedRemoteWindowId = nil
                selectedWindow = nil
                requestAutomaticTabFit()
            }
        }
    }

    private func localSessionsSection(sessions: [LocalTmuxSession]) -> some View {
        Section {
            WorktreeStatusButton(repositories: windowManager.worktreeRepositories)
            // Host's own cross-session usage rollup (issue #598), collapsed to
            // the "Today" line until the disclosure chevron expands it.
            if let overview = coordinator.usageOverview, !overview.isEmpty {
                UsageOverviewView(overview: overview)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("usage-overview-local")
            }
            if sessions.isEmpty && settings.hasRemoteHosts {
                Text("No local sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                SessionReorderableRows(
                    sessions: sessions, sessionName: \.sessionName,
                    selection: { .local(sessionName: $0.sessionName) },
                    onMove: moveLocalSession, rowBackground: localSessionBackground,
                    onDetach: { session, point in detachSession(hostID: nil, name: session.sessionName, position: point) }
                ) { session in
                    sessionButton(session: session)
                }
            }
        } header: {
            SectionHeader(
                title: "Local",
                symbol: .house,
                newSessionButtonIdentifier: "new-session-local",
                hasManualSessionOrder: !settings.localSessionOrder.isEmpty,
                onRestoreAutomaticOrder: { settings.setLocalSessionOrder([]) }
            ) {
                localNewSessionPopover
            }
            .contextMenu {
                Button("Restore Automatic Order") { settings.setLocalSessionOrder([]) }
                    .disabled(settings.localSessionOrder.isEmpty)
            }
        }
    }

    private func moveLocalSession(_ source: String, to target: SessionDropTarget) {
        settings.setLocalSessionOrder(target.moving(sortedLocalSessions.map(\.sessionName), source: source))
    }

    private func localSessionBackground(_ session: LocalTmuxSession) -> Color? {
        guard
            settings.highlightSelectedSidebarSession, selectedRemoteSession == nil,
            let selectedWindow, session.windows.contains(where: { $0.id == selectedWindow.id }) else { return nil }
        return settings.theme.selectedSidebarRowBackgroundColor
    }

    /// The local session that owns `selectedWindow`, or nil when the current
    /// selection is remote or empty. Centralizes the "find the session for the
    /// selected window" lookup shared by the navigation title, session
    /// cycling, and ⌘⌥F content search so they all resolve it the same
    /// way.
    private func currentLocalSession() -> LocalTmuxSession? {
        guard let name = currentLocalSessionName else { return nil }
        return tmuxService.sessions.first { $0.sessionName == name }
    }

    private var currentLocalSessionName: String? {
        guard selectedRemoteSession == nil else { return nil }
        let name = detachedWorkspace?.resolvedSession(using: terminalSession)
            ?? selectedWindow?.sessionName ?? selectedLocalSessionName
        guard let name, tmuxService.containsSession(named: name) else { return nil }
        return name
    }

    /// Primary label for the currently selected session, used as the navigation title.
    /// Returns nil when nothing is selected so the default fallback can be shown.
    private var selectedSessionTitle: String? {
        if let remote = selectedRemoteSession {
            return remoteSessionPrimaryLabel(hostId: remote.hostId, sessionName: remote.sessionName)
        }
        if let session = currentLocalSession() {
            return localSessionSortData(session).primaryLabel
        }
        return nil
    }

    /// Computes the primary sidebar label for a remote session using the same logic as `RemoteHostSidebarSection.sortedSessions`.
    private func remoteSessionPrimaryLabel(hostId: String, sessionName: String) -> String? {
        guard let sessionStore = coordinator.remoteSessionStore else { return nil }
        guard let session = sessionStore.sessions(for: hostId).first(where: { $0.sessionName == sessionName }) else {
            return nil
        }
        return SessionSortData.forRemoteSession(
            session,
            sidebarFields: settings.sidebarFields,
            sidebarTerminalFields: settings.sidebarTerminalFields,
            homeDirectory: sessionStore.homeDirectoryByHost[hostId]
        ).primaryLabel
    }

    /// Sort data for a local session, via the shared builder so the sidebar
    /// and the menu bar dropdown order sessions identically.
    private func localSessionSortData(_ session: LocalTmuxSession) -> SessionSortData {
        SessionSortData.forLocalSession(
            session,
            paneStates: windowManager.paneStates,
            lastActivity: { windowManager.lastActivity(for: $0) },
            sidebarFields: settings.sidebarFields,
            sidebarTerminalFields: settings.sidebarTerminalFields
        )
    }

    @ViewBuilder
    private var remoteHostSections: some View {
        if settings.hasRemoteHosts, let sessionStore = coordinator.remoteSessionStore {
            ForEach(settings.pairedHosts) { host in
                RemoteHostSidebarSection(
                    host: host,
                    connection: coordinator.viewerConnectionManager?.connection(for: host.id),
                    sessionStore: sessionStore,
                    creatingSelection: creatingSelection,
                    selectedRemoteSession: $selectedRemoteSession,
                    isHostDragging: remoteHostDragSourceID == host.id,
                    isHostDropTargeted: remoteHostDropTargetID == host.id,
                    onHeaderFrameChange: { frame in
                        if let frame {
                            remoteHostHeaderFrames[host.id] = frame
                        } else {
                            remoteHostHeaderFrames.removeValue(forKey: host.id)
                        }
                    },
                    onHostDragChanged: { location in
                        remoteHostDragSourceID = host.id
                        remoteHostDropTargetID = remoteHostTarget(
                            for: host.id,
                            at: location
                        )
                    },
                    onHostDragEnded: { location in
                        defer {
                            remoteHostDragSourceID = nil
                            remoteHostDropTargetID = nil
                        }
                        guard let targetID = remoteHostTarget(for: host.id, at: location) else { return }
                        settings.moveHostPairing(sourceID: host.id, targetID: targetID)
                    },
                    onSelect: { selection in
                        selectRemoteSession(selection)
                        selectedRemoteWindowId = nil
                        selectedWindow = nil
                        requestAutomaticTabFit()
                    },
                    onDetachSession: { name, point in detachSession(hostID: host.id, name: name, position: point) },
                    onCreate: { request in
                        Task {
                            await createRemoteSession(on: host, request: request)
                        }
                    },
                    onRename: { [inputState = coordinator.viewerConnectionManager?.connection(for: host.id)?.relayClient.workspaceInputState] sessionName, newName in
                        renameRemoteSession(on: host, from: sessionName, to: newName, inputBinding: inputState?.sessionBinding(name: sessionName) ?? .unavailable)
                    },
                    onSetDescription: { [inputState = coordinator.viewerConnectionManager?.connection(for: host.id)?.relayClient.workspaceInputState] sessionName, description in
                        let binding = inputState?.sessionBinding(name: sessionName) ?? .unavailable
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetSessionDescription(sessionName: sessionName, description: description)
                            if case let .failure(error) = await manager.sendCommand(command, paneId: "", hostId: host.id, inputBinding: binding) {
                                attachError = error.localizedDescription
                            }
                        }
                    },
                    onSetColor: { [inputState = coordinator.viewerConnectionManager?.connection(for: host.id)?.relayClient.workspaceInputState] sessionName, color in
                        let binding = inputState?.sessionBinding(name: sessionName) ?? .unavailable
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetSessionColor(sessionName: sessionName, color: color)
                            if case let .failure(error) = await manager.sendCommand(command, paneId: "", hostId: host.id, inputBinding: binding) {
                                attachError = error.localizedDescription
                            }
                        }
                    },
                    onSetEmoji: { [inputState = coordinator.viewerConnectionManager?.connection(for: host.id)?.relayClient.workspaceInputState] sessionName, emoji in
                        let binding = inputState?.sessionBinding(name: sessionName) ?? .unavailable
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetSessionEmoji(sessionName: sessionName, emoji: emoji)
                            if case let .failure(error) = await manager.sendCommand(command, paneId: "", hostId: host.id, inputBinding: binding) {
                                attachError = error.localizedDescription
                            }
                        }
                    },
                    onSetState: { [inputState = coordinator.viewerConnectionManager?.connection(for: host.id)?.relayClient.workspaceInputState] sessionName, state in
                        let binding = inputState?.sessionBinding(name: sessionName) ?? .unavailable
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetSessionState(sessionName: sessionName, state: state)
                            if case let .failure(error) = await manager.sendCommand(command, paneId: "", hostId: host.id, inputBinding: binding) {
                                attachError = error.localizedDescription
                            }
                        }
                    },
                    onToggleYolo: { paneId, enabled in
                        guard let manager = coordinator.viewerConnectionManager else { return }
                        let binding = manager.connection(for: host.id)?.relayClient.workspaceInputState.binding(paneID: paneId) ?? .unavailable
                        Task {
                            _ = await manager.sendCommand(
                                SetYoloMode(enabled: enabled),
                                paneId: paneId,
                                hostId: host.id,
                                inputBinding: binding
                            )
                        }
                    },
                    onCloseSession: { sessionName in
                        requestCloseRemoteSession(sessionName, hostId: host.id)
                    }
                )
            }
        }
    }

    private func remoteHostTarget(for sourceID: String, at location: CGPoint) -> String? {
        RemoteHostDropTarget.hostID(
            at: location,
            orderedHostIDs: settings.pairedHosts.map(\.id),
            headerFrames: remoteHostHeaderFrames,
            excluding: sourceID
        )
    }

    private func sessionButton(session: LocalTmuxSession, help: String? = nil) -> some View {
        let activeWindow = session.activeWindow
        let description = activeWindow?.activePane.flatMap { windowManager.paneStates[$0.paneId]?.customDescription }
        let color = activeWindow?.activePane.flatMap { windowManager.paneStates[$0.paneId]?.customColor }
        let emoji = activeWindow?.activePane.flatMap { windowManager.paneStates[$0.paneId]?.customEmoji }
        let claudePane = session.windows.flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId] }
            .representativeAgentPane
        // Current sidebar state for the "Set State" menu: the manual override
        // (if any pane has one) wins, else the agent's own state. Matches how
        // `SessionSidebarRow` picks the indicator across the session's panes.
        let stateOverride = session.windows.lazy.flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId]?.cliSessionState }
            .first
        let displayedState = CLISessionState.displayed(
            override: stateOverride,
            agentState: claudePane?.agentSession?.state
        )
        // Compute effective progress here (and not just inside the row) so we can expose
        // a sibling AX element OUTSIDE the Button label below — when the row
        // shows a "Working" indicator, SwiftUI flips the merged button to
        // `AXBusyIndicator` and absorbs the inner `TerminalProgressBar`'s
        // separate accessibility element, dropping its `accessibilityValue`.
        // The outer mirror keeps `valueContains("60%")` queries working.
        let sessionProgress: TerminalProgressState? = session.windows
            .flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId] }
            .effectiveProgress

        return Button {
            if NSApp.currentEvent?.clickCount == 2 {
                localSessionRenameRequest = session.sessionName
            } else {
                selectLocalSession(session)
            }
        } label: {
            SessionSidebarRow(session: session)
        }
        .id(session.sessionName)
        .buttonStyle(.plain)
        .help(help ?? "")
        .accessibilityChildren {
            // When the row contains a "Working" ProgressView, SwiftUI merges
            // the Button's children into one `AXBusyIndicator` element and
            // its numeric value clobbers the inner `TerminalProgressBar`'s
            // string `accessibilityValue`. The proxy injects an AX-only child
            // that sits outside that merge so e2e queries (and VoiceOver) can
            // read `Terminal progress` + `60%` regardless of working status.
            SessionProgressAccessibilityProxy(progress: sessionProgress)
        }
        .modifier(SessionWorktreeStatusModifier(
            repositories: windowManager.worktreeRepositories,
            paths: Set(session.windows.flatMap(\.panes).compactMap { windowManager.paneStates[$0.paneId]?.gitWorktreePath })
        ))
        .modifier(DescriptionEditingModifier(
            sessionName: session.sessionName,
            currentDescription: description,
            currentEmoji: emoji,
            renameRequest: Binding(
                get: { localSessionRenameRequest == session.sessionName },
                set: { requested in
                    if !requested, localSessionRenameRequest == session.sessionName {
                        localSessionRenameRequest = nil
                    }
                }
            ),
            onRename: { sessionName, newName in
                renameLocalSession(from: sessionName, to: newName, expectedWorkspacePane: session.windows.first?.panes.first?.workspaceIdentity)
            },
            onSetDescription: { sessionName, description in
                guard let identity = session.windows.first?.panes.first?.workspaceIdentity else {
                    attachError = "The terminal is still being discovered. Try again in a moment."
                    return
                }
                Task {
                    do {
                        try await windowManager.setSessionDescription(description, for: sessionName, expectedWorkspacePane: identity)
                    } catch {
                        attachError = error.localizedDescription
                    }
                }
            },
            onSetEmoji: { sessionName, emoji in
                guard let identity = session.windows.first?.panes.first?.workspaceIdentity else {
                    attachError = "The terminal is still being discovered. Try again in a moment."
                    return
                }
                Task {
                    do {
                        try await windowManager.setSessionEmoji(emoji, for: sessionName, expectedWorkspacePane: identity)
                    } catch {
                        attachError = error.localizedDescription
                    }
                }
            },
            additionalMenu: {
                Button {
                    detachSession(hostID: nil, name: session.sessionName, position: nil)
                } label: {
                    Label("Open in New Window", symbol: .macwindow)
                }
                Divider()
                ColorContextMenuButtons(currentColor: color) { newColor in
                    guard let identity = session.windows.first?.panes.first?.workspaceIdentity else {
                        attachError = "The terminal is still being discovered. Try again in a moment."
                        return
                    }
                    Task {
                        do {
                            try await windowManager.setSessionColor(newColor, for: session.sessionName, expectedWorkspacePane: identity)
                        } catch {
                            attachError = error.localizedDescription
                        }
                    }
                }

                StateContextMenuButtons(
                    currentState: displayedState,
                    hasOverride: stateOverride != nil
                ) { newState in
                    guard
                        let identity = session.windows.first?.panes.first?.workspaceIdentity,
                        windowManager.setCLISessionState(newState, forSession: session.sessionName, expectedWorkspacePane: identity) else {
                        attachError = "The session changed. Select the restored session and try again."
                        return
                    }
                    // A pin that lowers the pending count has no notification;
                    // push the badge down explicitly (issue #702).
                    Task {
                        await coordinator.broadcastBadgeDecreaseIfNeeded()
                    }
                }

                Divider()

                if let claudePane {
                    Toggle(isOn: localYoloModeBinding(for: claudePane.paneId)) {
                        Label("Yolo Mode", symbol: .bolt)
                    }

                    Divider()
                }

                if let activeWindow, let activePane = activeWindow.activePane {
                    Button {
                        attachToTerminal(activePane)
                    } label: {
                        Label("Open in Terminal", symbol: .macwindow)
                    }

                    Divider()
                }

                Divider()

                if let claudePane {
                    Button {
                        sessionInfoSheet = SessionInfoSheetTarget(id: claudePane.paneId)
                    } label: {
                        Label("Session Info", symbol: .infoCircle)
                    }
                }

                Button(role: .destructive) {
                    requestCloseSession(session.sessionName)
                } label: {
                    Label("Close Session", symbol: .rectangleStackBadgeMinus)
                }

                Divider()
            }
        ))
    }

    // MARK: - Detail View

    /// The currently selected remote window, resolved from session store.
    /// Excludes any window pinned to the right pane (`SessionFileTabsState.rightSide`)
    /// from the "follow tmux-active" override — otherwise toggling split on
    /// the active window would leave both panes rendering it.
    private var selectedRemoteWindow: TmuxWindow? {
        guard let remote = selectedRemoteSession else { return nil }
        let windows = remoteSessionWindows(hostId: remote.hostId, sessionName: remote.sessionName)
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        let rightWindowIds = remoteSessionTabsStates[key]?.rightSideWindowIds ?? []
        let id = WorkspaceTerminalSelection.leftWindowID(
            current: windows.first { $0.id == selectedRemoteWindowId }?.stableId ?? selectedRemoteWindowId,
            orderedIDs: windows.map(\.stableId), activeID: windows.first(where: \.isWindowActive)?.stableId,
            rightSide: rightWindowIds,
            owns: { ownsTerminal(hostID: remote.hostId, windowID: $0) }
        )
        return windows.first { $0.stableId == id }
    }

    /// All windows in the selected remote session
    private var selectedRemoteSessionWindows: [TmuxWindow] {
        guard let remote = selectedRemoteSession else { return [] }
        return remoteSessionWindows(hostId: remote.hostId, sessionName: remote.sessionName)
    }

    private var selectedRemoteWindowSelection: [WorkspaceTerminalSelection.Window] {
        guard let remote = selectedRemoteSession else { return [] }
        return selectedRemoteSessionWindows.map { .init($0, hostID: remote.hostId) }
    }

    private func reconcileRemoteWindowSelection(previous: [WorkspaceTerminalSelection.Window], current: [WorkspaceTerminalSelection.Window]) {
        guard let remote = selectedRemoteSession else { return }
        let old = previous.filter { $0.hostID == remote.hostId && $0.sessionName == remote.sessionName }
        let selected = old.first { $0.id == selectedRemoteWindowId }?.stableId
            ?? current.first { $0.id == selectedRemoteWindowId }?.stableId ?? selectedRemoteWindowId
        let oldActive = old.first(where: \.isWindowActive)?.stableId
        let active = current.first(where: \.isWindowActive)?.stableId
        let tabs = remoteSessionTabsStates[remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)]
        let id = WorkspaceTerminalSelection.leftWindowID(
            current: selected, orderedIDs: current.map(\.stableId), activeID: active,
            rightSide: tabs?.rightSideWindowIds ?? [],
            followsActive: detachedWorkspace == nil && oldActive != nil && oldActive != active
                && Set(old.map(\.stableId)).isSubset(of: Set(current.map(\.stableId))),
            owns: { ownsTerminal(hostID: remote.hostId, windowID: $0) }
        )
        selectedRemoteWindowId = current.first { $0.stableId == id }?.id
    }

    @ViewBuilder
    private var detailContent: some View {
        if
            let remote = selectedRemoteSession,
            let connection = coordinator.viewerConnectionManager?.connection(for: remote.hostId) {
            let window = selectedRemoteWindow
            let windows = selectedRemoteSessionWindows.filter { ownsTerminal(hostID: remote.hostId, windowID: $0.stableId) }
            let tabsKey = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            let remoteTabs = remoteSessionTabsStates[tabsKey]
            let selectedBrowserTab: BrowserTab? = {
                guard
                    let remoteTabs,
                    let selectedId = remoteTabs.selectedBrowserTabId
                else { return nil }
                return remoteTabs.openBrowserTabs.first(where: { $0.id == selectedId })
            }()
            VStack(spacing: 0) {
                RemoteWindowTabBar(
                    windows: windows,
                    sourcePanes: selectedRemoteSessionWindows.flatMap(\.panes),
                    selectedWindow: window,
                    isHostConnected: connection.isHostConnected,
                    hasCurrentHostState: connection.isHostConnected && coordinator.remoteSessionStore?.hasReceivedState(for: remote.hostId) == true,
                    openBrowserTabs: remoteTabs?.openBrowserTabs ?? [],
                    selectedBrowserTabId: remoteTabs?.selectedBrowserTabId,
                    sessionTabs: remoteTabs,
                    onSelectWindow: { newWindow in
                        if !ownsTerminal(hostID: remote.hostId, windowID: newWindow.stableId), coordinator.detachedWindows.focus(hostID: remote.hostId, windowID: newWindow.stableId) {
                            return
                        }
                        let tabs = remoteSessionTabsStates[tabsKey]
                        let payload = TabDragPayload.window(newWindow.stableId)
                        if tabs?.rightSide.contains(payload) == true {
                            // Right-side window: route the click to the
                            // right pane's selection so the left pane
                            // keeps showing whatever it had.
                            recordUserTabSelection()
                            tabs?.selectedRight = payload
                            requestAutomaticTabFit(windowID: newWindow.stableId)
                            return
                        }
                        selectTerminalWindow(stableId: newWindow.stableId)
                    },
                    onCloseWindow: { windowToClose in
                        requestCloseRemoteWindow(windowToClose, hostId: remote.hostId)
                    },
                    onNewWindow: { createTerminalTab() },
                    agentConfiguration: agentTabConfiguration(
                        sessionName: remote.sessionName,
                        hostID: remote.hostId,
                        fallbackDirectory: window?.activePane?.currentPath
                    ),
                    forkUnavailableReason: agentForkUnavailableReason(hostID: remote.hostId),
                    supportsOtherDirectoryFork: coordinator.remoteSessionStore?.hostsSupportingAgentForkDirectory.contains(remote.hostId) == true,
                    onForkWindow: { sourceWindow, destination in
                        pendingAgentFork = agentForkConfiguration(panes: sourceWindow.panes, hostID: remote.hostId, destination: destination)
                    },
                    onOpenBrowser: { sourceWindow in
                        openPaneBrowser(
                            hostID: remote.hostId,
                            sessionName: remote.sessionName,
                            paneID: browserSourcePane(sessionName: remote.sessionName, hostID: remote.hostId, windowID: sourceWindow.id)
                        )
                    },
                    onRenameWindow: { [inputState = connection.relayClient.workspaceInputState] windowToRename, newName in
                        let binding = inputState.windowBinding(target: windowToRename.stableId)
                        Task {
                            let result = await connection.relayClient.sendCommand(
                                SetWindowName(windowId: windowToRename.stableId, name: newName),
                                paneId: "", inputBinding: binding
                            )
                            if case let .failure(error) = result {
                                attachError = error.localizedDescription
                            }
                            if case let .success(response) = result, !response.success {
                                attachError = response.error
                            }
                        }
                    },
                    onSelectBrowserTab: { tabId in
                        selectRemoteBrowserTab(
                            tabId,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName
                        )
                    },
                    onCloseBrowserTab: { tabId in
                        closeRemoteBrowserTab(
                            tabId,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName
                        )
                    },
                    onToggleSplit: { payload in
                        toggleRemoteSplit(payload, hostId: remote.hostId, sessionName: remote.sessionName)
                    },
                    onReorderWindows: { newOrder, rollbackOrder in
                        reorderRemoteWindows(
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            to: newOrder,
                            rollbackOrder: rollbackOrder,
                            connection: connection
                        )
                    },
                    onReorderBrowserTabs: { newOrder in
                        reorderRemoteBrowserTabs(
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            to: newOrder
                        )
                    },
                    onSelectFileTab: { id in
                        selectRemoteFileTab(id, hostID: remote.hostId, sessionName: remote.sessionName)
                    },
                    onCloseFileTab: { id in
                        closeRemoteFileTab(id, hostID: remote.hostId, sessionName: remote.sessionName)
                    },
                    onOpenFiles: { sourceWindow, new in
                        openDirectoryTab(
                            sessionName: remote.sessionName,
                            windowID: sourceWindow.id,
                            hostID: remote.hostId,
                            paneIDs: sourceWindow.panes.map(\.paneId),
                            fallbackPaneID: sourceWindow.activePane?.paneId, new: new
                        )
                    },
                    linkedTabActions: linkedTabActions(hostID: remote.hostId, sessionName: remote.sessionName),
                    onNewResource: supportsIndependentResources(hostID: remote.hostId) ? { openIndependentResource($0, hostID: remote.hostId, sessionName: remote.sessionName) } : nil,
                    onViewWorkflow: { pane in openWorkflow(for: pane, hostID: remote.hostId) },
                    onDetachWindow: { sourceWindow, point in
                        detachTerminal(hostID: remote.hostId, windowID: sourceWindow.stableId, position: point)
                    }
                )
                .environment(\.workbenchTabContext, tabContext(hostID: remote.hostId, session: remote.sessionName))

                remoteDetailContentArea(
                    remote: remote,
                    connection: connection,
                    window: window,
                    sessionTabs: remoteTabs,
                    selectedBrowserTab: selectedBrowserTab
                )
                .backgroundPreferenceValue(WorkbenchTabSwipeExclusionKey.self) { exclusions in
                    if let remoteTabs {
                        GeometryReader { geometry in
                            WorkbenchTabSwipe(
                                tabs: remoteTabs,
                                isEnabled: !isPresentingSessionPicker,
                                excludedRects: exclusions.map { geometry[$0] },
                                allowsSwipe: { remoteTabs.allowsTabSwipe(onRight: $0) },
                                onSwipe: selectSwipedTab
                            )
                        }
                    }
                }
            }
            .background {
                if let remoteTabs {
                    WorkbenchSplitFocus(tabs: remoteTabs, onInteraction: recordUserTabSelection)
                }
            }
            .id("\(remote.hostId)-\(remote.sessionName)")
        } else if let session = currentLocalSession() {
            let window = selectedWindow
            // Legacy utility-tab flags are presentation-only, never tmux targets.
            let windowID = window?.id ?? ""
            let browserState = fileBrowserStates[session.sessionName]
            let sessionTabs = sessionFileTabsStates[session.sessionName]
            let directoryPath = localDirectoryPath(sessionName: session.sessionName, window: window)
            let selectedFileTab: OpenFileTab? = {
                guard let sessionTabs, let id = sessionTabs.selectedFileTabId else { return nil }
                return sessionTabs.openFileTabs.first(where: { $0.id == id })
            }()
            let selectedBrowserTab: BrowserTab? = {
                guard let sessionTabs, let id = sessionTabs.selectedBrowserTabId else { return nil }
                return sessionTabs.openBrowserTabs.first(where: { $0.id == id })
            }()
            let isFileBrowserActive = fileBrowserActiveWindowIds.contains(windowID)
            let isGitActive = sessionTabs?.isGitSelected == true
            let isAnyFileViewActive = isFileBrowserActive || isGitActive
                || selectedFileTab != nil || selectedBrowserTab != nil
            VStack(spacing: 0) {
                if let sessionTabs {
                    WindowTabBar(
                        session: LocalTmuxSession(sessionName: session.sessionName, windows: session.windows.filter { ownsTerminal(hostID: nil, windowID: $0.stableId) }),
                        selectedWindow: window,
                        isFileBrowserSelected: isFileBrowserActive && selectedFileTab == nil && selectedBrowserTab == nil,
                        isGitBrowserSelected: isGitActive,
                        gitChangedFileCount: gitChangedFileCount(
                            sessionName: session.sessionName,
                            directoryPath: directoryPath
                        ),
                        isAnyFileViewActive: isAnyFileViewActive,
                        sessionTabs: sessionTabs,
                        onSelectWindow: { newWindow in
                            if !ownsTerminal(hostID: nil, windowID: newWindow.stableId), coordinator.detachedWindows.focus(hostID: nil, windowID: newWindow.stableId) {
                                return
                            }
                            let tabs = sessionFileTabsStates[session.sessionName]
                            let payload = TabDragPayload.window(newWindow.stableId)
                            if tabs?.rightSide.contains(payload) == true {
                                // Right-side window: route the click to the
                                // right pane's selection so the left pane
                                // keeps showing whatever it had.
                                tabs?.selectedRight = payload
                                requestAutomaticTabFit(windowID: newWindow.stableId)
                                return
                            }
                            selectTerminalWindow(stableId: newWindow.stableId)
                        },
                        onCloseWindow: { windowToClose in
                            requestCloseWindow(windowToClose)
                        },
                        onNewWindow: { createTerminalTab() },
                        agentConfiguration: agentTabConfiguration(
                            sessionName: session.sessionName,
                            hostID: nil,
                            fallbackDirectory: directoryPath
                        ),
                        onForkWindow: { sourceWindow, destination in
                            let panes = sourceWindow.panes.compactMap { coordinator.windowManager.paneStates[$0.paneId] }
                            pendingAgentFork = agentForkConfiguration(panes: panes, hostID: nil, destination: destination)
                        },
                        onOpenBrowser: { sourceWindow in
                            openPaneBrowser(
                                hostID: nil,
                                sessionName: session.sessionName,
                                paneID: browserSourcePane(sessionName: session.sessionName, hostID: nil, windowID: sourceWindow.id)
                            )
                        },
                        onRenameWindow: { windowToRename, newName in
                            guard let identity = windowToRename.panes.first?.workspaceIdentity else {
                                attachError = "The terminal is still being discovered. Try again in a moment."
                                return
                            }
                            Task {
                                do {
                                    try await tmuxService.renameWindow(target: windowToRename.stableId, name: newName, expectedWorkspacePane: identity)
                                    _ = await tmuxService.refreshPanes()
                                    await coordinator.connectedViewerManager?.pushSessionStateToAll()
                                } catch {
                                    attachError = error.localizedDescription
                                }
                            }
                        },
                        onSelectFileBrowser: {
                            if fileBrowserStates[session.sessionName] == nil {
                                fileBrowserStates[session.sessionName] = FileBrowserState()
                            }
                            if sessionFileTabsStates[session.sessionName] == nil {
                                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
                            }
                            let tabs = sessionFileTabsStates[session.sessionName]
                            if tabs?.rightSide.contains(.fileExplorer) == true {
                                // Folder button lives on the right pane:
                                // route the click to the right-side
                                // selection so the left pane is untouched.
                                tabs?.selectedRight = .fileExplorer
                                return
                            }
                            fileBrowserActiveWindowIds.insert(windowID)
                            tabs?.isGitSelected = false
                            tabs?.selectedFileTabId = nil
                            tabs?.selectedBrowserTabId = nil
                        },
                        onSelectGitBrowser: {
                            // Build the per-session store synchronously now (it's
                            // cheap) so gitPane takes its `if` branch and renders
                            // GitBrowserView immediately, instead of flashing a
                            // ProgressView for one frame while a `.task` runs.
                            // ensureGitStore is idempotent, so this is harmless when
                            // the store already exists for this folder.
                            ensureGitStore(sessionName: session.sessionName, directoryPath: directoryPath)
                            if sessionFileTabsStates[session.sessionName] == nil {
                                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
                            }
                            let tabs = sessionFileTabsStates[session.sessionName]
                            if tabs?.rightSide.contains(.git) == true {
                                // Git button lives on the right pane: route the
                                // click to the right-side selection so the left
                                // pane is untouched.
                                tabs?.selectedRight = .git
                                return
                            }
                            fileBrowserActiveWindowIds.remove(windowID)
                            tabs?.selectLeftGit()
                        },
                        onCloseGitBrowser: {
                            closeGitTab(sessionName: session.sessionName)
                        },
                        onSelectFileTab: { tabId in
                            selectFileTab(tabId, sessionName: session.sessionName, windowId: windowID)
                        },
                        onCloseFileTab: { tabId in
                            closeOpenFileTab(tabId, sessionName: session.sessionName)
                        },
                        onSelectBrowserTab: { tabId in
                            selectBrowserTab(tabId, sessionName: session.sessionName, windowId: windowID)
                        },
                        onCloseBrowserTab: { tabId in
                            closeBrowserTab(tabId, sessionName: session.sessionName)
                        },
                        onToggleSplit: { payload in
                            toggleSplit(payload, sessionName: session.sessionName, windowId: windowID)
                        },
                        onShowInFileExplorer: { path in
                            revealInFileExplorer(
                                path: path,
                                sessionName: session.sessionName,
                                windowId: windowID
                            )
                        },
                        onAcceptOpenSuggestion: { suggestion in
                            openFileInNewTab(
                                path: suggestion.filePath,
                                directoryPath: suggestion.directoryPath,
                                sessionName: session.sessionName,
                                windowId: windowID,
                                origin: openSuggestionOrigin(
                                    for: windowID,
                                    sessionName: session.sessionName
                                )
                            )
                            markdownOpenSuggestionStore.dismiss(sessionName: session.sessionName)
                        },
                        onReorderWindows: { newOrder, rollbackOrder in
                            reorderWindows(
                                in: session.sessionName,
                                to: newOrder,
                                rollbackOrder: rollbackOrder
                            )
                        },
                        onReorderFileTabs: { newOrder in
                            reorderFileTabs(in: session.sessionName, to: newOrder)
                        },
                        onReorderBrowserTabs: { newOrder in
                            reorderBrowserTabs(in: session.sessionName, to: newOrder)
                        },
                        onOpenFiles: { sourceWindow, new in
                            openDirectoryTab(
                                sessionName: session.sessionName,
                                windowID: sourceWindow.id,
                                hostID: nil,
                                paneIDs: sourceWindow.panes.map(\.paneId),
                                fallbackPaneID: sourceWindow.activePane?.paneId, new: new
                            )
                        },
                        linkedTabActions: linkedTabActions(hostID: nil, sessionName: session.sessionName),
                        onNewResource: { openIndependentResource($0, hostID: nil, sessionName: session.sessionName) },
                        onViewWorkflow: { pane in openWorkflow(for: pane, hostID: nil) },
                        onDetachWindow: { sourceWindow, point in
                            detachTerminal(hostID: nil, windowID: sourceWindow.stableId, position: point)
                        }
                    )
                    .environment(\.workbenchTabContext, tabContext(hostID: nil, session: session.sessionName))
                }

                detailContentArea(
                    window: window,
                    session: session,
                    directoryPath: directoryPath,
                    isFileBrowserActive: isFileBrowserActive,
                    isGitActive: isGitActive,
                    browserState: browserState,
                    sessionTabs: sessionFileTabsStates[session.sessionName],
                    selectedBrowserTab: selectedBrowserTab
                )
                .backgroundPreferenceValue(WorkbenchTabSwipeExclusionKey.self) { exclusions in
                    if let sessionTabs {
                        GeometryReader { geometry in
                            WorkbenchTabSwipe(
                                tabs: sessionTabs,
                                isEnabled: !isPresentingSessionPicker,
                                excludedRects: exclusions.map { geometry[$0] },
                                allowsSwipe: { sessionTabs.allowsTabSwipe(onRight: $0, leftFileBrowserActive: isFileBrowserActive) },
                                onSwipe: selectSwipedTab
                            )
                        }
                    }
                }
            }
            .background {
                if let sessionTabs {
                    WorkbenchSplitFocus(tabs: sessionTabs, onInteraction: recordUserTabSelection)
                }
            }
            .id(session.sessionName)
            .task(id: coordinator.workspaceRecoveryReady && sessionTabs?.isGitOpen == true ? directoryPath : nil) {
                guard sessionTabs?.isGitOpen == true else { return }
                // Keep an open Git tab's badge current even when another tab is selected.
                await eagerlyLoadGitStatus(
                    sessionName: session.sessionName,
                    directoryPath: directoryPath
                )
            }
        } else if tmuxService.panes.isEmpty && !settings.hasRemoteHosts {
            NewSessionContent(
                title: "New Session",
                projects: projects,
                isLoadingProjects: isLoadingProjects,
                creatingSelection: creatingSelection,
                onCreate: { request in
                    createNewSession(request: request)
                },
                launchAgents: localLaunchAgents,
                directorySource: localDirectorySource,
                pluginShortName: { coordinator.pluginRegistry?.manifest($0)?.shortName ?? $0 },
                popover: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ContentUnavailableView(
                        "Select a Window",
                        symbol: .terminal,
                        description: "Choose a window from the sidebar to view its mirror."
                    )
                    Spacer()
                }
                Spacer()
            }
        }
    }

    // MARK: - Remote Detail Body

    /// Renders the remote session detail area below the tab bar. When the
    /// session has any tabs flipped to the right pane
    /// (`SessionFileTabsState.isSplit`), draws a left pane + draggable
    /// divider + right pane laid out side by side. Otherwise renders the
    /// single-pane content unchanged.
    @ViewBuilder
    private func remoteDetailContentArea(
        remote: RemoteSessionSelection,
        connection: ViewerConnection,
        window: TmuxWindow?,
        sessionTabs: SessionFileTabsState?,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        if let sessionTabs, sessionTabs.isSplit {
            SplitDetailContent(
                sessionTabs: sessionTabs,
                left: {
                    remoteLeftPaneContent(
                        remote: remote,
                        connection: connection,
                        window: window,
                        selectedBrowserTab: selectedBrowserTab
                    )
                },
                right: {
                    remoteRightPaneContent(
                        remote: remote,
                        connection: connection,
                        sessionTabs: sessionTabs
                    )
                }
            )
        } else {
            remoteLeftPaneContent(
                remote: remote,
                connection: connection,
                window: window,
                selectedBrowserTab: selectedBrowserTab
            )
        }
    }

    @ViewBuilder
    private func remoteFilesContent(_ tab: FileBrowserTab, remote: RemoteSessionSelection, connection: ViewerConnection) -> some View {
        if
            tabStore.unavailableRemoteFileIDs.contains(tab.id)
            || !coordinator.viewerWorkspaceRecovery.allowsRendering(hostID: remote.hostId, session: remote.sessionName, store: tabStore) {
            ContentUnavailableView(
                "Files Source Unavailable", symbol: .exclamationmarkTriangle,
                description: "The saved Files tab will reconnect when its original terminal is available."
            )
        } else {
            WorkspaceFileBrowserView(tab: tab, source: .remote(hostID: remote.hostId, paneID: tab.sourcePaneID, connection: connection))
        }
    }

    /// Renders the body of a remote session's detail pane: either the live
    /// in-app browser tab content (when one is selected) or the remote tmux
    /// pane layout. Web links clicked in the remote terminal flow through
    /// `handleRemoteTerminalURLClick` so the per-domain rules and
    /// `browserLinkBehavior` prompt apply identically to local sessions.
    @ViewBuilder
    private func remoteLeftPaneContent(
        remote: RemoteSessionSelection,
        connection: ViewerConnection,
        window: TmuxWindow?,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        let tabsKey = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        if let tabs = remoteSessionTabsStates[tabsKey], let id = tabs.selectedFileTabId, let tab = tabs.directoryTabs[id] {
            remoteFilesContent(tab, remote: remote, connection: connection)
                .id(tab.id)
        } else if let selectedBrowserTab, let tab = remoteSessionTabsStates[tabsKey]?.remoteSimulatorTabs[selectedBrowserTab.id] {
            RemoteSimulatorView(tab: tab, client: connection.relayClient).id("\(tab.id):\(tab.sessionName)")
        } else if let selectedBrowserTab, let tab = remoteSessionTabsStates[tabsKey]?.remoteBrowserTabs[selectedBrowserTab.id] {
            RemoteBrowserView(tab: tab, client: connection.relayClient) { opened in
                claimBrowser(opened.id, hostID: remote.hostId, session: remote.sessionName, windowID: opened.windowID)
                syncHostBrowserTabs(hostId: remote.hostId, sessionName: remote.sessionName, client: connection.relayClient)
                selectRemoteBrowserTab(opened.id, hostId: remote.hostId, sessionName: remote.sessionName)
            }.id("\(tab.id):\(tab.sessionName)")
        } else if let selectedBrowserTab, let state = remoteSessionTabsStates[tabsKey]?.agentBrowserStates[selectedBrowserTab.id] {
            AgentBrowserTabContentView(state: state, workspaceID: agentBrowserWorkspace.id)
                .id(selectedBrowserTab.id)
        } else if
            let selectedBrowserTab,
            let browserTabState = remoteSessionTabsStates[tabsKey]?.browserStates[selectedBrowserTab.id] {
            BrowserTabContentView(
                state: browserTabState,
                onTitleChange: { newTitle in
                    updateRemoteBrowserTabTitle(
                        tabId: selectedBrowserTab.id,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        title: newTitle
                    )
                },
                onURLChange: { newURL in
                    updateRemoteBrowserTabURL(
                        tabId: selectedBrowserTab.id,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        url: newURL
                    )
                },
                onRequestNewTab: { newURL in
                    openRemoteBrowserTab(
                        url: newURL,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        originWindowId: selectedBrowserTab.originWindowId,
                        parentTabId: selectedBrowserTab.id
                    )
                },
                onRequestClose: {
                    closeRemoteBrowserTab(
                        selectedBrowserTab.id,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName
                    )
                }
            )
            .id(selectedBrowserTab.id)
        } else if let window, ownsTerminal(hostID: remote.hostId, windowID: window.stableId) {
            RemoteWindowPaneLayoutView(
                window: window,
                connection: connection,
                settings: settings,
                onOpenURL: { url, paneID, behavior in
                    handleRemoteTerminalURLClick(
                        url,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        windowId: window.id,
                        paneID: paneID,
                        behaviorOverride: behavior
                    )
                }
            )
            .modifier(DetachedTerminalPresentation(hostID: remote.hostId, windowID: window.stableId))
        } else {
            emptyLeftPane
        }
    }

    /// Renders the right pane of the remote split layout by dispatching on
    /// the `selectedRight` payload — window terminal or browser tab. File
    /// explorer / file tab payloads can't reach here for remote sessions
    /// (no source view emits them), so those branches fall back to the
    /// placeholder.
    @ViewBuilder
    private func remoteRightPaneContent(
        remote: RemoteSessionSelection,
        connection: ViewerConnection,
        sessionTabs: SessionFileTabsState
    ) -> some View {
        switch sessionTabs.selectedRight {
        case let .window(id):
            if let rightWindow = selectedRemoteSessionWindows.first(where: { $0.stableId == id }) {
                RemoteWindowPaneLayoutView(
                    window: rightWindow,
                    connection: connection,
                    settings: settings,
                    onOpenURL: { url, paneID, behavior in
                        handleRemoteTerminalURLClick(
                            url,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            windowId: rightWindow.id,
                            paneID: paneID,
                            behaviorOverride: behavior
                        )
                    }
                )
                .id("right-remote-\(rightWindow.id)")
                .modifier(DetachedTerminalPresentation(hostID: remote.hostId, windowID: rightWindow.stableId))
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case let .browser(id):
            if let tab = sessionTabs.remoteSimulatorTabs[id] {
                RemoteSimulatorView(tab: tab, client: connection.relayClient)
                    .id("\(tab.id):\(tab.sessionName)")
                    .accessibilityIdentifier("split-right-pane")
            } else if let tab = sessionTabs.remoteBrowserTabs[id] {
                RemoteBrowserView(tab: tab, client: connection.relayClient) { opened in
                    claimBrowser(opened.id, hostID: remote.hostId, session: remote.sessionName, windowID: opened.windowID)
                    syncHostBrowserTabs(hostId: remote.hostId, sessionName: remote.sessionName, client: connection.relayClient)
                    sessionTabs.rightSide.insert(.browser(opened.id))
                    selectRemoteBrowserTab(opened.id, hostId: remote.hostId, sessionName: remote.sessionName)
                }
                .id("\(tab.id):\(tab.sessionName)")
                .accessibilityIdentifier("split-right-pane")
            } else if let state = sessionTabs.agentBrowserStates[id] {
                AgentBrowserTabContentView(state: state, workspaceID: agentBrowserWorkspace.id)
                    .id(id)
                    .accessibilityIdentifier("split-right-pane")
            } else if
                let tab = sessionTabs.openBrowserTabs.first(where: { $0.id == id }),
                let tabState = sessionTabs.browserStates[id] {
                BrowserTabContentView(
                    state: tabState,
                    onTitleChange: { newTitle in
                        updateRemoteBrowserTabTitle(
                            tabId: id,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            title: newTitle
                        )
                    },
                    onURLChange: { newURL in
                        updateRemoteBrowserTabURL(
                            tabId: id,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            url: newURL
                        )
                    },
                    onRequestNewTab: { newURL in
                        openRemoteBrowserTab(
                            url: newURL,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            originWindowId: tab.originWindowId,
                            parentTabId: tab.id
                        )
                    },
                    onRequestClose: {
                        closeRemoteBrowserTab(
                            tab.id,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName
                        )
                    }
                )
                .id("right-remote-\(tab.id)")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case let .file(id):
            if let tab = sessionTabs.directoryTabs[id] {
                remoteFilesContent(tab, remote: remote, connection: connection)
                    .id(tab.id)
            } else {
                rightPanePlaceholder
            }
        case .fileExplorer,
             .git,
             nil:
            rightPanePlaceholder
        }
    }

    // MARK: - Detail Content Area (split-aware)

    /// Renders the content area below the tab bar. When the session has any
    /// tabs sent to the right pane (`SessionFileTabsState.isSplit`), draws a
    /// left pane + draggable divider + right pane laid out side by side.
    /// Otherwise renders the single-pane content unchanged.
    @ViewBuilder
    private func detailContentArea(
        window: LocalTmuxWindow?,
        session: LocalTmuxSession?,
        directoryPath: String,
        isFileBrowserActive: Bool,
        isGitActive: Bool,
        browserState: FileBrowserState?,
        sessionTabs: SessionFileTabsState?,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        if let sessionTabs, sessionTabs.isSplit, let session {
            SplitDetailContent(
                sessionTabs: sessionTabs,
                left: {
                    leftPaneContent(
                        window: window,
                        session: session,
                        directoryPath: directoryPath,
                        isFileBrowserActive: isFileBrowserActive,
                        isGitActive: isGitActive,
                        browserState: browserState,
                        sessionTabs: sessionTabs,
                        selectedBrowserTab: selectedBrowserTab
                    )
                },
                right: {
                    rightPaneContent(
                        sessionName: session.sessionName,
                        directoryPath: directoryPath,
                        browserState: browserState,
                        sessionTabs: sessionTabs
                    )
                }
            )
        } else {
            leftPaneContent(
                window: window,
                session: session,
                directoryPath: directoryPath,
                isFileBrowserActive: isFileBrowserActive,
                isGitActive: isGitActive,
                browserState: browserState,
                sessionTabs: sessionTabs,
                selectedBrowserTab: selectedBrowserTab
            )
        }
    }

    @ViewBuilder
    private func leftPaneContent(
        window: LocalTmuxWindow?,
        session: LocalTmuxSession?,
        directoryPath: String,
        isFileBrowserActive: Bool,
        isGitActive: Bool,
        browserState: FileBrowserState?,
        sessionTabs: SessionFileTabsState?,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        if let id = sessionTabs?.selectedFileTabId, let tab = sessionTabs?.directoryTabs[id] {
            WorkspaceFileBrowserView(tab: tab, source: .local(paneID: tab.sourcePaneID, tmux: tmuxService, windows: windowManager))
                .id(tab.id)
        } else if
            let sessionTabs, let id = sessionTabs.selectedFileTabId,
            let tab = sessionTabs.openFileTabs.first(where: { $0.id == id }) {
            OpenFileTabContentView(tab: tab, sessionTabs: sessionTabs)
                .id(tab.id)
        } else if let selectedBrowserTab, let state = sessionTabs?.simulatorStates[selectedBrowserTab.id] {
            SimulatorTabContentView(state: state, workspaceID: simulatorWorkspace.id)
                .id(selectedBrowserTab.id)
        } else if let selectedBrowserTab, let state = sessionTabs?.agentBrowserStates[selectedBrowserTab.id] {
            AgentBrowserTabContentView(state: state, workspaceID: agentBrowserWorkspace.id)
                .id(selectedBrowserTab.id)
        } else if
            let selectedBrowserTab,
            let session,
            let browserTabState = sessionFileTabsStates[session.sessionName]?.browserStates[selectedBrowserTab.id] {
            BrowserTabContentView(
                state: browserTabState,
                onTitleChange: { newTitle in
                    updateBrowserTabTitle(
                        tabId: selectedBrowserTab.id,
                        sessionName: session.sessionName,
                        title: newTitle
                    )
                },
                onURLChange: { newURL in
                    updateBrowserTabURL(
                        tabId: selectedBrowserTab.id,
                        sessionName: session.sessionName,
                        url: newURL
                    )
                },
                onRequestNewTab: { newURL in
                    openBrowserTab(
                        url: newURL,
                        sessionName: session.sessionName,
                        windowId: window?.id ?? "",
                        originWindowId: selectedBrowserTab.originWindowId,
                        parentTabId: selectedBrowserTab.id
                    )
                },
                onRequestClose: {
                    closeBrowserTab(selectedBrowserTab.id, sessionName: session.sessionName)
                }
            )
            .id(selectedBrowserTab.id)
        } else if
            isFileBrowserActive,
            let browserState,
            let session,
            let sessionTabs {
            FileBrowserView(
                directoryPath: directoryPath,
                state: browserState,
                sessionTabs: sessionTabs,
                onOpenFileInNewTab: { path in
                    openFileInNewTab(
                        path: path,
                        directoryPath: directoryPath,
                        sessionName: session.sessionName,
                        windowId: window?.id ?? ""
                    )
                }
            )
        } else if isGitActive, let session {
            gitPane(windowId: window?.id ?? "", sessionName: session.sessionName, directoryPath: directoryPath)
        } else if
            let window, ownsTerminal(hostID: nil, windowID: window.stableId),
            sessionTabs?.rightSide.contains(.window(window.stableId)) != true {
            WindowPaneLayoutView(
                window: window,
                onOpenURL: { url, paneID, behavior in
                    handleTerminalURLClick(
                        url,
                        directoryPath: directoryPath,
                        session: session,
                        window: window,
                        paneID: paneID,
                        behaviorOverride: behavior
                    )
                }
            )
            .modifier(DetachedTerminalPresentation(hostID: nil, windowID: window.stableId))
        } else {
            emptyLeftPane
        }
    }

    private var emptyLeftPane: some View {
        ContentUnavailableView(
            "No Tab Selected",
            symbol: .terminal,
            description: "Select a tab or create a new terminal using +."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Git tab's content (issue #258), backed by a per-session
    /// ``GitWorkbenchStore`` cached in `gitWorkbenchStores`. The store is built
    /// lazily here (in `.task`, never during `body` evaluation) so the git state
    /// survives tab/session switches, and rebuilt when the working directory
    /// changes so it tracks the same folder as the file explorer.
    @ViewBuilder
    private func gitPane(
        windowId: String,
        sessionName: String,
        directoryPath requestedPath: String
    ) -> some View {
        let existing = gitWorkbenchStores[sessionName]
        let directoryPath = existing?.retainsRecoveredDirectory == true ? existing?.path ?? requestedPath : requestedPath
        if let entry = gitWorkbenchStores[sessionName], entry.path == directoryPath {
            GitRecoveryContent(entry: entry) {
                GitBrowserView(
                    store: entry.store,
                    directoryPath: directoryPath,
                    onOpenFileInNewTab: { path in
                        openFileInNewTab(
                            path: path,
                            directoryPath: directoryPath,
                            sessionName: sessionName,
                            windowId: windowId,
                            // Remember the file came from the Git tab so closing it
                            // returns here instead of the File Explorer.
                            origin: .gitTab(windowId: windowId)
                        )
                    },
                    onShowInFileExplorer: { path in
                        revealInFileExplorer(
                            path: path,
                            sessionName: sessionName,
                            windowId: windowId
                        )
                    }
                )
            }
            .id(ObjectIdentifier(entry))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: coordinator.workspaceRecoveryReady ? directoryPath : nil) {
                    ensureGitStore(sessionName: sessionName, directoryPath: directoryPath)
                }
        }
    }

    /// Changed-file count for a session's Git tab badge (issue #573), read live
    /// from the session's cached GitWorkbench store's `summary`. The store keeps
    /// it fresh on its own (via the provider's repository watcher). Returns 0
    /// until the store exists for this directory and has finished its first load
    /// (`summary == nil`), so a clean repository shows no badge.
    @MainActor
    private func gitChangedFileCount(sessionName: String, directoryPath: String) -> Int {
        guard
            let entry = gitWorkbenchStores[sessionName],
            entry.path == directoryPath || entry.retainsRecoveredDirectory
        else { return 0 }
        return entry.store.summary?.changedFileCount ?? 0
    }

    /// Loads an open Git tab's status while another tab is selected.
    /// The per-session store and its repository watcher keep the badge current.
    @MainActor
    private func eagerlyLoadGitStatus(sessionName: String, directoryPath: String) async {
        guard coordinator.workspaceRecoveryReady else { return }
        // A recovered Git preview owns its saved directory. Only an explicit Git
        // selection may retarget it; a terminal's startup cwd must not erase it.
        if tabStore.pendingGitRecoverySessions.contains(sessionName) || gitWorkbenchStores[sessionName]?.retainsRecoveredDirectory != true {
            ensureGitStore(sessionName: sessionName, directoryPath: directoryPath)
        }
        await gitWorkbenchStores[sessionName]?.load()
    }

    /// Creates (or rebuilds, on a directory change) the cached GitWorkbench
    /// store for a session. Safe to call from `.task`/event handlers; never call
    /// it during `body` evaluation since it mutates `@State`. The working-tree
    /// root is passed as `repositoryURL` so the Changes-tab file callbacks get
    /// absolute URLs.
    @MainActor
    private func ensureGitStore(sessionName: String, directoryPath requestedPath: String) {
        guard coordinator.workspaceRecoveryReady else { return }
        let recovery = tabStore.takeGitRecovery(for: sessionName)
        let directoryPath = recovery?.directory ?? requestedPath
        if recovery == nil, let entry = gitWorkbenchStores[sessionName], entry.path == directoryPath {
            return
        }
        let provider = gitProviderClient.provider(URL(fileURLWithPath: directoryPath))
        let entry = GitStoreEntry(
            path: directoryPath,
            provider: provider,
            configuration: .ctrlx(
                repositoryURL: URL(fileURLWithPath: directoryPath),
                preferences: preferences
            ),
            recovery: recovery
        )
        gitWorkbenchStores[sessionName] = entry
    }

    private func localDirectoryPath(sessionName: String, window: LocalTmuxWindow?, onRight: Bool = false) -> String {
        WorkbenchDirectoryContext.resolve(
            terminalPath: window?.activePane?.currentPath,
            tabs: sessionFileTabsStates[sessionName],
            retainedGitPath: gitWorkbenchStores[sessionName]?.path,
            homeDirectory: NSHomeDirectory(),
            onRight: onRight
        )
    }

    /// Switches the given window to the File Explorer and asks it to reveal
    /// `path`. Shared by the tab bar's "Show in File Explorer" affordance and
    /// the Git tab's right-click menu so both behave identically.
    @MainActor
    private func revealInFileExplorer(path: String, sessionName: String, windowId: String) {
        openDirectoryTab(
            sessionName: sessionName,
            windowID: windowId,
            hostID: nil,
            paneIDs: [],
            fallbackPaneID: nil,
            path: (path as NSString).deletingLastPathComponent,
            selectedFile: path
        )
    }

    /// Renders the right pane of the split layout by dispatching on the
    /// `selectedRight` payload — window terminal, file explorer, browser
    /// tab, or file tab — and falls back to a placeholder when nothing is
    /// picked or the referenced content has gone away.
    @ViewBuilder
    private func rightPaneContent(
        sessionName: String,
        directoryPath: String,
        browserState: FileBrowserState?,
        sessionTabs: SessionFileTabsState
    ) -> some View {
        switch sessionTabs.selectedRight {
        case let .window(id):
            if
                let window = tmuxService.windows.first(where: {
                    $0.sessionName == sessionName && $0.stableId == id
                }) {
                WindowPaneLayoutView(
                    window: window,
                    onOpenURL: { url, paneID, behavior in
                        handleTerminalURLClick(
                            url,
                            directoryPath: directoryPath,
                            session: tmuxService.sessions.first(where: { $0.sessionName == sessionName }),
                            window: window,
                            paneID: paneID,
                            behaviorOverride: behavior
                        )
                    }
                )
                .id("right-window-\(window.id)")
                .modifier(DetachedTerminalPresentation(hostID: nil, windowID: window.stableId))
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case .fileExplorer:
            if let browserState {
                FileBrowserView(
                    directoryPath: directoryPath,
                    state: browserState,
                    sessionTabs: sessionTabs,
                    onOpenFileInNewTab: { path in
                        openFileInNewTab(
                            path: path,
                            directoryPath: directoryPath,
                            sessionName: sessionName,
                            windowId: selectedWindow?.id ?? ""
                        )
                    }
                )
                .id("right-file-explorer")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case .git:
            gitPane(windowId: selectedWindow?.id ?? "", sessionName: sessionName, directoryPath: directoryPath)
                .id("right-git")
                .accessibilityIdentifier("split-right-pane")
        case let .browser(id):
            if let state = sessionTabs.simulatorStates[id] {
                SimulatorTabContentView(state: state, workspaceID: simulatorWorkspace.id)
                    .id("right-\(id)")
                    .accessibilityIdentifier("split-right-pane")
            } else if let state = sessionTabs.agentBrowserStates[id] {
                AgentBrowserTabContentView(state: state, workspaceID: agentBrowserWorkspace.id)
                    .id("right-\(id)")
                    .accessibilityIdentifier("split-right-pane")
            } else if
                let tab = sessionTabs.openBrowserTabs.first(where: { $0.id == id }),
                let tabState = sessionTabs.browserStates[id] {
                BrowserTabContentView(
                    state: tabState,
                    onTitleChange: { newTitle in
                        updateBrowserTabTitle(tabId: id, sessionName: sessionName, title: newTitle)
                    },
                    onURLChange: { newURL in
                        updateBrowserTabURL(tabId: id, sessionName: sessionName, url: newURL)
                    },
                    onRequestNewTab: { newURL in
                        openBrowserTab(
                            url: newURL,
                            sessionName: sessionName,
                            windowId: selectedWindow?.id ?? "",
                            originWindowId: tab.originWindowId,
                            parentTabId: tab.id
                        )
                    },
                    onRequestClose: {
                        closeBrowserTab(tab.id, sessionName: sessionName)
                    }
                )
                .id("right-\(tab.id)")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case let .file(id):
            if let tab = sessionTabs.directoryTabs[id] {
                WorkspaceFileBrowserView(tab: tab, source: .local(paneID: tab.sourcePaneID, tmux: tmuxService, windows: windowManager))
                    .id(tab.id)
            } else if let tab = sessionTabs.openFileTabs.first(where: { $0.id == id }) {
                OpenFileTabContentView(tab: tab, sessionTabs: sessionTabs)
                    .id("right-\(tab.id)")
                    .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case nil:
            rightPanePlaceholder
        }
    }

    private var rightPanePlaceholder: some View {
        VStack {
            Spacer()
            ContentUnavailableView(
                "No Tab Selected",
                symbol: .rectangleSplit2x1,
                description: "Pick a tab on the right side to view it."
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("split-right-pane")
    }

    // MARK: - Toolbar

    private var workspaceTitle: String {
        let title = selectedSessionTitle ?? "CtrlX"
        return detachedWorkspace == nil ? title : "\(title) — Workspace"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if detachedWorkspace == nil {
            ToolbarItem(id: "ctrlx.toolbar.workflows", placement: .automatic) {
                Button { openWindow(id: "workflows") } label: { Label("Workflows", symbol: .flowchart) }
                    .help("Agent Workflows")
                    .accessibilityIdentifier("workflows-open")
            }
            ToolbarItem(id: "ctrlx.toolbar.dashboard", placement: .automatic) {
                Button { openWindow(id: "dashboard") } label: {
                    Label("Dashboard", symbol: .gaugeWithDotsNeedle50percent)
                }
                .help("Dashboard")
                .accessibilityIdentifier("dashboard-open")
            }
            ToolbarItem(id: "ctrlx.toolbar.session-switcher", placement: .navigation) {
                Button { showingSessionSwitcher = true } label: {
                    Label("Switch Session", symbol: .magnifyingglass)
                }
                .help("Switch Session (⌘P)")
                .accessibilityIdentifier("session-switcher-button")
            }
        }
        ToolbarItem(id: "ctrlx.toolbar.quotas", placement: .automatic) {
            DashboardQuotaToolbar(store: coordinator.dashboardStore) {
                openWindow(id: "dashboard")
            }
        }
        WorkbenchWindowTitle(title: workspaceTitle)
        ToolbarItem(id: "ctrlx.toolbar.trial", placement: .automatic) {
            TrialStatusToolbarItem()
        }

        ToolbarItem(id: "ctrlx.toolbar.connection", placement: .automatic) {
            connectionStatusView
        }

        // Actions for selected window
        ToolbarItemGroup(placement: .primaryAction) {
            if let window = selectedWindow ?? rightPaneTerminalWindow(), selectedRemoteSession == nil {
                let claudePane = window.panes.first { windowManager.paneStates[$0.paneId]?.agentSession != nil }
                let activePane = window.activePane

                // Yolo mode toggle (only for windows with active Claude sessions)
                if let claudePane {
                    Toggle(isOn: localYoloModeBinding(for: claudePane.paneId)) {
                        Symbols.bolt.image
                    }
                    .toggleStyle(.button)
                    .help(
                        windowManager.isYoloModeEnabled(for: claudePane.paneId)
                            ? "Yolo mode: auto-approving permissions (click to disable)"
                            : "Enable yolo mode to auto-approve permissions"
                    )
                }

                if let activePane {
                    Button {
                        attachToTerminal(activePane)
                    } label: {
                        Symbols.macwindow.image
                    }
                    .accessibilityLabel("Open session in terminal app")
                    .help("Open session in terminal app")
                }

                TerminalFitButton(action: resizeVisibleTerminalsToFit)

                Button {
                    requestCloseSession(window.sessionName)
                } label: {
                    Symbols.xmark.image
                }
                .accessibilityLabel("Close session")
                .help("Close session")
            } else if let remote = selectedRemoteSession, let remoteWindow = selectedRemoteWindow ?? remoteRightPaneTerminalWindow() {
                // Yolo mode toggle for remote windows with active Claude sessions
                let claudePaneId = remoteWindow.panes.first(where: { $0.agentSession != nil })?.paneId
                if
                    let claudePaneId,
                    let sessionStore = coordinator.remoteSessionStore,
                    sessionStore.session(for: claudePaneId, hostId: remote.hostId) != nil {
                    Toggle(isOn: Binding(
                        get: { sessionStore.isYoloModeEnabled(paneId: claudePaneId, hostId: remote.hostId) },
                        set: { newValue in
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let binding = manager.connection(for: remote.hostId)?.relayClient.workspaceInputState.binding(paneID: claudePaneId) ?? .unavailable
                            Task {
                                _ = await manager.sendCommand(
                                    SetYoloMode(enabled: newValue),
                                    paneId: claudePaneId,
                                    hostId: remote.hostId,
                                    inputBinding: binding
                                )
                            }
                        }
                    )) {
                        Symbols.bolt.image
                    }
                    .toggleStyle(.button)
                    .help(
                        coordinator.remoteSessionStore?.isYoloModeEnabled(paneId: claudePaneId, hostId: remote.hostId) == true
                            ? "Yolo mode: auto-approving permissions (click to disable)"
                            : "Enable yolo mode to auto-approve permissions"
                    )
                }

                TerminalFitButton(action: resizeVisibleTerminalsToFit)

                Button {
                    requestCloseRemoteSession(remote.sessionName, hostId: remote.hostId)
                } label: {
                    Symbols.xmark.image
                }
                .accessibilityLabel("Close session")
                .help("Close session")
            }

            Button {
                Task {
                    await refreshPanes()
                }
            } label: {
                Symbols.arrowClockwise.image
            }
            .accessibilityLabel("Refresh session list")
            .help("Refresh session list")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(tmuxService.isRefreshing)
        }
    }

    // MARK: - Connection Status View

    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            connectionStatusIcon
                .font(.caption)

            connectionActionButton
        }
        .onChange(of: coordinator.connectedViewerManager?.combinedState) { _, _ in
            showingDisconnectConfirmation = false
        }
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected
        let anyViewerConnected = connectionManager?.anyViewerConnected ?? false

        switch combinedState {
        case .disconnected:
            Symbols.wifiSlash.image
                .foregroundStyle(.secondary)
                .help("Disconnected from relay server")
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .help("Connecting...")
        case let .reconnecting(attempt):
            ProgressView()
                .controlSize(.small)
                .help("Reconnecting (attempt \(attempt))...")
        case .connected:
            Symbols.wifi.image
                .foregroundStyle(.green)
                .help(
                    anyViewerConnected
                        ? "Connected - viewer online"
                        : "Connected - waiting for viewer"
                )
        case let .error(message):
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
                .help("Error: \(message)")
        }
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected

        if !settings.isPaired {
            // Not paired - show generate pair button
            Button("Generate Pair") {
                openSettingsToRemoteAccess()
            }
            .controlSize(.small)
            .help("Open Remote Access settings to pair with iOS")
        } else if combinedState.isConnected {
            // Connected - show disconnect button with confirmation popover
            Button("Disconnect") {
                showingDisconnectConfirmation = true
            }
            .controlSize(.small)
            .help("Disconnect from relay server")
            .popover(isPresented: $showingDisconnectConfirmation, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Disconnect from relay server?")
                        .font(.headline)
                    Text("Paired iOS viewers will stop receiving updates until you reconnect.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            showingDisconnectConfirmation = false
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Disconnect", role: .destructive) {
                            showingDisconnectConfirmation = false
                            Task {
                                await connectionManager?.disconnectAll()
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
        } else if case .connecting = combinedState {
            // Connecting - no button
            EmptyView()
        } else if case .reconnecting = combinedState {
            // Reconnecting - show cancel button
            Button("Cancel") {
                Task {
                    await connectionManager?.disconnectAll()
                }
            }
            .controlSize(.small)
            .help("Cancel reconnection attempts")
        } else {
            // Disconnected but paired - show connect button
            Button("Connect") {
                Task {
                    await connectionManager?.connectAll()
                }
            }
            .controlSize(.small)
            .help("Connect to relay server for iOS monitoring")
        }
    }

    // MARK: - Resize

    private func localYoloModeBinding(for paneId: String) -> Binding<Bool> {
        let identity = windowManager.paneStates[paneId]?.workspaceIdentity
        return Binding(
            get: { windowManager.isYoloModeEnabled(for: paneId) },
            set: { newValue in
                guard let identity, windowManager.setYoloMode(enabled: newValue, for: paneId, expectedWorkspacePane: identity) else { return }
                Task {
                    await coordinator.connectedViewerManager?.pushSessionStateToAll()
                }
            }
        )
    }

    /// Manual Fit also consumes any pending automatic fit for this entry.
    private func resizeVisibleTerminalsToFit() {
        automaticTabFit.cancel()
        attachError = nil

        if let remote = selectedRemoteSession {
            let requests = visibleRemoteResizeRequests(remote: remote)
            Task {
                await performResize(requests)
            }
            return
        }

        let requests = visibleLocalResizeRequests()
        guard !requests.isEmpty else { return }
        Task {
            await performResize(requests)
        }
    }

    /// Common reaction for local and remote selection changes. Selection updates
    /// persistence and shared logical layout, but never tmux dimensions. Read
    /// acknowledgements are owned by the actually displayed terminal tiles.
    private func handleSelectionChanged() {
        seedLayoutIfNeeded()
        seedRemoteLayoutIfNeeded()
        scheduleSharedTerminalLayoutSync()
    }

    private func requestAutomaticTabFit(windowID: String? = nil) {
        if let remote = selectedRemoteSession {
            automaticTabFit.request(.init(hostID: remote.hostId, sessionName: remote.sessionName, windowID: windowID))
        } else if let session = currentLocalSession() {
            automaticTabFit.request(.init(hostID: nil, sessionName: session.sessionName, windowID: windowID))
        }
    }

    private func fitTerminalIfViewportChanged(hostID: String?, paneID: String) {
        guard
            appearsActive,
            let focused = terminalQuickActions.active, focused.isAvailable,
            focused.hostID == hostID, focused.paneID == paneID,
            let windowID = focusedTerminalWindowID else { return }
        let target = TerminalTabFit.Target(
            hostID: hostID,
            sessionName: selectedRemoteSession?.sessionName ?? currentLocalSession()?.sessionName ?? "",
            windowID: windowID
        )
        let input = terminalFitInput(for: target)
        guard
            input.current == target, input.isAvailable, input.isReady, input.isVisible,
            let request = input.request else { return }
        automaticTabFit.requestAfterViewportChange(target, measuredRequest: request)
        fitSelectedTerminalIfReady()
    }

    private var focusedTerminalWindowID: String? {
        guard
            let focused = terminalQuickActions.active, focused.isAvailable,
            focused.hostID == selectedRemoteSession?.hostId else { return nil }
        if selectedRemoteSession != nil {
            return selectedRemoteSessionWindows.first { $0.panes.contains { $0.paneId == focused.paneID } }?.stableId
        }
        return tmuxService.windows.first {
            $0.sessionName == currentLocalSession()?.sessionName && $0.panes.contains { $0.paneId == focused.paneID }
        }?.stableId
    }

    private struct AutomaticTabFitInput: Equatable {
        let pending: TerminalTabFit.Target
        let current: TerminalTabFit.Target
        let request: ResizeTmuxPane?
        let isAvailable: Bool
        let isReady: Bool
        let isVisible: Bool
    }

    private var automaticTabFitInput: AutomaticTabFitInput? {
        guard let pending = automaticTabFit.target else { return nil }
        return terminalFitInput(for: pending)
    }

    private func terminalFitInput(for pending: TerminalTabFit.Target) -> AutomaticTabFitInput {
        let hostID = selectedRemoteSession?.hostId
        let sessionName = selectedRemoteSession?.sessionName ?? currentLocalSession()?.sessionName ?? ""
        let tabs: SessionFileTabsState?
        let windowID: String?
        let isAvailable: Bool
        let isSeeded: Bool
        if let remote = selectedRemoteSession {
            let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            tabs = remoteSessionTabsStates[key]
            windowID = selectedRemoteWindow?.stableId
            let client = coordinator.viewerConnectionManager?.connection(for: remote.hostId)?.relayClient
            isAvailable = client?.isHostConnected == true && client?.hostSupportsTerminalFit == true
            isSeeded = detachedWorkspace != nil || seededRemoteSessions.contains(key)
                || tabStore.restoredRemoteSessions.contains(key)
        } else {
            tabs = sessionFileTabsStates[sessionName]
            windowID = selectedWindow?.stableId
            isAvailable = currentLocalSession() != nil
            isSeeded = detachedWorkspace != nil || seededSessions.contains(sessionName)
                || tabStore.restoredLocalSessions.contains(sessionName)
        }
        let selectedRightID: String? = if
            let tabs, tabs.isSplit,
            case let .window(id) = tabs.selectedRight {
            id
        } else {
            nil
        }
        let targetsRight = selectedRightID != nil && pending.windowID == selectedRightID
        let pendingRightIsHidden = pending.windowID.map {
            tabs?.rightSide.contains(.window($0)) == true && selectedRightID != $0
        } ?? false
        let targetID = targetsRight ? selectedRightID : windowID
        let leftIsVisible = tabs?.selectedFileTabId == nil && tabs?.selectedBrowserTabId == nil
            && (hostID != nil || (!fileBrowserActiveWindowIds.contains(selectedWindow?.id ?? "")
                    && tabs?.isGitSelected != true))
        let width = targetID.flatMap { effectiveTerminalWidth(tabs: tabs, windowId: $0) }
        let identityReady: Bool
        if let hostID, let targetID {
            let binding = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient.workspaceInputState.windowBinding(target: targetID)
            identityReady = (binding ?? .unavailable) != .unavailable
        } else {
            identityReady = hostID == nil
        }
        let isReady = identityReady && isSeeded && (width ?? detailPaneSize.width) >= 100 && detailPaneSize.height >= 100
        let dimensions = calculateOptimalTerminalDimensions(widthOverride: width)
        return AutomaticTabFitInput(
            pending: pending,
            current: .init(hostID: hostID, sessionName: sessionName, windowID: targetID),
            request: isReady ? ResizeTmuxPane(width: dimensions.columns, height: dimensions.rows, userInitiated: true) : nil,
            isAvailable: isAvailable,
            isReady: isReady,
            isVisible: (targetID.map { ownsTerminal(hostID: hostID, windowID: $0) } ?? true)
                && !pendingRightIsHidden && (targetsRight || leftIsVisible)
        )
    }

    private func fitSelectedTerminalIfReady() {
        guard appearsActive, let input = automaticTabFitInput else { return }
        guard input.isVisible else {
            automaticTabFit.cancel()
            return
        }
        guard
            let request = automaticTabFit.takeRequest(
                for: input.current,
                isAvailable: input.isAvailable,
                isPresentationReady: input.isReady,
                measuredRequest: input.request
            ), let windowID = input.current.windowID else { return }
        let requests = [resizeRequest(
            hostID: input.current.hostID, sessionName: input.current.sessionName,
            windowTarget: windowID, resize: request
        )]
        Task {
            await performResize(requests)
        }
    }

    private func visibleLocalResizeRequests() -> [TerminalFitRequest] {
        guard let session = currentLocalSession() else { return [] }
        var visibleWindows = selectedWindow.map { [$0] } ?? []
        if
            let rightWindow = rightPaneTerminalWindow(),
            rightWindow.stableId != selectedWindow?.stableId {
            visibleWindows.append(rightWindow)
        }

        let tabs = sessionFileTabsStates[session.sessionName]
        return visibleWindows.filter { ownsTerminal(hostID: nil, windowID: $0.stableId) }.map { window in
            resizeRequest(
                hostID: nil, sessionName: session.sessionName,
                windowTarget: window.stableId,
                width: effectiveTerminalWidth(tabs: tabs, windowId: window.stableId)
            )
        }
    }

    private func visibleRemoteResizeRequests(
        remote: RemoteSessionSelection
    ) -> [TerminalFitRequest] {
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        let tabs = remoteSessionTabsStates[key]
        var visibleWindows = selectedRemoteWindow.map { [$0] } ?? []
        if
            let tabs,
            tabs.isSplit,
            case let .window(rightWindowId) = tabs.selectedRight,
            rightWindowId != selectedRemoteWindow?.stableId,
            let rightWindow = selectedRemoteSessionWindows.first(where: {
                $0.stableId == rightWindowId
            }) {
            visibleWindows.append(rightWindow)
        }

        return visibleWindows.filter { ownsTerminal(hostID: remote.hostId, windowID: $0.stableId) }.map { window in
            resizeRequest(
                hostID: remote.hostId, sessionName: remote.sessionName,
                windowTarget: window.stableId,
                width: effectiveTerminalWidth(tabs: tabs, windowId: window.stableId)
            )
        }
    }

    private func resizeRequest(
        hostID: String?,
        sessionName: String,
        windowTarget: String,
        width: CGFloat?
    ) -> TerminalFitRequest {
        let dimensions = calculateOptimalTerminalDimensions(widthOverride: width)
        return resizeRequest(
            hostID: hostID, sessionName: sessionName, windowTarget: windowTarget,
            resize: .init(width: dimensions.columns, height: dimensions.rows, userInitiated: true)
        )
    }

    private func resizeRequest(
        hostID: String?,
        sessionName: String,
        windowTarget: String,
        resize: ResizeTmuxPane
    ) -> TerminalFitRequest {
        return TerminalFitRequest(
            hostID: hostID, sessionName: sessionName,
            windowTarget: windowTarget,
            columns: resize.width,
            rows: resize.height,
            workspaceScope: hostID.flatMap {
                coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.workspaceInputState.catalog?.scope
            },
            inputBinding: hostID.flatMap {
                coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.workspaceInputState.windowBinding(target: windowTarget)
            },
            workspacePane: hostID == nil ? windowManager.paneStates.values.first(where: { $0.stableWindowId == windowTarget })?.workspaceIdentity : nil
        )
    }

    private func performResize(_ requests: [TerminalFitRequest]) async {
        do {
            try await TerminalFitRequest.perform(requests, isCurrent: { request in
                guard let hostID = request.hostID else {
                    guard let identity = request.workspacePane else { return true }
                    return windowManager.paneStates.values.contains { identity.isSameWindow(as: $0.workspaceIdentity) }
                }
                guard let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient else { return false }
                guard client.isHostConnected, client.workspaceInputState.catalog?.scope == request.workspaceScope else { return false }
                guard let binding = request.inputBinding else { return true }
                do {
                    _ = try binding.expectedPane(current: client.workspaceInputState.windowBinding(target: request.windowTarget))
                    return true
                } catch { return false }
            }, willStart: { request in
                automaticTabFit.invalidateFit(for: request.target)
            }, resize: { request in
                if let hostID = request.hostID {
                    guard let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient else {
                        throw ViewerRelayClientError.notConnected
                    }
                    _ = try await client.sendCommand(
                        request.resize, paneId: request.windowTarget, inputBinding: request.inputBinding
                    ).get()
                } else {
                    try await tmuxService.fitWindow(
                        request.windowTarget, width: request.columns, height: request.rows,
                        expectedWorkspacePane: request.workspacePane
                    )
                }
            }, didSucceed: { request in
                automaticTabFit.recordFit(for: request.target, request: request.resize)
            })
        } catch {
            attachError = "Failed to resize: \(error.localizedDescription)"
        }
    }

    /// The tmux window currently rendered in the split-view right pane (if any).
    /// Returns `nil` when the right pane is empty, holds non-terminal content
    /// (file explorer, file tab, browser tab), or when the layout is not split.
    private func rightPaneTerminalWindow() -> LocalTmuxWindow? {
        guard
            let sessionName = currentLocalSession()?.sessionName,
            let tabs = sessionFileTabsStates[sessionName],
            tabs.isSplit,
            case let .window(rightWindowId) = tabs.selectedRight
        else {
            return nil
        }
        return tmuxService.windows.first {
            $0.sessionName == sessionName && $0.stableId == rightWindowId && ownsTerminal(hostID: nil, windowID: $0.stableId)
        }
    }

    private func remoteRightPaneTerminalWindow() -> TmuxWindow? {
        guard
            let remote = selectedRemoteSession,
            let tabs = remoteSessionTabsStates[remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)],
            case let .window(id) = tabs.selectedRight,
            tabs.rightSide.contains(.window(id)) else { return nil }
        return selectedRemoteSessionWindows.first {
            $0.stableId == id && ownsTerminal(hostID: remote.hostId, windowID: id)
        }
    }

    // MARK: - Session Tracking

    private func handleActiveSessionsChanged() {
        let currentIds = windowManager.activeSessionPaneIds
        let previousIds = trackedActiveSessionPaneIds

        // Detect newly added Claude sessions
        let newSessionPaneIds = currentIds.subtracting(previousIds)
        // Detect removed Claude sessions (sessions moving from Claude Sessions → Terminals)
        let removedSessionPaneIds = previousIds.subtracting(currentIds)

        if
            let selected = selectedWindow, newSessionPaneIds.contains(where: { paneId in
                selected.panes.contains { $0.paneId == paneId }
            }) {
            // The currently selected window just got a Claude session - scroll to its session
            let sessionName = selected.sessionName
            scrollToWindowId = sessionName
        } else if !removedSessionPaneIds.isEmpty, let selected = selectedWindow {
            // A session ended, causing entries to move between sections - scroll to keep visible
            let sessionName = selected.sessionName
            scrollToWindowId = sessionName
        } else if
            selectedWindow == nil, selectedRemoteSession == nil, newSessionPaneIds.count == 1,
            let newPaneId = newSessionPaneIds.first,
            let containingWindow = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == newPaneId } }),
            let session = tmuxService.sessions.first(where: { $0.sessionName == containingWindow.sessionName }) {
            // Nothing selected and a single new session appeared - auto-select its
            // tmux-active window, mirroring the sidebar-click behavior. Selecting the
            // window that merely *contains* the agent pane would show the wrong window
            // whenever tmux's active window differs from the agent's window (issue #653).
            let rightSideIds = sessionFileTabsStates[session.sessionName]?.rightSideWindowIds ?? []
            if let pick = session.leftPaneWindow(excludingRightSide: rightSideIds) {
                selectedWindow = pick
                scrollToWindowId = pick.sessionName
            }
        }

        trackedActiveSessionPaneIds = currentIds
    }

    // MARK: - Pending Menu Bar Selection

    /// Applies a pending menu bar selection, if any.
    /// Called both from `.task` (when the view first appears) and `.onChange` (when already visible).
    private func applyPendingMenuBarSelection() {
        guard detachedWorkspace == nil else { return }
        guard let selection = coordinator.pendingMenuBarSelection else { return }
        coordinator.pendingMenuBarSelection = nil
        switch selection {
        case let .local(paneId):
            if let window = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == paneId } }) {
                tabStore.userDidSelectSession()
                selectedWindow = window
                selectedRemoteSession = nil
                selectedRemoteWindowId = nil
                fileBrowserActiveWindowIds.remove(window.id)
                sessionFileTabsStates[window.sessionName]?.isGitSelected = false
                if
                    let sessionName = tmuxService.sessions
                        .first(where: { $0.windows.contains(where: { $0.id == window.id }) })?
                        .sessionName {
                    sessionFileTabsStates[sessionName]?.selectedFileTabId = nil
                }
                requestAutomaticTabFit(windowID: window.stableId)
            }
        case let .remote(hostId, hostName, paneId):
            // Find the session name for this pane from the session store
            if let paneState = coordinator.remoteSessionStore?.paneState(for: paneId, hostId: hostId) {
                selectRemoteSession(.init(
                    hostId: hostId,
                    hostName: hostName,
                    sessionName: paneState.sessionName
                ))
                tabStore.userDidSelectTab(hostID: hostId, session: paneState.sessionName)
                selectedRemoteWindowId = paneState.windowId
                requestAutomaticTabFit(windowID: paneState.stableWindowId)
            }
            selectedWindow = nil
        }
    }

    // MARK: - Actions

    private func refreshPanes() async {
        await tmuxService.refreshPanes()
    }

    private func renameLocalSession(from sessionName: String, to newName: String, expectedWorkspacePane: WorkspacePaneIdentity?) {
        guard let expectedWorkspacePane else {
            attachError = "The terminal is still being discovered. Try again in a moment."
            return
        }
        let oldPanes = tmuxService.panes
        Task {
            do {
                try await tmuxService.renameSession(from: sessionName, to: newName, expectedWorkspacePane: expectedWorkspacePane)
                let newPanes = await tmuxService.refreshPanes()
                windowManager.updatePaneStates(from: newPanes)
                for rename in SessionRenameMapping.detect(from: oldPanes, to: newPanes) {
                    migrateLocalSessionState(rename)
                }
                await coordinator.paneStreamManager.updateMonitoring(panes: newPanes)
                await coordinator.connectedViewerManager?.pushSessionStateToAll()
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    /// Moves every MainView-owned cache that uses the mutable tmux session or
    /// window ID as a key. This is idempotent because the old keys disappear on
    /// the first pass; both the explicit rename action and pane-snapshot change
    /// detection may call it during the same render cycle.
    private func migrateLocalSessionState(_ rename: SessionRenameMapping) {
        let oldName = rename.oldName
        let newName = rename.newName

        coordinator.detachedWindows.renameSession(hostID: nil, from: oldName, to: newName, windowIDs: rename.windowIDs)
        if selectedLocalSessionName == oldName {
            selectedLocalSessionName = newName
        }

        coordinator.agentBrowser.renameManualTabs(
            in: agentBrowserWorkspace,
            from: ManualBrowserTarget(sessionName: oldName),
            to: ManualBrowserTarget(sessionName: newName)
        )

        if let state = fileBrowserStates.removeValue(forKey: oldName) {
            fileBrowserStates[newName] = state
        }
        if let store = gitWorkbenchStores.removeValue(forKey: oldName) {
            gitWorkbenchStores[newName] = store
        }
        if seededSessions.remove(oldName) != nil {
            seededSessions.insert(newName)
        }
        // Let the renamed session start a fresh read. The old in-flight task
        // observes that `oldName` no longer exists and exits without applying.
        seedingSessions.remove(oldName)
        if let layout = lastPersistedLayouts.removeValue(forKey: oldName) {
            lastPersistedLayouts[newName] = layout
        }
        if let save = pendingLayoutSaves.removeValue(forKey: oldName) {
            pendingLayoutSaves[newName] = save
        }

        fileBrowserActiveWindowIds = Set(fileBrowserActiveWindowIds.map { rename.windowIDs[$0] ?? $0 })
        if scrollToWindowId == oldName {
            scrollToWindowId = newName
        }
        markdownOpenSuggestionStore.sessionRenamed(from: oldName, to: newName)

        guard let selected = selectedWindow, selected.sessionName == oldName else { return }
        if
            let newWindowID = rename.windowIDs[selected.id],
            let replacement = tmuxService.windows.first(where: { $0.id == newWindowID }) {
            selectedWindow = replacement
        } else if
            let paneID = selected.activePane?.paneId ?? selected.panes.first?.paneId,
            let replacement = tmuxService.windows.first(where: { window in
                window.panes.contains(where: { $0.paneId == paneID })
            }) {
            selectedWindow = replacement
        }
    }

    private func attachToTerminal(_ pane: PaneInfo) {
        let launcher = TerminalLauncher(settings: settings)
        Task {
            do {
                try await launcher.attachToSession(pane.sessionName)
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    private func requestCloseSession(_ sessionName: String) {
        if let session = coordinator.resourceSessions.sessions.first(where: { $0.name == sessionName }) {
            closeConfirmation = .init(target: .resourceSession(session, hostID: nil), runningProcesses: [])
            return
        }
        guard let identity = tmuxService.panes.first(where: { $0.sessionName == sessionName })?.workspaceIdentity else {
            attachError = "The terminal is still being discovered. Try again shortly."
            return
        }
        let target = CloseConfirmation.Target.session(sessionName, identity: identity)
        Task {
            let processes = await tmuxService.runningProcesses(inSession: sessionName)
            if processes.isEmpty {
                performClose(target)
            } else {
                closeConfirmation = CloseConfirmation(
                    target: target,
                    localProcesses: processes
                )
            }
        }
    }

    private func requestCloseWindow(_ window: LocalTmuxWindow) {
        guard ownsTerminal(hostID: nil, windowID: window.stableId) else { return }
        guard let identity = window.panes.first?.workspaceIdentity else {
            attachError = "The terminal is still being discovered. Try again shortly."
            return
        }
        let target = CloseConfirmation.Target.window(window, identity: identity)
        Task {
            let processes = await tmuxService.runningProcesses(inWindow: window.stableId)
            guard ownsTerminal(hostID: nil, windowID: window.stableId) else { return }
            let windows = tmuxService.windows.filter { $0.sessionName == window.sessionName }
            let closesSession = windows.count == 1 && windows.first?.stableId == window.stableId && !hasIndependentResources(hostID: nil, sessionName: window.sessionName)
            if processes.isEmpty, !closesSession {
                performClose(target)
            } else {
                closeConfirmation = CloseConfirmation(
                    target: closesSession ? .session(window.sessionName, identity: identity) : target,
                    localProcesses: processes,
                    closesLastWindow: closesSession
                )
            }
        }
    }

    private var sessionSwitcherItems: [SessionSwitcherItem] {
        orderedSidebarSessions().map { entry in
            switch entry {
            case let .local(session):
                SessionSwitcherItem(
                    id: .local(sessionName: session.sessionName),
                    name: session.sessionName,
                    title: localSessionSortData(session).primaryLabel,
                    host: "This Mac"
                )
            case let .remote(hostID, hostName, session):
                SessionSwitcherItem(
                    id: .remote(hostID: hostID, sessionName: session.sessionName),
                    name: session.sessionName,
                    title: remoteSessionPrimaryLabel(hostId: hostID, sessionName: session.sessionName) ?? session.sessionName,
                    host: hostName,
                    isAvailable: coordinator.viewerConnectionManager?.connection(for: hostID)?.isHostConnected == true
                )
            }
        }
    }

    private var currentSessionTabs: SessionFileTabsState? {
        if let remote = selectedRemoteSession {
            return remoteSessionTabsStates[remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)]
        }
        return currentLocalSessionName.flatMap { sessionFileTabsStates[$0] }
    }

    private var targetsRightPane: Bool {
        currentSessionTabs?.isSplit == true && currentSessionTabs?.isRightPaneFocused == true
    }

    private var menuTerminalWindowID: String? {
        if targetsRightPane {
            return currentSessionTabs?.selectedRight?.windowId
        }
        return selectedRemoteSession == nil ? selectedWindow?.stableId : selectedRemoteWindow?.stableId
    }

    private func focusRightTerminal(_ id: String) {
        let paneID: String?
        if selectedRemoteSession != nil {
            paneID = selectedRemoteSessionWindows.first { $0.stableId == id }?.activePane?.paneId
        } else {
            paneID = currentLocalSession()?.windows.first { $0.stableId == id }?.activePane?.paneId
        }
        if let paneID {
            terminalQuickActions.requestFocus(hostID: selectedRemoteSession?.hostId, paneID: paneID)
        }
        requestAutomaticTabFit(windowID: id)
    }

    private var rightTabEntries: [TabDragPayload] {
        guard let tabs = currentSessionTabs else { return [] }
        let ids = selectedRemoteSession == nil
            ? currentLocalSession()?.windows.map(\.stableId) ?? [] : selectedRemoteSessionWindows.map(\.stableId)
        let order = TabDragPayload.reconciledOrder(
            windowIds: ids.filter { ownsTerminal(hostID: selectedRemoteSession?.hostId, windowID: $0) },
            fileTabIds: tabs.openFileTabs.map(\.id), browserTabIds: tabs.openBrowserTabs.map(\.id),
            storedOrder: tabs.tabOrder, includeFileExplorer: false, includeGit: selectedRemoteSession == nil
        )
        return tabs.groupedTabOrder(order, paneOrder: navigationSourcePanes.map(\.paneId)).filter { tabs.rightSide.contains($0) }
    }

    private func selectAdjacentRightTab(direction: Int) {
        guard let tabs = currentSessionTabs else { return }
        let entries = rightTabEntries
        guard
            let selected = tabs.selectedRight,
            let next = adjacentTab(to: selected, in: entries, direction: direction) else { return }
        selectRightTab(next)
    }

    private var navigationSourcePanes: [PaneState] {
        let panes: [PaneState]
        if selectedRemoteSession != nil {
            panes = selectedRemoteSessionWindows.flatMap(\.panes)
        } else {
            guard let session = currentLocalSession() else { return [] }
            panes = tmuxService.windows.filter { $0.sessionName == session.sessionName }
                .flatMap(\.panes).compactMap { windowManager.paneStates[$0.paneId] }
        }
        let windows = PaneLinkedTabs.ordered(panes.map(\.stableWindowId), stored: currentSessionTabs?.tabOrder.compactMap(\.windowId) ?? [])
        return windows.flatMap { id in panes.filter { $0.stableWindowId == id } }
    }

    private func adjacentTab(to current: TabDragPayload, in order: [TabDragPayload], direction: Int) -> TabDragPayload? {
        if currentSessionTabs?.sourcePaneID(for: current) == nil {
            let terminals = order.filter { currentSessionTabs?.sourcePaneID(for: $0) == nil }
            guard terminals.count > 1, let index = terminals.firstIndex(of: current) else { return nil }
            return terminals[(index + direction + terminals.count) % terminals.count]
        }
        guard let tabs = currentSessionTabs else { return nil }
        let groups = PaneLinkedTabs.groups(items: order.filter(\.isLinkedContent), paneOrder: navigationSourcePanes.map(\.paneId), sourcePane: tabs.sourcePaneID)
        switch PaneLinkedTabs.adjacent(to: current, direction: direction, groups: groups) {
        case let .tab(tab): return tab
        case let .sourcePane(id):
            guard let pane = navigationSourcePanes.first(where: { $0.paneId == id }) else { return nil }
            showSourcePane(pane, hostID: selectedRemoteSession?.hostId)
            return nil
        case nil: return nil
        }
    }

    private func consumeSourcePaneRequest() {
        guard
            detachedWorkspace != nil || isLayoutStoreReady,
            let request = coordinator.detachedWindows.sourcePaneRequest,
            ownsTerminal(hostID: request.hostID, windowID: request.pane.stableWindowId) else { return }
        coordinator.detachedWindows.sourcePaneRequest = nil
        showSourcePane(request.pane, hostID: request.hostID)
    }

    private func openWorkflow(for pane: PaneState, hostID: String?) {
        let endpoint: AgentWorkflowEndpoint
        if let hostID {
            guard let host = settings.pairedHosts.first(where: { $0.id == hostID }) else { return }
            endpoint = .remote(host, manager: coordinator.viewerConnectionManager)
        } else {
            endpoint = coordinator.localWorkflowEndpoint()
        }
        Task {
            do {
                try await coordinator.workflowNavigation.open(for: pane, endpoint: endpoint)
                openWindow(id: "workflows")
            } catch is CancellationError {
                // A newer navigation replaced this request.
            } catch { attachError = error.localizedDescription }
        }
    }

    private func showSourcePane(_ pane: PaneState, hostID: String?) {
        let live = hostID.flatMap { coordinator.remoteSessionStore?.paneState(for: pane.paneId, hostId: $0) }
            ?? (hostID == nil ? windowManager.paneStates[pane.paneId] : nil)
        guard
            let live, live.sessionName == pane.sessionName, live.stableWindowId == pane.stableWindowId,
            pane.workspaceIdentity == nil || pane.workspaceIdentity?.isSamePane(as: live.workspaceIdentity) == true else { return }
        if !ownsTerminal(hostID: hostID, windowID: pane.stableWindowId) {
            coordinator.detachedWindows.sourcePaneRequest = .init(hostID: hostID, pane: pane)
            coordinator.detachedWindows.focusNativeWindow(workspaceID: coordinator.detachedWindows.owner(hostID: hostID, windowID: pane.stableWindowId))
            return
        }
        if let hostID {
            if selectedRemoteSession?.hostId != hostID || selectedRemoteSession?.sessionName != pane.sessionName {
                selectRemoteSession(.init(hostId: hostID, hostName: settings.pairedHosts.first { $0.id == hostID }?.displayName ?? hostID, sessionName: pane.sessionName))
            }
        } else if selectedRemoteSession != nil || currentLocalSession()?.sessionName != pane.sessionName {
            guard let session = tmuxService.sessions.first(where: { $0.sessionName == pane.sessionName }) else { return }
            selectLocalSession(session)
        }
        let onRight = currentSessionTabs?.rightSide.contains(.window(pane.stableWindowId)) == true
        currentSessionTabs?.isRightPaneFocused = onRight
        if onRight {
            selectRightTab(.window(pane.stableWindowId))
        } else {
            selectTerminalWindow(stableId: pane.stableWindowId)
        }
        terminalQuickActions.requestFocus(hostID: hostID, paneID: pane.paneId)
        let client = hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient }
        let binding = client?.workspaceInputState.binding(paneID: pane.paneId)
        Task {
            if let client {
                _ = await client.sendCommand(SelectTmuxPane(), paneId: pane.paneId, inputBinding: binding)
            } else if hostID == nil {
                do { try await tmuxService.selectPane(pane.paneId, expectedWorkspacePane: pane.workspaceIdentity) }
                catch { attachError = error.localizedDescription }
            }
        }
    }

    private func selectRightTab(_ entry: TabDragPayload) {
        recordUserTabSelection()
        currentSessionTabs?.selectedRight = entry
        if case let .window(id) = entry {
            focusRightTerminal(id)
        }
    }

    private func closeRightTab() {
        guard let selected = currentSessionTabs?.selectedRight else { return }
        if let remote = selectedRemoteSession {
            switch selected {
            case let .window(id):
                if let window = selectedRemoteSessionWindows.first(where: { $0.stableId == id }) {
                    requestCloseRemoteWindow(window, hostId: remote.hostId)
                }
            case let .file(id): closeRemoteFileTab(id, hostID: remote.hostId, sessionName: remote.sessionName)
            case let .browser(id): closeRemoteBrowserTab(id, hostId: remote.hostId, sessionName: remote.sessionName)
            case .fileExplorer,
                 .git: break
            }
        } else if let session = currentLocalSession() {
            switch selected {
            case let .window(id):
                if let window = session.windows.first(where: { $0.stableId == id }) {
                    requestCloseWindow(window)
                }
            case let .file(id): closeOpenFileTab(id, sessionName: session.sessionName)
            case let .browser(id): closeBrowserTab(id, sessionName: session.sessionName)
            case .git: closeGitTab(sessionName: session.sessionName)
            case .fileExplorer: break
            }
        }
    }

    private var canCreateTerminal: Bool {
        guard !isCreatingTerminal else { return false }
        if let remote = selectedRemoteSession {
            return coordinator.viewerConnectionManager?.connection(for: remote.hostId)?.isHostConnected == true
        }
        return currentLocalSession() != nil
    }

    private func createTerminalTab() {
        guard canCreateTerminal, let selection = sidebarSessionSelection.wrappedValue else { return }
        recordUserTabSelection()
        let hostID = selectedRemoteSession?.hostId
        let sessionName = selectedRemoteSession?.sessionName ?? currentLocalSession()?.sessionName ?? ""
        let onRight = targetsRightPane
        let tabs = currentSessionTabs
        let sourceID = menuTerminalWindowID
        let focused = terminalQuickActions.active
        let sourcePane = focused.flatMap { endpoint -> PaneState? in
            guard endpoint.isAvailable, endpoint.hostID == hostID else { return nil }
            let pane: PaneState?
            if let hostID {
                pane = coordinator.remoteSessionStore?.paneState(for: endpoint.paneID, hostId: hostID)
            } else {
                pane = windowManager.paneStates[endpoint.paneID]
            }
            return pane?.sessionName == sessionName && pane?.stableWindowId == sourceID ? pane : nil
        }
        let directory = tabs?.selectedDirectoryPath(onRight: onRight) ?? sourcePane?.currentPath ?? (hostID == nil
            ? localDirectoryPath(
                sessionName: sessionName,
                window: currentLocalSession()?.windows.first { $0.stableId == sourceID },
                onRight: onRight
            )
            : selectedRemoteSessionWindows.first { $0.stableId == sourceID }?.activePane?.currentPath)
        let localIdentity = tmuxService.panes.first { $0.sessionName == sessionName }?.workspaceIdentity
        let remoteBinding = hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.workspaceInputState.sessionBinding(name: sessionName) } ?? .unavailable
        isCreatingTerminal = true
        Task {
            defer { isCreatingTerminal = false }
            do {
                let newWindowID: String
                if let hostID, let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient {
                    let response = try await client.sendCommand(CreateTmuxWindow(sessionName: sessionName, workingDirectory: directory, resourceSessionID: client.resourceSessions.first { $0.name == sessionName }?.id), paneId: "", inputBinding: remoteBinding).get()
                    guard let paneID = response.paneId else { throw ViewerRelayClientError.commandFailed("The Host did not return the new terminal.") }
                    await client.requestSessionState()
                    var found: String?
                    for _ in 0..<20 {
                        if client.resourceSessions.first(where: { $0.name == sessionName }) == nil {
                            _ = try remoteBinding.expectedPane(current: client.workspaceInputState.sessionBinding(name: sessionName))
                        }
                        found = coordinator.remoteSessionStore?.windows(for: hostID).first { $0.panes.contains { $0.paneId == paneID } }?.stableId
                        if found != nil {
                            break
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                    guard let found else { throw ViewerRelayClientError.commandFailed("Terminal created but not visible yet. Select it from the tab bar.") }
                    newWindowID = found
                } else if hostID == nil {
                    let resourceID = coordinator.resourceSessions.sessions.first { $0.name == sessionName }?.id
                    guard localIdentity != nil || resourceID != nil else { throw ViewerRelayClientError.commandFailed("Session identity is not available yet. Try again after discovery.") }
                    let paneID = try await tmuxService.newWindow(sessionName: sessionName, workingDirectory: directory, expectedWorkspacePane: localIdentity, resourceSessionID: resourceID)
                    guard let window = await PaneSurfaceRetry.localWindow(containing: paneID, windows: { tmuxService.windows }, refresh: { _ = await tmuxService.refreshPanes() }) else {
                        throw ViewerRelayClientError.commandFailed("Terminal created but not visible yet. Select it from the tab bar.")
                    }
                    guard
                        window.panes.contains(where: { pane in
                            if let localIdentity {
                                return pane.workspaceIdentity?.isSameSession(as: localIdentity) == true
                            }
                            return pane.workspaceIdentity?.sessionID == resourceID
                        }) else {
                        throw ViewerRelayClientError.commandFailed("The session changed while creating the terminal. Select the restored session.")
                    }
                    newWindowID = window.stableId
                } else {
                    return
                }
                adoptCreatedWindow(hostID: hostID, windowID: newWindowID)
                guard sidebarSessionSelection.wrappedValue == selection, targetsRightPane == onRight else { return }
                if onRight {
                    tabs?.rightSide.insert(.window(newWindowID))
                    tabs?.selectedRight = .window(newWindowID)
                    focusRightTerminal(newWindowID)
                } else {
                    selectTerminalWindow(stableId: newWindowID)
                }
            } catch is CancellationError {
                return
            } catch {
                attachError = "Failed to create terminal: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Menu Commands

    private var canSelectAdjacentTab: Bool {
        guard !isPresentingSessionPicker, let tabs = currentSessionTabs else { return false }
        let order: [TabDragPayload]
        let selected: TabDragPayload?
        if targetsRightPane {
            order = rightTabEntries
            selected = tabs.selectedRight
        } else if let remote = selectedRemoteSession {
            order = remoteTabEntries(remote: remote)
            selected = tabs.selectedBrowserTabId.map(TabDragPayload.browser)
                ?? tabs.selectedFileTabId.map(TabDragPayload.file)
                ?? selectedRemoteWindow.map { .window($0.stableId) }
        } else if let session = currentLocalSession() {
            let entries = tabStripEntries(session: session, sessionTabs: tabs)
            order = entries.map(\.payload)
            selected = currentTabIndex(entries: entries, window: selectedWindow, sessionTabs: tabs).map { order[$0] }
        } else {
            return false
        }
        guard let selected else { return false }
        if selected.windowId != nil {
            return order.filter { $0.windowId != nil }.count > 1
        }
        let groups = PaneLinkedTabs.groups(items: order.filter(\.isLinkedContent), paneOrder: navigationSourcePanes.map(\.paneId), sourcePane: tabs.sourcePaneID)
        guard let group = groups.first(where: { $0.items.contains(selected) }) else { return false }
        return group.items.count > 1 || navigationSourcePanes.contains { $0.paneId == group.id }
    }

    private var navigableTabCount: Int {
        guard !isPresentingSessionPicker else { return 0 }
        if targetsRightPane {
            return rightTabEntries.count
        }
        if let remote = selectedRemoteSession {
            return remoteTabEntries(remote: remote).count
        }
        guard let session = currentLocalSession() else { return 0 }
        return tabStripEntries(session: session, sessionTabs: currentSessionTabs).count
    }

    private func selectTab(at index: Int) {
        guard !isPresentingSessionPicker else { return }
        if targetsRightPane {
            let entries = rightTabEntries
            guard entries.indices.contains(index) else { return }
            selectRightTab(entries[index])
        } else if let remote = selectedRemoteSession {
            let entries = remoteTabEntries(remote: remote)
            guard entries.indices.contains(index) else { return }
            selectRemoteTab(entries[index], remote: remote)
        } else if let session = currentLocalSession() {
            let tabs = currentSessionTabs
            let entries = tabStripEntries(session: session, sessionTabs: tabs)
            guard entries.indices.contains(index) else { return }
            applyTabSelection(entry: entries[index], session: session, sessionTabs: tabs, currentWindow: selectedWindow)
        }
    }

    private var resourceTabActions: ResourceTabActions? {
        if let remote = selectedRemoteSession {
            guard
                let client = coordinator.viewerConnectionManager?.connection(for: remote.hostId)?.relayClient,
                client.hostSupportsIndependentResources else { return nil }
            return .init { try await ResourceTabClient.request($0, client: client) }
        }
        return .init { try await coordinator.handleResourceTab($0) }
    }

    private var browserAnnotationContext: BrowserAnnotationContext? {
        if let remote = selectedRemoteSession {
            guard let client = coordinator.viewerConnectionManager?.connection(for: remote.hostId)?.relayClient else { return nil }
            let targets = remoteSessionWindows(hostId: remote.hostId, sessionName: remote.sessionName)
                .flatMap(\.panes).compactMap(AgentImageTarget.init(pane:))
            return .remote(targets: targets, client: client) { target in
                revealAnnotationTarget(target, hostID: remote.hostId)
            }
        }
        guard let sessionName = currentLocalSession()?.sessionName else { return nil }
        let targets = windowManager.paneStates.values.filter { $0.sessionName == sessionName }
            .sorted { $0.target < $1.target }.compactMap(AgentImageTarget.init(pane:))
        return BrowserAnnotationContext(targets: targets) { image, target in
            try await coordinator.insertBrowserImage(image, target: target)
        } didSend: { target in revealAnnotationTarget(target, hostID: nil) }
    }

    private func revealAnnotationTarget(_ target: AgentImageTarget, hostID: String?) {
        // An image handoff can finish after the user has left its session.
        guard
            selectedRemoteSession?.hostId == hostID,
            (selectedRemoteSession?.sessionName ?? currentLocalSession()?.sessionName) == target.sessionName else { return }
        terminalQuickActions.requestFocus(hostID: hostID, paneID: target.paneID)
        let tabs = hostID.map { remoteSessionTabsStates[remoteTabsKey(hostId: $0, sessionName: target.sessionName)] }
            ?? sessionFileTabsStates[target.sessionName]
        if tabs?.rightSide.contains(.window(target.windowID)) == true {
            tabs?.selectedRight = .window(target.windowID)
            requestAutomaticTabFit(windowID: target.windowID)
        } else {
            selectTerminalWindow(stableId: target.windowID)
        }
        let client = hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient }
        let binding = client?.workspaceInputState.binding(paneID: target.paneID)
        let identity = windowManager.paneStates[target.paneID]?.workspaceIdentity
        Task {
            if hostID != nil {
                guard let client else { return }
                _ = await client.sendCommand(SelectTmuxPane(), paneId: target.paneID, inputBinding: binding)
            } else {
                do { try await tmuxService.selectPane(target.paneID, expectedWorkspacePane: identity) }
                catch { attachError = error.localizedDescription }
            }
        }
    }

    private func browserSourcePane(sessionName: String, hostID: String?, windowID: String?) -> String? {
        let panes: [PaneState] = if let hostID {
            remoteSessionWindows(hostId: hostID, sessionName: sessionName).flatMap(\.panes)
        } else {
            windowManager.paneStates.values.filter { $0.sessionName == sessionName }
        }
        let source = panes.filter { windowID == nil || $0.windowId == windowID || $0.stableWindowId == windowID }
        let focused = terminalQuickActions.active.flatMap { $0.hostID == hostID ? $0.paneID : nil }
        return FileBrowserTab.sourcePaneID(
            in: source.map(\.paneId),
            focusedPaneID: focused,
            activePaneID: source.first(where: \.isActive)?.paneId
        )
    }

    private func browserSourceAgent(sessionName: String, hostID: String?, windowID: String?) -> AgentImageTarget? {
        guard let paneID = browserSourcePane(sessionName: sessionName, hostID: hostID, windowID: windowID) else { return nil }
        if let hostID {
            return remoteSessionWindows(hostId: hostID, sessionName: sessionName).flatMap(\.panes)
                .first { $0.paneId == paneID }.flatMap(AgentImageTarget.init(pane:))
        }
        return windowManager.paneStates[paneID].flatMap(AgentImageTarget.init(pane:))
    }

    private func detachTerminal(hostID: String?, windowID: String, position: CGPoint?) {
        guard let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID) else { return }
        if !ownsTerminal(hostID: hostID, windowID: windowID) {
            coordinator.detachedWindows.focus(hostID: hostID, windowID: windowID)
            return
        }
        if let workspace = coordinator.detachedWindows.detach(target, position: position, session: terminalSession) {
            openWindow(id: "detached-terminal", value: workspace.id)
        }
    }

    private func detachSession(hostID: String?, name: String, position: CGPoint?) {
        guard detachedWorkspace == nil else { return }
        let ids: [String]
        let selectedID: String?
        if let hostID {
            guard coordinator.viewerConnectionManager?.connection(for: hostID)?.isHostConnected == true else { return }
            let windows = remoteSessionWindows(hostId: hostID, sessionName: name)
            ids = windows.map(\.stableId)
            selectedID = selectedRemoteSession?.hostId == hostID && selectedRemoteSession?.sessionName == name
                ? selectedRemoteWindow?.stableId : windows.first(where: \.isWindowActive)?.stableId
        } else {
            let windows = tmuxService.windows.filter { $0.sessionName == name }
            ids = windows.map(\.stableId)
            selectedID = selectedRemoteSession == nil && selectedWindow?.sessionName == name
                ? selectedWindow?.stableId : windows.first(where: \.isWindowActive)?.stableId
        }
        guard
            let workspace = coordinator.detachedWindows.detachSession(
                hostID: hostID, name: name, windowIDs: ids, selectedWindowID: selectedID,
                position: position, allowsResourceOnly: hasIndependentResources(hostID: hostID, sessionName: name), session: terminalSession
            ) else { return }
        openWindow(id: "detached-terminal", value: workspace.id)
        coordinator.detachedWindows.focusNativeWindow(workspaceID: workspace.id)
        coordinator.agentSimulator.register(simulatorWorkspace)
    }

    private func fileLinkIsCurrent(_ request: TerminalFileLinkRequest, detachedRequestID: UUID?) -> Bool {
        if let detachedRequestID {
            return coordinator.detachedWindows.mainRequest?.id == detachedRequestID
        }
        return pendingFileLink == request
    }

    /// Resolve the captured stable target afresh; never use the main scene's previous selection.
    private func handleDetachedWindowRequest(_ request: DetachedTerminalWindows.Request) async {
        let target = request.target
        let sessionName: String
        let windowID: String
        let panes: [PaneState]
        let activePaneID: String?
        if let host = target.hostID {
            guard
                let window = coordinator.remoteSessionStore?.windows(for: host).first(where: { $0.stableId == target.windowID }),
                let connection = coordinator.viewerConnectionManager?.connection(for: host) else {
                attachError = "The source Host or Window is no longer available."
                return
            }
            sessionName = window.sessionName
            windowID = window.id
            panes = window.panes
            activePaneID = window.activePane?.paneId
            selectedWindow = nil
            selectRemoteSession(.init(hostId: host, hostName: connection.hostName, sessionName: sessionName))
            let tabs = remoteSessionTabsStates[remoteTabsKey(hostId: host, sessionName: sessionName)]
            selectedRemoteWindowId = DetachedTerminalWindows.mainSelection(
                target: window.stableId, windows: remoteSessionWindows(hostId: host, sessionName: sessionName).map { ($0.stableId, $0.id) },
                rightSide: tabs?.rightSideWindowIds ?? []
            ) ?? window.id
        } else {
            guard let window = tmuxService.windows.first(where: { $0.stableId == target.windowID }) else {
                attachError = "The source Window is no longer available."
                return
            }
            sessionName = window.sessionName
            windowID = window.id
            panes = window.panes.compactMap { windowManager.paneStates[$0.paneId] }
            activePaneID = window.activePane?.paneId
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            let selection = DetachedTerminalWindows.mainSelection(
                target: window.stableId, windows: tmuxService.windows.filter { $0.sessionName == sessionName }.map { ($0.stableId, $0.id) },
                rightSide: sessionFileTabsStates[sessionName]?.rightSideWindowIds ?? []
            )
            selectedWindow = tmuxService.windows.first { $0.id == selection } ?? window
        }
        switch request.action {
        case let .tab(tab):
            let tabs = tabStore.tabs(hostID: target.hostID, session: sessionName)
            switch tab {
            case let .window(id):
                if tabs.rightSide.contains(tab) {
                    tabStore.userDidSelectTab(hostID: target.hostID, session: sessionName)
                    tabs.selectedRight = tab
                } else {
                    selectTerminalWindow(stableId: id)
                }
            case let .file(id):
                if let host = target.hostID {
                    selectRemoteFileTab(id, hostID: host, sessionName: sessionName)
                } else {
                    selectFileTab(id, sessionName: sessionName, windowId: windowID)
                }
            case let .browser(id):
                if let host = target.hostID {
                    selectRemoteBrowserTab(id, hostId: host, sessionName: sessionName)
                } else {
                    selectBrowserTab(id, sessionName: sessionName, windowId: windowID)
                }
            default: break
            }
        case .show:
            tabStore.userDidSelectTab(hostID: target.hostID, session: sessionName)
            if let host = target.hostID {
                let tabs = remoteSessionTabsStates[remoteTabsKey(hostId: host, sessionName: sessionName)]
                if tabs?.rightSide.contains(.window(target.windowID)) == true {
                    tabs?.selectedRight = .window(target.windowID)
                } else {
                    _ = tabs?.selectLeftTerminalWindow(target.windowID)
                }
            } else {
                let tabs = sessionFileTabsStates[sessionName]
                if tabs?.rightSide.contains(.window(target.windowID)) == true {
                    tabs?.selectedRight = .window(target.windowID)
                } else {
                    _ = tabs?.selectLeftTerminalWindow(target.windowID)
                }
                fileBrowserActiveWindowIds.remove(windowID)
            }
        case let .files(paneID):
            // Supplying only the captured pane prevents the main router from choosing a different pane.
            let source = panes.first(where: { $0.paneId == paneID })?.paneId ?? activePaneID
            openDirectoryTab(
                sessionName: sessionName,
                windowID: windowID,
                hostID: target.hostID,
                paneIDs: source.map { [$0] } ?? [],
                fallbackPaneID: source
            )
        case let .fork(paneID, destination):
            pendingAgentFork = agentForkConfiguration(panes: panes, hostID: target.hostID, destination: destination, focusedPaneID: paneID)
        case let .fileLink(link):
            guard link.hostID == target.hostID, panes.contains(where: { $0.paneId == link.paneID }) else { return }
            await openTerminalFile(link, detachedRequestID: request.id)
        case let .url(raw, paneID):
            guard let url = URL(string: raw), let pane = panes.first(where: { $0.paneId == paneID }) else { return }
            if let host = target.hostID {
                _ = handleRemoteTerminalURLClick(
                    url, hostId: host, sessionName: sessionName, windowId: windowID, paneID: paneID, behaviorOverride: nil
                )
            } else if let window = tmuxService.windows.first(where: { $0.stableId == target.windowID }) {
                _ = handleTerminalURLClick(
                    url,
                    directoryPath: pane.currentPath ?? NSHomeDirectory(),
                    session: tmuxService.sessions.first { $0.sessionName == sessionName },
                    window: window,
                    paneID: paneID,
                    behaviorOverride: nil
                )
            }
        }
    }

    private func selectTerminalWindow(stableId: String) {
        guard ownsTerminal(hostID: selectedRemoteSession?.hostId, windowID: stableId) else {
            coordinator.detachedWindows.focus(hostID: selectedRemoteSession?.hostId, windowID: stableId)
            return
        }
        if let remote = selectedRemoteSession {
            guard
                let target = selectedRemoteSessionWindows.first(where: { $0.stableId == stableId }),
                let connection = coordinator.viewerConnectionManager?.connection(for: remote.hostId)
            else { return }
            let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            let tabs = remoteSessionTabsStates[key]
            guard tabs?.selectLeftTerminalWindow(target.stableId) != false else { return }

            recordUserTabSelection()
            selectedRemoteWindowId = target.id
            requestAutomaticTabFit(windowID: target.stableId)
            let binding = connection.relayClient.workspaceInputState.windowBinding(target: target.id)
            Task {
                _ = await connection.relayClient.sendCommand(
                    SelectTmuxWindow(),
                    paneId: target.id, inputBinding: binding
                )
            }
            return
        }

        guard
            let session = currentLocalSession(),
            let target = session.windows.first(where: { $0.stableId == stableId })
        else { return }
        let tabs = sessionFileTabsStates[session.sessionName]
        guard tabs?.selectLeftTerminalWindow(target.stableId) != false else { return }

        recordUserTabSelection()
        fileBrowserActiveWindowIds.remove(selectedWindow?.id ?? "")
        selectedWindow = target
        requestAutomaticTabFit(windowID: target.stableId)
        let identity = target.panes.first?.workspaceIdentity
        Task {
            try? await tmuxService.selectWindow(target.id, expectedWorkspacePane: identity)
        }
    }

    /// Cmd-W handler exposed to the menu via `.focusedSceneValue` so other
    /// scenes (Settings, About, CLI API Reference) get the default
    /// `performClose:` behaviour while this scene routes through the
    /// existing precedence: remote tab → browser tab → file tab → regular
    /// window. Lifted out so the body's modifier chain stays small enough
    /// for the type checker to handle.
    private func handleCloseCurrentTab() {
        if isPresentingSessionPicker {
            showingSessionSwitcher = false
            showingNewLocalSession = false
            return
        }
        if targetsRightPane {
            closeRightTab()
            return
        }
        if let remote = selectedRemoteSession {
            // If a remote browser tab is selected, Cmd-W closes that tab
            // first — mirrors the local "tab over window" precedence.
            let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            if let id = remoteSessionTabsStates[key]?.selectedFileTabId {
                closeRemoteFileTab(id, hostID: remote.hostId, sessionName: remote.sessionName)
                return
            }
            if let selectedBrowserId = remoteSessionTabsStates[key]?.selectedBrowserTabId {
                closeRemoteBrowserTab(
                    selectedBrowserId,
                    hostId: remote.hostId,
                    sessionName: remote.sessionName
                )
                return
            }
            if let remoteWindow = selectedRemoteWindow {
                requestCloseRemoteWindow(remoteWindow, hostId: remote.hostId)
            }
            return
        }
        let sessionName = currentLocalSession()?.sessionName
        // If a browser tab is selected, Cmd-W closes that tab first.
        if
            let sessionName,
            let selectedBrowserId = sessionFileTabsStates[sessionName]?.selectedBrowserTabId {
            closeBrowserTab(selectedBrowserId, sessionName: sessionName)
            return
        }
        // If a file tab is selected, Cmd-W closes that tab first.
        if
            let sessionName,
            let selectedTabId = sessionFileTabsStates[sessionName]?.selectedFileTabId {
            closeOpenFileTab(selectedTabId, sessionName: sessionName)
            return
        }
        if let sessionName, sessionFileTabsStates[sessionName]?.isGitSelected == true {
            closeGitTab(sessionName: sessionName)
            return
        }
        // The legacy file explorer has no close action.
        guard let window = selectedWindow else { return }
        guard !fileBrowserActiveWindowIds.contains(window.id) else { return }
        requestCloseWindow(window)
    }

    private func closeGitTab(sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        tabStore.userDidSelectTab(hostID: nil, session: sessionName)
        tabs.closeGit()
        reconcileRightPaneSelection(sessionName: sessionName)
        if currentLocalSession()?.sessionName == sessionName {
            requestAutomaticTabFit()
        }
    }

    private func selectSwipedTab(direction: Int, onRight: Bool) {
        guard !isPresentingSessionPicker, let tabs = currentSessionTabs else { return }
        guard !onRight || tabs.isSplit else { return }
        tabs.isRightPaneFocused = onRight
        selectAdjacentTab(direction: direction)
    }

    /// Cmd-Option-Left / Cmd-Option-Right handler. Walks the active session's tab
    /// strip in visual order, even when only Files / Browser tabs remain.
    /// Wraps at both ends within the focused split.
    private func selectAdjacentTab(direction: Int) {
        guard !isPresentingSessionPicker else { return }
        if targetsRightPane {
            selectAdjacentRightTab(direction: direction)
            return
        }
        if let remote = selectedRemoteSession {
            cycleRemoteWindowTab(remote: remote, direction: direction)
            return
        }
        guard let session = currentLocalSession() else { return }
        let window = selectedWindow
        let sessionTabs = sessionFileTabsStates[session.sessionName]
        let entries = tabStripEntries(
            session: session,
            sessionTabs: sessionTabs
        )
        let currentIndex = currentTabIndex(
            entries: entries,
            window: window,
            sessionTabs: sessionTabs
        )
        guard let currentIndex else { return }
        guard
            let next = adjacentTab(to: entries[currentIndex].payload, in: entries.map(\.payload), direction: direction),
            let entry = entries.first(where: { $0.payload == next }) else { return }
        applyTabSelection(
            entry: entry,
            session: session,
            sessionTabs: sessionTabs,
            currentWindow: window
        )
    }

    /// Logical tab-strip entries used by `selectAdjacentTab`. The cases mirror
    /// the order rendered by `WindowTabBar.singleSection` so cycling matches
    /// the user's visual mental model.
    private enum TabStripEntry: Equatable {
        case window(LocalTmuxWindow)
        case fileBrowser
        case gitBrowser
        case fileTab(UUID)
        case browserTab(UUID)

        var payload: TabDragPayload {
            switch self {
            case let .window(window): .window(window.stableId)
            case .fileBrowser: .fileExplorer
            case .gitBrowser: .git
            case let .fileTab(id): .file(id)
            case let .browserTab(id): .browser(id)
            }
        }
    }

    private func tabStripEntries(
        session: LocalTmuxSession,
        sessionTabs: SessionFileTabsState?
    ) -> [TabStripEntry] {
        // Walk the same reconciled, drag-reordered order the visible
        // `WindowTabBar` renders — sharing `reconciledOrder` keeps keyboard
        // cycling and the on-screen strip from drifting apart (issue #566).
        // An explicitly opened Git tab participates in the same order.
        let order = TabDragPayload.reconciledOrder(
            windowIds: session.windows.filter { ownsTerminal(hostID: nil, windowID: $0.stableId) }.map(\.stableId),
            fileTabIds: sessionTabs?.openFileTabs.map(\.id) ?? [],
            browserTabIds: sessionTabs?.openBrowserTabs.map(\.id) ?? [],
            storedOrder: sessionTabs?.tabOrder ?? [],
            includeFileExplorer: false
        )
        // Window ids are unique within a session, so assert that invariant
        // rather than silently tolerating a duplicate.
        let windowsById = Dictionary(uniqueKeysWithValues: session.windows.map { ($0.stableId, $0) })
        let grouped = sessionTabs?.groupedTabOrder(order, paneOrder: navigationSourcePanes.map(\.paneId)) ?? order
        return grouped.compactMap { payload in
            guard sessionTabs?.rightSide.contains(payload) != true else { return nil }
            return switch payload {
            case let .window(id):
                windowsById[id].map(TabStripEntry.window)
            case .fileExplorer:
                .fileBrowser
            case .git:
                .gitBrowser
            case let .file(id):
                .fileTab(id)
            case let .browser(id):
                .browserTab(id)
            }
        }
    }

    private func currentTabIndex(
        entries: [TabStripEntry],
        window: LocalTmuxWindow?,
        sessionTabs: SessionFileTabsState?
    ) -> Int? {
        // Browser tab > file tab > git > file browser > selected window. The
        // first match wins so the user's actual visible tab is the cycling
        // anchor.
        if let selectedBrowserId = sessionTabs?.selectedBrowserTabId {
            if let idx = entries.firstIndex(of: .browserTab(selectedBrowserId)) {
                return idx
            }
        }
        if let selectedFileId = sessionTabs?.selectedFileTabId {
            if let idx = entries.firstIndex(of: .fileTab(selectedFileId)) {
                return idx
            }
        }
        if sessionTabs?.isGitSelected == true {
            if let idx = entries.firstIndex(of: .gitBrowser) {
                return idx
            }
        }
        if fileBrowserActiveWindowIds.contains(window?.id ?? "") {
            if let idx = entries.firstIndex(of: .fileBrowser) {
                return idx
            }
        }
        return window.flatMap { entries.firstIndex(of: .window($0)) }
    }

    private func applyTabSelection(
        entry: TabStripEntry,
        session: LocalTmuxSession,
        sessionTabs: SessionFileTabsState?,
        currentWindow: LocalTmuxWindow?
    ) {
        let windowID = currentWindow?.id ?? ""
        tabStore.userDidSelectTab(hostID: nil, session: session.sessionName)
        switch entry {
        case let .window(window):
            selectTerminalWindow(stableId: window.stableId)
        case .fileBrowser:
            fileBrowserActiveWindowIds.insert(windowID)
            sessionTabs?.isGitSelected = false
            if fileBrowserStates[session.sessionName] == nil {
                fileBrowserStates[session.sessionName] = FileBrowserState()
            }
            if sessionFileTabsStates[session.sessionName] == nil {
                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
            }
            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil
            sessionFileTabsStates[session.sessionName]?.selectedBrowserTabId = nil
        case .gitBrowser:
            // Build the store before the state flip so gitPane renders
            // GitBrowserView immediately (no one-frame ProgressView flash).
            ensureGitStore(
                sessionName: session.sessionName,
                directoryPath: localDirectoryPath(sessionName: session.sessionName, window: currentWindow)
            )
            fileBrowserActiveWindowIds.remove(windowID)
            if sessionFileTabsStates[session.sessionName] == nil {
                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
            }
            sessionFileTabsStates[session.sessionName]?.selectLeftGit()
        case let .fileTab(tabId):
            selectFileTab(tabId, sessionName: session.sessionName, windowId: windowID)
        case let .browserTab(tabId):
            selectBrowserTab(tabId, sessionName: session.sessionName, windowId: windowID)
        }
    }

    private func remoteTabEntries(remote: RemoteSessionSelection) -> [TabDragPayload] {
        let windows = selectedRemoteSessionWindows.filter { ownsTerminal(hostID: remote.hostId, windowID: $0.stableId) }
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        let tabs = remoteSessionTabsStates[key]
        let order = TabDragPayload.reconciledOrder(
            windowIds: windows.map(\.stableId),
            fileTabIds: tabs?.openFileTabs.map(\.id) ?? [],
            browserTabIds: tabs?.openBrowserTabs.map(\.id) ?? [],
            storedOrder: tabs?.tabOrder ?? [],
            includeFileExplorer: false,
            includeGit: false
        )
        return (tabs?.groupedTabOrder(order, paneOrder: navigationSourcePanes.map(\.paneId)) ?? order).filter { tabs?.rightSide.contains($0) != true }
    }

    private func cycleRemoteWindowTab(remote: RemoteSessionSelection, direction: Int) {
        let tabs = currentSessionTabs
        let entries = remoteTabEntries(remote: remote)

        // File tab > browser tab > selected window. The first match wins so the user's
        // actual visible tab is the cycling anchor.
        let currentIndex: Int?
        if let selectedFileId = tabs?.selectedFileTabId {
            currentIndex = entries.firstIndex(of: .file(selectedFileId))
        } else if let selectedBrowserId = tabs?.selectedBrowserTabId {
            currentIndex = entries.firstIndex(of: .browser(selectedBrowserId))
        } else if let currentId = selectedRemoteWindow?.stableId {
            currentIndex = entries.firstIndex(of: .window(currentId))
        } else {
            currentIndex = nil
        }
        guard let currentIndex else { return }
        guard let next = adjacentTab(to: entries[currentIndex], in: entries, direction: direction) else { return }
        selectRemoteTab(next, remote: remote)
    }

    private func selectRemoteTab(_ entry: TabDragPayload, remote: RemoteSessionSelection) {
        switch entry {
        case let .window(id):
            selectTerminalWindow(stableId: id)
        case let .browser(id):
            selectRemoteBrowserTab(id, hostId: remote.hostId, sessionName: remote.sessionName)
        case let .file(id):
            selectRemoteFileTab(id, hostID: remote.hostId, sessionName: remote.sessionName)
        case .fileExplorer,
             .git:
            break
        }
    }

    // MARK: - Session Navigation

    /// Selects a local session for the left pane, skipping any window the user
    /// has parked on the right side so the two panes don't end up showing the
    /// same terminal after a session round-trip. Shared by the sidebar row
    /// button and session navigation.
    private func selectLocalSession(_ session: LocalTmuxSession) {
        tabStore.userDidSelectSession()
        selectedRemoteSession = nil
        selectedRemoteWindowId = nil
        repairLocalLeftSelection(sessionName: session.sessionName, followsActive: true)
        if selectedWindow?.sessionName == session.sessionName {
            requestAutomaticTabFit()
        }
    }

    /// One entry in the sidebar's combined, ordered session list — a local
    /// session or a remote host's session — used by session navigation and search.
    private enum SidebarSessionEntry {
        case local(LocalTmuxSession)
        case remote(hostId: String, hostName: String, session: TmuxSession)
    }

    /// Rebuilds the sidebar's visible session order: local sessions first (in
    /// manual or `sidebarSortMode` order), then each paired host's sessions in
    /// `pairedHosts` order, each independently sorted the same way its
    /// `RemoteHostSidebarSection` sorts them. Kept in lockstep with `windowList`
    /// and `RemoteHostSidebarSection` so keyboard cycling matches what's on
    /// screen.
    private func orderedSidebarSessions() -> [SidebarSessionEntry] {
        let localSorted = sortedLocalSessions
        var entries: [SidebarSessionEntry] = localSorted.map { SidebarSessionEntry.local($0) }

        if settings.hasRemoteHosts, let sessionStore = coordinator.remoteSessionStore {
            for host in settings.pairedHosts {
                // Mirror RemoteHostSidebarSection: a version-mismatched host
                // renders a placeholder row instead of its session buttons, yet
                // the store can still hold sessions cached from before the
                // mismatch. Skip them so cycling never lands on a session that
                // isn't actually on screen.
                let connection = coordinator.viewerConnectionManager?.connection(for: host.id)
                if connection?.versionMismatch != nil {
                    continue
                }
                let sorted = SessionSortData.sortedRemoteSessions(
                    sessionStore.sessions(for: host.id),
                    mode: settings.sidebarSortMode,
                    sidebarFields: settings.sidebarFields,
                    sidebarTerminalFields: settings.sidebarTerminalFields,
                    homeDirectory: sessionStore.homeDirectoryByHost[host.id],
                    preferredSessionNames: settings.remoteSessionOrder(for: host.id)
                )
                entries.append(contentsOf: sorted.map { session in
                    SidebarSessionEntry.remote(hostId: host.id, hostName: host.displayName, session: session)
                })
            }
        }
        return entries
    }

    /// Index of the currently-selected session within `entries`, or nil when
    /// nothing is selected (or the selection isn't present in the list).
    private func currentSidebarSessionIndex(in entries: [SidebarSessionEntry]) -> Int? {
        if let remote = selectedRemoteSession {
            return entries.firstIndex { entry in
                if case let .remote(hostId, _, session) = entry {
                    return hostId == remote.hostId && session.sessionName == remote.sessionName
                }
                return false
            }
        }
        if let session = currentLocalSession() {
            return entries.firstIndex { entry in
                if case let .local(localSession) = entry {
                    return localSession.sessionName == session.sessionName
                }
                return false
            }
        }
        return nil
    }

    /// Selects the session `direction` steps away
    /// from the current one in the sidebar's combined local+remote order,
    /// wrapping around the ends. When nothing is selected yet it steps in from
    /// the leading edge (forward) or trailing edge (backward). No-op when there
    /// are no sessions.
    private func selectAdjacentSession(direction: Int) {
        guard detachedWorkspace == nil else { return }
        let entries = orderedSidebarSessions()
        guard !entries.isEmpty else { return }
        let nextIndex: Int
        if let currentIndex = currentSidebarSessionIndex(in: entries) {
            nextIndex = (currentIndex + direction + entries.count) % entries.count
        } else {
            nextIndex = direction >= 0 ? 0 : entries.count - 1
        }
        switch entries[nextIndex] {
        case let .local(session):
            selectLocalSession(session)
            // Keep the newly-selected row visible: with many sessions the
            // pick can land outside the sidebar's scroll region. Both local
            // and remote rows are keyed by `sessionName` in the ScrollViewReader.
            scrollToWindowId = session.sessionName
        case let .remote(hostId, hostName, session):
            selectRemoteSession(.init(
                hostId: hostId,
                hostName: hostName,
                sessionName: session.sessionName
            ))
            selectedRemoteWindowId = nil
            selectedWindow = nil
            scrollToWindowId = session.sessionName
            requestAutomaticTabFit()
        }
    }

    /// Cmd-Option-F opens content search in a Host-backed directory tab.
    private func handleOpenContentSearch() {
        if let remote = selectedRemoteSession {
            let tabs = tabStore.tabs(hostID: remote.hostId, session: remote.sessionName)
            if tabs.selectedFileTabId.flatMap({ tabs.directoryTabs[$0] }) != nil {
                tabs.focusContentSearch { nil }
            } else if let window = selectedRemoteWindow {
                openDirectoryTab(
                    sessionName: remote.sessionName,
                    windowID: window.id,
                    hostID: remote.hostId,
                    paneIDs: window.panes.map(\.paneId),
                    fallbackPaneID: window.activePane?.paneId, focusSearch: true
                )
            }
        } else if let session = currentLocalSession() {
            let tabs = tabStore.tabs(hostID: nil, session: session.sessionName)
            if tabs.selectedFileTabId.flatMap({ tabs.directoryTabs[$0] }) != nil {
                tabs.focusContentSearch { nil }
            } else if let window = selectedWindow {
                openDirectoryTab(
                    sessionName: session.sessionName,
                    windowID: window.id,
                    hostID: nil,
                    paneIDs: window.panes.map(\.paneId),
                    fallbackPaneID: window.activePane?.paneId, focusSearch: true
                )
            }
        }
    }

    // MARK: - File Browser Tabs

    /// Picks the return target for a file tab opened from the markdown
    /// "Want to open …?" suggestion, based on what `windowId` is currently
    /// showing (issue #700). The suggestion's "Yes" button lives in the tab
    /// strip, so the user could be on the terminal, the Git tab, or the
    /// file-browser tree when they accept — recording the matching origin makes
    /// closing the opened tab land them back where they were instead of always
    /// dropping onto the file tree (the previous behaviour, since the accept
    /// path passed no origin).
    ///
    /// Only three prior views are expressible as a `FileTabOrigin`: the
    /// terminal, the Git tab, and the tree (`nil`, which keeps the tree
    /// visible underneath). A currently-selected file or browser tab has no
    /// origin case, so it falls back to the window's terminal.
    private func openSuggestionOrigin(for windowId: String, sessionName: String) -> FileTabOrigin? {
        // Git and file-browser modes are mutually exclusive, and selecting any
        // file/browser tab clears git mode, so an active Git tab is unambiguous.
        if sessionFileTabsStates[sessionName]?.isGitSelected == true {
            return .gitTab(windowId: windowId)
        }
        // The tree is showing only in file-browser mode with nothing selected on
        // the left; a nil origin preserves the existing "return to tree" flow.
        let tabs = sessionFileTabsStates[sessionName]
        let showingTree = fileBrowserActiveWindowIds.contains(windowId)
            && tabs?.selectedFileTabId == nil
            && tabs?.selectedBrowserTabId == nil
        return showingTree ? nil : .terminalWindow(windowId)
    }

    /// Opens a file in a new tab next to the file browser, or selects the existing
    /// tab if the file is already open. Newly opened tabs become the active view.
    /// Tabs are scoped to the tmux session so they remain visible when the user
    /// switches between windows in the same session.
    ///
    /// Also ensures `fileBrowserActiveWindowIds` contains `windowId` so the
    /// FileBrowserView for that window stays mounted while the file tab is
    /// selected — its `directoryChanges` task is what drives tab deletion
    /// state, so it must continue running underneath the visible file content.
    ///
    /// `origin` records where the open came from (a terminal click, or the Git
    /// tab); closing the tab routes the user back there instead of leaving them
    /// on the file browser tree. When an existing tab is re-opened, only a
    /// non-nil incoming origin overwrites the stored value — a tree/context-menu
    /// re-open carries no origin and must not silently clear the
    /// previously-recorded return target.
    private func openFileInNewTab(
        path: String,
        directoryPath: String,
        sessionName: String,
        windowId: String,
        origin: FileTabOrigin? = nil
    ) {
        tabStore.userDidSelectTab(hostID: nil, session: sessionName)
        fileBrowserActiveWindowIds.insert(windowId)
        sessionFileTabsStates[sessionName]?.isGitSelected = false
        if fileBrowserStates[sessionName] == nil {
            fileBrowserStates[sessionName] = FileBrowserState()
        }
        if sessionFileTabsStates[sessionName] == nil {
            sessionFileTabsStates[sessionName] = SessionFileTabsState()
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        let useSplit = settings.alwaysOpenFilesInSplit
        if let existingIndex = tabs.openFileTabs.firstIndex(where: { $0.path == path }) {
            if let origin {
                tabs.openFileTabs[existingIndex].origin = origin
            }
            let existingId = tabs.openFileTabs[existingIndex].id
            if tabs.rightSide.contains(.file(existingId)) {
                tabs.selectedRight = .file(existingId)
            } else {
                tabs.selectedFileTabId = existingId
            }
            return
        }
        let newTab = OpenFileTab(
            path: path,
            directoryPath: directoryPath,
            origin: origin
        )
        tabs.openFileTabs.append(newTab)
        if useSplit {
            tabs.rightSide.insert(.file(newTab.id))
            tabs.selectedRight = .file(newTab.id)
        } else {
            tabs.selectedFileTabId = newTab.id
        }
    }

    /// Bind resolution to the clicked pane, not whichever pane becomes focused later.
    private func openTerminalFile(_ request: TerminalFileLinkRequest, detachedRequestID: UUID? = nil) async {
        let source: FileBrowserSource
        let sessionName: String
        let windowID: String
        let stableWindowID: String
        let fileContext: RepositoryFileContext?
        let inputBinding: ViewerWorkspaceInputBinding?
        let expectedWorkspacePane: WorkspacePaneIdentity?
        if let hostID = request.hostID {
            guard
                let remote = selectedRemoteSession, remote.hostId == hostID,
                let window = selectedRemoteSessionWindows.first(where: { $0.panes.contains { $0.paneId == request.paneID } }),
                ownsTerminal(hostID: hostID, windowID: window.stableId),
                let pane = window.panes.first(where: { $0.paneId == request.paneID }) else { return }
            sessionName = remote.sessionName
            windowID = window.id
            stableWindowID = window.stableId
            fileContext = RepositoryFileContext(pane: pane)
            inputBinding = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient.workspaceInputState.binding(paneID: request.paneID) ?? .unavailable
            expectedWorkspacePane = nil
            source = .remote(
                hostID: hostID,
                paneID: request.paneID,
                connection: coordinator.viewerConnectionManager?.connection(for: hostID)
            )
        } else {
            guard
                selectedRemoteSession == nil,
                let window = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == request.paneID } }),
                window.sessionName == currentLocalSession()?.sessionName,
                ownsTerminal(hostID: nil, windowID: window.stableId),
                let pane = windowManager.paneStates[request.paneID] else { return }
            sessionName = window.sessionName
            windowID = window.id
            stableWindowID = window.stableId
            fileContext = RepositoryFileContext(pane: pane)
            inputBinding = nil
            expectedWorkspacePane = pane.workspaceIdentity
            source = .local(paneID: request.paneID, tmux: tmuxService, windows: windowManager)
        }
        let target = ManualBrowserTarget(hostID: request.hostID, sessionName: sessionName)
        let initialSelection = browserOpenSelection(for: target)
        do {
            let destination = try await TerminalFileDestination.resolve(path: request.path, context: fileContext, source: source)
            let shouldPreview = request.prefersPreview && TerminalArtifactPreview.supports(path: destination.file)
            let descriptor = shouldPreview ? nil : try await requestHostFileTab(hostID: request.hostID, sessionName: sessionName, paneID: request.paneID, new: request.opensNewTab, inputBinding: inputBinding, expectedWorkspacePane: expectedWorkspacePane)
            try Task.checkCancellation()
            guard fileLinkIsCurrent(request, detachedRequestID: detachedRequestID) else { return }
            if let hostID = request.hostID {
                guard
                    selectedRemoteSession?.hostId == hostID, selectedRemoteSession?.sessionName == sessionName,
                    ownsTerminal(hostID: hostID, windowID: stableWindowID),
                    selectedRemoteSessionWindows.contains(where: { $0.id == windowID && $0.panes.contains { $0.paneId == request.paneID && RepositoryFileContext(pane: $0) == fileContext } }) else { return }
            } else {
                guard
                    selectedRemoteSession == nil, currentLocalSession()?.sessionName == sessionName,
                    ownsTerminal(hostID: nil, windowID: stableWindowID),
                    tmuxService.windows.contains(where: { $0.id == windowID && $0.panes.contains { $0.paneId == request.paneID } }),
                    let pane = windowManager.paneStates[request.paneID], RepositoryFileContext(pane: pane) == fileContext else { return }
            }
            guard initialSelection == browserOpenSelection(for: target) else { return }
            if shouldPreview, let path = destination.file, let fileContext {
                presentArtifactPreview(.init(link: request, context: fileContext, source: source, path: path))
            } else if let descriptor {
                let tab = try presentHostFileTab(descriptor, hostID: request.hostID, windowID: windowID)
                tab.openTerminalFile(destination, paneID: request.paneID)
            }
        } catch is CancellationError { }
        catch {
            if fileLinkIsCurrent(request, detachedRequestID: detachedRequestID) {
                attachError = "Cannot open Host path: \(error.localizedDescription)"
            }
        }
    }

    private func presentArtifactPreview(_ preview: TerminalArtifactPreview) {
        artifactPreviewWindow?.close()
        artifactPreviewWindow = nil
        let controller = TerminalArtifactPreviewWindowController(
            preview: preview,
            colorScheme: settings.theme.workspaceColorScheme,
            onOpenFiles: { request in
                artifactPreviewWindow?.close()
                artifactPreviewWindow = nil
                pendingFileLink = request
            }
        )
        controller.onWindowClosed = { [weak controller] in
            guard let controller, artifactPreviewWindow === controller else { return }
            artifactPreviewWindow = nil
        }
        artifactPreviewWindow = controller
        controller.show()
    }

    /// Captures a pane in the source window as the initial directory and return target.
    private func openDirectoryTab(sessionName: String, windowID: String, hostID: String?, paneIDs: [String], fallbackPaneID: String?, path: String? = nil, selectedFile: String? = nil, focusSearch: Bool = false, new: Bool = false) {
        if supportsIndependentResources(hostID: hostID) {
            let directory = path ?? (hostID == nil ? windowManager.paneStates[fallbackPaneID ?? ""]?.currentPath : nil)
            openIndependentResource(.files, hostID: hostID, sessionName: sessionName, location: directory, selectedFile: selectedFile, focusSearch: focusSearch)
            return
        }
        tabStore.userDidSelectTab(hostID: hostID, session: sessionName)
        let localWindows = tmuxService.windows.filter { $0.sessionName == sessionName }
        let remoteWindows = hostID.map { remoteSessionWindows(hostId: $0, sessionName: sessionName) } ?? []
        let focused = terminalQuickActions.active.flatMap { $0.hostID == hostID ? $0.paneID : nil }
        let candidates = paneIDs.isEmpty
            ? (hostID == nil ? localWindows.first { $0.id == windowID }?.panes.map(\.paneId) : remoteWindows.first { $0.id == windowID }?.panes.map(\.paneId)) ?? []
            : paneIDs
        guard let paneID = FileBrowserTab.sourcePaneID(in: candidates, focusedPaneID: focused, activePaneID: fallbackPaneID) else {
            attachError = "This window no longer has a source pane."
            return
        }
        let target = ManualBrowserTarget(hostID: hostID, sessionName: sessionName)
        let selection = browserOpenSelection(for: target)
        let inputBinding = hostID.map { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.workspaceInputState.binding(paneID: paneID) ?? .unavailable }
        let expectedWorkspacePane = hostID == nil ? windowManager.paneStates[paneID]?.workspaceIdentity : nil
        filesOpenTask?.cancel()
        filesOpenTask = Task {
            do {
                let descriptor = try await requestHostFileTab(hostID: hostID, sessionName: sessionName, paneID: paneID, new: new, inputBinding: inputBinding, expectedWorkspacePane: expectedWorkspacePane)
                try Task.checkCancellation()
                guard browserOpenSelection(for: target) == selection else { return }
                let tab = try presentHostFileTab(descriptor, hostID: hostID, windowID: windowID)
                if let path {
                    tab.navigate(path)
                    tab.selectedFile = selectedFile
                }
                if focusSearch {
                    tab.searchMode = .content
                    tab.searchFocusRequest += 1
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled {
                    attachError = error.localizedDescription
                }
            }
        }
    }

    private func requestHostFileTab(hostID: String?, sessionName: String, paneID: String, new: Bool = false, inputBinding: ViewerWorkspaceInputBinding?, expectedWorkspacePane: WorkspacePaneIdentity?) async throws -> HostFileTab {
        if supportsIndependentResources(hostID: hostID) {
            let tabs = manualBrowserTabs(for: .init(hostID: hostID, sessionName: sessionName))
            if !new, let reusable = tabs?.directoryTabs.values.filter({ $0.hostTab?.resourceSessionID != nil }).max(by: { $0.lastSelectedAt < $1.lastSelectedAt })?.hostTab {
                return reusable
            }
            let result = try await requestIndependentResource(.files, hostID: hostID, sessionName: sessionName)
            guard let file = result.file else { throw FileBrowserError.message("No Files tab was returned.") }
            _ = try claimHostFileTab(file, hostID: hostID)
            return file
        }
        if let hostID {
            return try await HostFileTabClient.open(connection: coordinator.viewerConnectionManager?.connection(for: hostID), sessionName: sessionName, paneID: paneID, new: new, inputBinding: inputBinding)
        }
        let tab = try await coordinator.hostFileTabs.open(sessionName: sessionName, paneID: paneID, new: new, expectedWorkspacePane: expectedWorkspacePane)
        if let expectedWorkspacePane, !expectedWorkspacePane.isSamePane(as: windowManager.paneStates[paneID]?.workspaceIdentity) {
            throw CancellationError()
        }
        return tab
    }

    private func presentHostFileTab(_ descriptor: HostFileTab, hostID: String?, windowID: String?) throws -> FileBrowserTab {
        let tab = try claimHostFileTab(descriptor, hostID: hostID)
        let tabs = tabStore.tabs(hostID: hostID, session: descriptor.sessionName)
        tab.lastSelectedAt = Date()
        if let windowID, descriptor.resourceSessionID == nil, let index = tabs.openFileTabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.openFileTabs[index].origin = .terminalWindow(windowID)
        }
        if tabs.rightSide.contains(.file(tab.id)) {
            tabs.rightSide.insert(.file(tab.id))
            tabs.selectedRight = .file(tab.id)
        } else {
            if hostID == nil {
                let presentationWindowID = selectedWindow.flatMap { $0.sessionName == descriptor.sessionName ? $0.id : nil } ?? windowID
                tabs.selectLeftFileTab(tab.id, windowID: presentationWindowID, legacyExplorerWindows: &fileBrowserActiveWindowIds)
            } else {
                tabs.selectedFileTabId = tab.id
                tabs.selectedBrowserTabId = nil
            }
        }
        return tab
    }

    private func claimHostFileTab(_ descriptor: HostFileTab, hostID: String?) throws -> FileBrowserTab {
        guard coordinator.detachedWindows.store(for: detachedWorkspace?.id) === tabStore else { throw CancellationError() }
        let catalog: [HostFileTab]
        if let hostID {
            catalog = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient.fileTabs ?? []
        } else {
            catalog = coordinator.hostFileTabs.tabs
        }
        syncHostFiles(hostID: hostID, descriptors: catalog.filter { $0.id != descriptor.id } + [descriptor])
        coordinator.detachedWindows.claimFile(descriptor.id, hostID: hostID, session: descriptor.sessionName, workspaceID: detachedWorkspace?.id)
        let tabs = tabStore.tabs(hostID: hostID, session: descriptor.sessionName)
        guard let tab = tabs.directoryTabs[descriptor.id] else { throw FileBrowserError.message("The Host Files tab is no longer available.") }
        return tab
    }

    private func selectRemoteFileTab(_ id: UUID, hostID: String, sessionName: String) {
        guard let tabs = remoteSessionTabsStates[remoteTabsKey(hostId: hostID, sessionName: sessionName)] else { return }
        tabStore.userDidSelectTab(hostID: hostID, session: sessionName)
        if tabs.rightSide.contains(.file(id)) {
            tabs.selectedRight = .file(id)
        } else {
            tabs.selectedFileTabId = id
            tabs.selectedBrowserTabId = nil
        }
    }

    private var remoteFileCatalogs: [String: [HostFileTab]] {
        guard let manager = coordinator.viewerConnectionManager else { return [:] }
        return Dictionary(uniqueKeysWithValues: manager.managedHostIDs.compactMap { hostID in
            guard let client = manager.connection(for: hostID)?.relayClient, client.isHostConnected else { return nil }
            return (hostID, client.fileTabs)
        })
    }

    private func syncHostFiles(hostID: String?, descriptors: [HostFileTab]) {
        let windows: [String: [String]]
        if let hostID {
            windows = Dictionary(grouping: coordinator.remoteSessionStore?.windows(for: hostID) ?? [], by: \.sessionName)
                .mapValues { $0.map(\.stableId) }
        } else {
            windows = Dictionary(grouping: tmuxService.windows, by: \.sessionName).mapValues { $0.map(\.stableId) }
        }
        coordinator.detachedWindows.syncFileTabs(hostID: hostID, descriptors: descriptors, sessionWindows: windows)
    }

    private func closeRemoteFileTab(_ id: UUID, hostID: String, sessionName: String) {
        guard let tabs = remoteSessionTabsStates[remoteTabsKey(hostId: hostID, sessionName: sessionName)] else { return }
        if tabs.directoryTabs[id]?.hostTab != nil {
            guard
                tabs.beginClosingHostFileTab(id, onClose: { result in
                    finishRemoteFileTabClose(result, hostID: hostID, sessionName: sessionName)
                }) else { return }
            Task {
                defer { tabs.cancelClosingHostFileTab(id) }
                do {
                    try await HostFileTabClient.close(connection: coordinator.viewerConnectionManager?.connection(for: hostID), id: id)
                    if let values = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient.fileTabs {
                        syncHostFiles(hostID: hostID, descriptors: values)
                    }
                } catch { attachError = "Cannot close Host Files: \(error.localizedDescription)" }
            }
            return
        }
        if let result = tabs.removeFileTab(id) {
            finishRemoteFileTabClose(result, hostID: hostID, sessionName: sessionName)
        }
    }

    private func finishRemoteFileTabClose(_ result: SessionFileTabsState.FileTabCloseResult, hostID: String, sessionName: String) {
        reconcileRemoteRightPaneSelection(
            hostId: hostID,
            sessionName: sessionName,
            sessionWindows: remoteSessionWindows(hostId: hostID, sessionName: sessionName)
        )
        guard
            result.wasSelectedLeft, selectedRemoteSession?.hostId == hostID,
            selectedRemoteSession?.sessionName == sessionName,
            let tabs = remoteSessionTabsStates[remoteTabsKey(hostId: hostID, sessionName: sessionName)] else { return }
        if
            case let .terminalWindow(windowID) = result.origin,
            let window = remoteSessionWindows(hostId: hostID, sessionName: sessionName).first(where: { $0.id == windowID }),
            ownsTerminal(hostID: hostID, windowID: window.stableId),
            !tabs.rightSide.contains(.window(window.stableId)) {
            selectedRemoteWindowId = windowID
        }
        if tabs.selectedFileTabId == nil, tabs.selectedBrowserTabId == nil, !tabs.isGitSelected {
            requestAutomaticTabFit()
        }
    }

    private func selectFileTab(_ tabId: UUID, sessionName: String, windowId: String) {
        tabStore.userDidSelectTab(hostID: nil, session: sessionName)
        if sessionFileTabsStates[sessionName] == nil {
            sessionFileTabsStates[sessionName] = SessionFileTabsState()
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        if tabs.directoryTabs[tabId] == nil, fileBrowserStates[sessionName] == nil {
            fileBrowserStates[sessionName] = FileBrowserState()
        }
        if tabs.rightSide.contains(.file(tabId)) {
            tabs.selectedRight = .file(tabId)
            return
        }
        tabs.selectLeftFileTab(tabId, windowID: windowId, legacyExplorerWindows: &fileBrowserActiveWindowIds)
    }

    /// Toggles which side of the split a tab strip entry lives on (issue #498).
    /// The receiving side becomes the entry's selected slot; the originating
    /// side has its selection reset if it pointed at the moved entry. After
    /// every move `reconcileRightPaneSelection` re-picks a right-pane selection
    /// so the pane doesn't show the empty placeholder while content still lives
    /// over there.
    ///
    /// `windowId` is the *current left-pane window* — used to flip
    /// `fileBrowserActiveWindowIds` and `selectedWindow` for moves that land
    /// content back on the left. Terminal-only sessions don't materialise a
    /// `SessionFileTabsState` until the first tab opens, so the state is
    /// created on demand for the very first split-toggle click.
    private func toggleSplit(_ payload: TabDragPayload, sessionName: String, windowId: String?) {
        if sessionFileTabsStates[sessionName] == nil {
            sessionFileTabsStates[sessionName] = SessionFileTabsState()
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        // Reject payloads whose underlying data has gone away between the
        // last reconcile and the click (extremely rare; we'd otherwise
        // insert a dangling id into `rightSide`).
        switch payload {
        case let .window(id) where !ownsTerminal(hostID: nil, windowID: id): return
        case let .file(id) where !tabs.openFileTabs.contains(where: { $0.id == id }): return
        case let .browser(id) where !tabs.openBrowserTabs.contains(where: { $0.id == id }): return
        default: break
        }

        // Build the Git store before either branch flips state, so whichever
        // pane ends up showing git renders GitBrowserView immediately rather
        // than flashing a ProgressView for one frame.
        if case .git = payload, gitWorkbenchStores[sessionName] == nil {
            let window = tmuxService.windows.first { $0.id == windowId && $0.sessionName == sessionName }
            ensureGitStore(sessionName: sessionName, directoryPath: localDirectoryPath(sessionName: sessionName, window: window))
        }

        if tabs.rightSide.contains(payload) {
            // Moving back to the left side — receiving side becomes this entry.
            tabs.rightSide.remove(payload)
            if tabs.selectedRight == payload {
                tabs.selectedRight = nil
            }
            switch payload {
            case let .window(id):
                if
                    let restored = tmuxService.windows.first(where: {
                        $0.sessionName == sessionName && $0.stableId == id
                    }) {
                    _ = tabs.selectLeftTerminalWindow(id)
                    selectedWindow = restored
                }
            case .fileExplorer:
                if let windowId {
                    fileBrowserActiveWindowIds.insert(windowId)
                }
                tabs.isGitSelected = false
            case .git:
                if let windowId {
                    fileBrowserActiveWindowIds.remove(windowId)
                }
                tabs.selectLeftGit()
            case let .file(id):
                tabs.selectLeftFileTab(id, windowID: windowId, legacyExplorerWindows: &fileBrowserActiveWindowIds)
            case let .browser(id):
                tabs.selectedBrowserTabId = id
                tabs.selectedFileTabId = nil
                if let windowId {
                    fileBrowserActiveWindowIds.remove(windowId)
                }
            }
        } else {
            // Moving to the right side — becomes the right pane's selection.
            tabs.rightSide.insert(payload)
            tabs.selectedRight = payload
            switch payload {
            case .window: break // Reconcile both sides before choosing a new left terminal.
            case .fileExplorer:
                if let windowId {
                    fileBrowserActiveWindowIds.remove(windowId)
                }
            case .git:
                tabs.isGitSelected = false
            case let .file(id):
                if tabs.selectedFileTabId == id {
                    tabs.selectedFileTabId = nil
                }
            case let .browser(id):
                if tabs.selectedBrowserTabId == id {
                    tabs.selectedBrowserTabId = nil
                }
            }
        }
        reconcileRightPaneSelection(sessionName: sessionName)
    }

    /// Keeps the right pane's selection coherent with the tabs still on that
    /// side. Clears a dangling selection, then auto-picks an entry on the
    /// right when nothing is selected but at least one tab remains there.
    /// The auto-pick prefers terminals in visible tab order, avoiding the "No Tab
    /// Selected" placeholder whenever real right-side content exists.
    private func reconcileRightPaneSelection(sessionName: String) {
        defer {
            if currentLocalSession()?.sessionName == sessionName {
                repairLocalLeftSelection(sessionName: sessionName)
            }
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        let sessionWindows = tmuxService.windows.filter {
            $0.sessionName == sessionName && ownsTerminal(hostID: nil, windowID: $0.stableId)
        }
        let ownedIDs = Set(sessionWindows.map(\.stableId))
        tabs.rightSide = tabs.rightSide.filter {
            if case let .window(id) = $0 {
                ownedIDs.contains(id)
            } else {
                true
            }
        }
        tabs.reconcileRightPaneSelection(sessionWindowIDs: sessionWindows.map(\.stableId), includeLocalTabs: true)
    }

    /// Routes a URL clicked in the terminal. Three flows are possible:
    ///
    /// - `file://` URL with `openClickedFileInNewTab` enabled: opens the file
    ///   in a new file tab. Returns `true`.
    /// - http/https/ftp URL: the destination depends on the effective behavior
    ///   for the URL — a one-click modifier override, then a per-domain rule,
    ///   then the global `settings.browserLinkBehavior`.
    ///   `.alwaysInApp` opens the source pane's Host browser and returns `true`.
    ///   `.alwaysInDefaultBrowser` returns `false` so the click falls through
    ///   to `NSWorkspace.shared.open`. `.ask` shows a confirmation dialog
    ///   (with "remember my choice" toggles) and returns `true` so the system
    ///   handler doesn't race with the user.
    /// - Anything else: `false`, system handler takes over.
    private func handleTerminalURLClick(
        _ url: URL,
        directoryPath: String,
        session: LocalTmuxSession?,
        window: LocalTmuxWindow,
        paneID: String,
        behaviorOverride: BrowserLinkBehavior?
    ) -> Bool {
        if url.isFileURL {
            guard settings.openClickedFileInNewTab, let session else {
                return false
            }
            openFileInNewTab(
                path: url.path,
                directoryPath: directoryPath,
                sessionName: session.sessionName,
                windowId: window.id,
                origin: .terminalWindow(window.id)
            )
            return true
        }

        guard let session, BrowserURLDispatcher.canHandle(url) else {
            return false
        }

        let effective = settings.effectiveBrowserBehavior(for: url, override: behaviorOverride)

        switch effective {
        case .alwaysInApp:
            openPaneBrowser(hostID: nil, sessionName: session.sessionName, paneID: paneID, url: url)
            return true
        case .alwaysInDefaultBrowser:
            return false
        case .ask:
            pendingBrowserURLPrompt = PendingBrowserURLPrompt(
                url: url,
                sessionName: session.sessionName,
                windowId: window.id,
                hostId: nil,
                paneID: paneID
            )
            return true
        }
    }

    /// Mirror of `handleTerminalURLClick` for remote sessions. Web link clicks
    /// inside a remote terminal follow the same `browserLinkBehavior` rules as
    /// local clicks — including the per-domain overrides — so the
    /// in-app/system-browser preference is honoured uniformly across
    /// host types. URLs that require Host-local handling (including
    /// `file://` and scheme-less absolute paths) are consumed here: the
    /// file links have their own Host-backed handler; passing them to this
    /// Mac's `NSWorkspace` would target the wrong machine.
    private func handleRemoteTerminalURLClick(
        _ url: URL,
        hostId: String,
        sessionName: String,
        windowId: String,
        paneID: String,
        behaviorOverride: BrowserLinkBehavior?
    ) -> Bool {
        if RemoteTerminalURLPolicy.shouldConsumeWithoutOpening(url) {
            return true
        }

        let effective = settings.effectiveBrowserBehavior(for: url, override: behaviorOverride)

        switch effective {
        case .alwaysInApp:
            openPaneBrowser(hostID: hostId, sessionName: sessionName, paneID: paneID, url: url)
            return true
        case .alwaysInDefaultBrowser:
            return false
        case .ask:
            pendingBrowserURLPrompt = PendingBrowserURLPrompt(
                url: url,
                sessionName: sessionName,
                windowId: windowId,
                hostId: hostId,
                paneID: paneID
            )
            return true
        }
    }

    /// Opens (or re-selects) a browser tab for `url` in the given session,
    /// activating it as the visible detail content.
    private func openBrowserTab(
        url: URL,
        sessionName: String,
        windowId: String,
        originWindowId: String? = nil,
        parentTabId: UUID? = nil
    ) {
        tabStore.userDidSelectTab(hostID: nil, session: sessionName)
        let tabs: SessionFileTabsState
        if let existing = sessionFileTabsStates[sessionName] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            sessionFileTabsStates[sessionName] = tabs
        }
        let useSplit = settings.alwaysOpenLinksInSplit
        // Match on the tab's live `currentURL` (driven by the WKWebView) rather
        // than the value stored on `BrowserTab`. After the user navigates away
        // from the opening URL, `BrowserTab.url` advances with them; re-using
        // that for de-dup would let a second click on the original URL spawn a
        // duplicate tab. Re-focusing is the intended behaviour.
        let sourcePaneID = parentTabId.flatMap { tabs.sourcePaneID(for: .browser($0)) }
            ?? browserSourcePane(sessionName: sessionName, hostID: nil, windowID: originWindowId ?? windowId)
        let existingIndex = tabs.openBrowserTabs.firstIndex { tab in
            tabs.browserStates[tab.id]?.currentURL == url && tab.sourcePaneID == sourcePaneID
        }
        if let existingIndex {
            if let originWindowId {
                tabs.openBrowserTabs[existingIndex].originWindowId = originWindowId
            }
            let existingId = tabs.openBrowserTabs[existingIndex].id
            if tabs.rightSide.contains(.browser(existingId)) {
                tabs.selectedRight = .browser(existingId)
            } else {
                tabs.selectedBrowserTabId = existingId
                tabs.selectedFileTabId = nil
                fileBrowserActiveWindowIds.remove(windowId)
            }
        } else {
            let newTab = BrowserTab(url: url, originWindowId: originWindowId, sourcePaneID: sourcePaneID, parentTabId: parentTabId)
            tabs.openBrowserTabs.append(newTab)
            tabs.browserStates[newTab.id] = BrowserTabState(initialURL: url)
            tabs.browserStates[newTab.id]?.sourceAgent = parentTabId.flatMap { tabs.browserStates[$0]?.sourceAgent }
                ?? browserSourceAgent(sessionName: sessionName, hostID: nil, windowID: originWindowId ?? windowId)
            if useSplit {
                tabs.rightSide.insert(.browser(newTab.id))
                tabs.selectedRight = .browser(newTab.id)
            } else {
                tabs.selectedBrowserTabId = newTab.id
                tabs.selectedFileTabId = nil
                fileBrowserActiveWindowIds.remove(windowId)
            }
        }
    }

    /// Selects an existing browser tab and ensures the file tree/file tab views
    /// don't render alongside it.
    private func selectBrowserTab(_ tabId: UUID, sessionName: String, windowId: String?) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        tabStore.userDidSelectTab(hostID: nil, session: sessionName)
        if tabs.selectLinkedBrowserTab(tabId) {
            if let windowId {
                fileBrowserActiveWindowIds.remove(windowId)
            }
        }
    }

    /// Commits one optimistic tab reorder to tmux. Stable window ids keep the
    /// selected logical window and split state intact across index changes;
    /// target-based file/browser state is remapped before publishing refresh.
    private func reorderWindows(
        in sessionName: String,
        to newOrder: [String],
        rollbackOrder: [TabDragPayload]
    ) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard let identity = tmuxService.panes.first(where: { $0.sessionName == sessionName })?.workspaceIdentity else {
            tabs.tabOrder = rollbackOrder
            tabs.isWindowReorderPending = false
            attachError = "The session is still being discovered. Try reordering again."
            return
        }
        let fullOrder = tmuxService.windows.filter { $0.sessionName == sessionName }.map(\.stableId)
        guard let newOrder = TabDragPayload.mergingWindowOrder(newOrder, into: fullOrder) else {
            tabs.tabOrder = rollbackOrder
            tabs.isWindowReorderPending = false
            return
        }
        let selectedStableId = selectedWindow?.stableId
        Task {
            defer { tabs.isWindowReorderPending = false }
            do {
                let targetMapping = try await tmuxService.moveWindows(in: sessionName, to: newOrder, expectedWorkspacePane: identity)
                guard tmuxService.panes.contains(where: { $0.sessionName == sessionName && $0.workspaceIdentity?.isSameSession(as: identity) == true }) else { return }
                tabs.remapWindowIDs(targetMapping)
                fileBrowserActiveWindowIds = Set(fileBrowserActiveWindowIds.map { targetMapping[$0] ?? $0 })

                let newPanes = await tmuxService.refreshPanes()
                windowManager.updatePaneStates(from: newPanes)
                guard newPanes.contains(where: { $0.sessionName == sessionName && $0.workspaceIdentity?.isSameSession(as: identity) == true }) else { return }
                if
                    let selectedStableId,
                    let refreshed = tmuxService.windows.first(where: {
                        $0.sessionName == sessionName && $0.stableId == selectedStableId
                    }) {
                    selectedWindow = refreshed
                }
                await coordinator.connectedViewerManager?.pushSessionStateToAll()
            } catch {
                guard tmuxService.panes.contains(where: { $0.sessionName == sessionName && $0.workspaceIdentity?.isSameSession(as: identity) == true }) else {
                    attachError = error.localizedDescription
                    return
                }
                tabs.tabOrder = TabDragPayload.restoringWindowOrder(
                    from: rollbackOrder,
                    in: tabs.tabOrder
                )
                _ = await tmuxService.refreshPanes()
                guard tmuxService.panes.contains(where: { $0.sessionName == sessionName && $0.workspaceIdentity?.isSameSession(as: identity) == true }) else { return }
                if
                    let selectedStableId,
                    let restored = tmuxService.windows.first(where: {
                        $0.sessionName == sessionName && $0.stableId == selectedStableId
                    }) {
                    selectedWindow = restored
                }
                attachError = "Failed to reorder windows: \(error.localizedDescription)"
            }
        }
    }

    /// Reorders the open file tabs in `sessionName` to match `newOrder`.
    private func reorderFileTabs(in sessionName: String, to newOrder: [UUID]) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        let indexed = Dictionary(uniqueKeysWithValues: tabs.openFileTabs.map { ($0.id, $0) })
        let reordered: [OpenFileTab] = newOrder.compactMap { indexed[$0] }
        guard reordered.count == tabs.openFileTabs.count else { return }
        tabs.openFileTabs = reordered
    }

    /// Reorders the open browser tabs in `sessionName` to match `newOrder`.
    private func reorderBrowserTabs(in sessionName: String, to newOrder: [UUID]) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        let indexed = Dictionary(uniqueKeysWithValues: tabs.openBrowserTabs.map { ($0.id, $0) })
        let reordered: [BrowserTab] = newOrder.compactMap { indexed[$0] }
        guard reordered.count == tabs.openBrowserTabs.count else { return }
        tabs.openBrowserTabs = reordered
    }

    /// Updates the cached page title for a browser tab so the tab strip
    /// re-renders with the new label.
    private func updateBrowserTabTitle(tabId: UUID, sessionName: String, title: String?) {
        guard
            let tabs = sessionFileTabsStates[sessionName],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].displayTitle != title {
            tabs.openBrowserTabs[index].displayTitle = title
        }
    }

    /// Updates the recorded URL for a browser tab as the user navigates so
    /// re-opening the same URL later picks the existing tab.
    private func updateBrowserTabURL(tabId: UUID, sessionName: String, url: URL) {
        guard
            let tabs = sessionFileTabsStates[sessionName],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].url != url {
            tabs.openBrowserTabs[index].url = url
        }
    }

    /// Removes a browser tab and its live web view. If the closed tab was
    /// selected and originated from a terminal click, the original tmux window
    /// becomes selected again — mirroring the file-tab close flow. If the
    /// closed tab was spawned from another browser tab (`target="_blank"` /
    /// `window.open()`), the parent tab is selected first instead.
    private func closeBrowserTab(_ tabId: UUID, sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard let closedIndex = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        defer { reconcileRightPaneSelection(sessionName: sessionName) }
        let closedTab = tabs.openBrowserTabs[closedIndex]
        let payload = TabDragPayload.browser(tabId)
        let wasOnRight = tabs.rightSide.contains(payload)
        let wasSelectedLeft = tabs.selectedBrowserTabId == tabId
        defer {
            if wasSelectedLeft, selectedRemoteSession == nil, selectedWindow?.sessionName == sessionName {
                requestAutomaticTabFit()
            }
        }
        tabs.openBrowserTabs.remove(at: closedIndex)
        tabs.tabOrder.removeAll { $0 == .browser(tabId) }
        // Cancel in-flight downloads before dropping the state — a
        // deallocated `BrowserTabState` can't clean up its partial files.
        tabs.browserStates[tabId]?.cancelActiveDownloads()
        tabs.browserStates.removeValue(forKey: tabId)
        if let state = tabs.agentBrowserStates.removeValue(forKey: tabId) {
            state.service.close(state)
        }
        if let state = tabs.simulatorStates.removeValue(forKey: tabId) {
            state.service.close(state)
        }
        tabs.rightSide.remove(payload)
        if tabs.selectedRight == payload {
            tabs.selectedRight = nil
        }
        // Even if the closed tab wasn't the left selection, it may still have
        // been the user's "current view" on the right pane — prefer the
        // parent-tab return for those too so a popup closed from the right
        // pane lands back on its opener.
        if
            let parentTabId = closedTab.parentTabId,
            tabs.openBrowserTabs.contains(where: { $0.id == parentTabId }) {
            if tabs.rightSide.contains(.browser(parentTabId)) {
                tabs.selectedRight = .browser(parentTabId)
            } else {
                tabs.selectedBrowserTabId = parentTabId
                tabs.selectedFileTabId = nil
            }
            return
        }
        guard wasSelectedLeft else { return }
        tabs.selectedBrowserTabId = nil
        // Right-side tabs were opened explicitly by the user; we don't bounce
        // them back to a terminal window on close. Only the left-side close
        // path preserves the original "return to origin terminal" behaviour.
        guard !wasOnRight else { return }

        guard
            let originWindowId = closedTab.originWindowId,
            let originWindow = tmuxService.windows.first(where: { $0.id == originWindowId }),
            ownsTerminal(hostID: nil, windowID: originWindow.stableId),
            !tabs.rightSide.contains(.window(originWindow.stableId))
        else { return }
        if selectedWindow?.id != originWindow.id {
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            selectedWindow = originWindow
            Task {
                try? await tmuxService.selectWindow(originWindow.id, expectedWorkspacePane: originWindow.panes.first?.workspaceIdentity)
            }
        }
    }

    // MARK: - Linked Tab Source Actions

    private func linkedTabActions(hostID: String?, sessionName: String) -> LinkedTabSourceActions {
        let client = hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient }
        let isConnected = hostID == nil || client?.isHostConnected == true
        let canPresentSimulator = detachedWorkspace == nil

        return LinkedTabSourceActions(
            canOpenFiles: isConnected && (hostID == nil || client?.hostSupportsPaneFiles == true),
            canOpenBrowser: isConnected && (hostID == nil || client?.hostSupportsPaneBrowser == true),
            canOpenSimulator: canPresentSimulator && isConnected && (hostID == nil || client?.hostSupportsPaneSimulator == true),
            onRevealSource: { paneID in
                revealLinkedSource(paneID: paneID, hostID: hostID, sessionName: sessionName)
            },
            onOpenFiles: { paneID in
                openLinkedFiles(paneID: paneID, hostID: hostID, sessionName: sessionName)
            },
            onOpenBrowser: { paneID in
                openPaneBrowser(hostID: hostID, sessionName: sessionName, paneID: paneID)
            },
            onOpenSimulator: { paneID in
                openLinkedSimulator(paneID: paneID, hostID: hostID, sessionName: sessionName)
            }
        )
    }

    private func revealLinkedSource(paneID: String, hostID: String?, sessionName: String) {
        let pane: PaneState?
        if let hostID {
            pane = remoteSessionWindows(hostId: hostID, sessionName: sessionName)
                .lazy
                .flatMap(\.panes)
                .first { $0.paneId == paneID && $0.sessionName == sessionName }
        } else {
            let windowExists = tmuxService.windows.contains { window in
                window.sessionName == sessionName && window.panes.contains { $0.paneId == paneID }
            }
            pane = windowExists ? windowManager.paneStates[paneID] : nil
        }

        guard let pane, pane.sessionName == sessionName else {
            attachError = "This tab's source terminal is no longer available."
            return
        }
        showSourcePane(pane, hostID: hostID)
    }

    private func hasIndependentResources(hostID: String?, sessionName: String) -> Bool {
        if let hostID, let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient {
            return client.fileTabs.contains { $0.sessionName == sessionName && $0.resourceSessionID != nil }
                || client.browserTabs.contains { $0.sessionName == sessionName && $0.resourceSessionID != nil }
                || client.simulatorTabs.contains { $0.sessionName == sessionName && $0.resourceSessionID != nil }
        }
        let catalog = coordinator.independentResourceCatalog
        return catalog.files.contains { $0.sessionName == sessionName }
            || catalog.browsers.contains { $0.sessionName == sessionName }
            || catalog.simulators.contains { $0.sessionName == sessionName }
    }

    private func supportsIndependentResources(hostID: String?) -> Bool {
        hostID == nil || hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.hostSupportsIndependentResources } == true
    }

    private func requestIndependentResource(_ kind: ResourceTabKind, hostID: String?, sessionName: String, location: String? = nil) async throws -> ResourceTabResponse {
        if let hostID {
            guard
                let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient,
                let session = client.resourceSessions.first(where: { $0.name == sessionName }) else {
                throw FileBrowserError.message("Refresh the Host session list before opening a tab.")
            }
            return try await ResourceTabClient.request(.init(sessionID: session.id, operation: .open(kind: kind, location: location)), client: client)
        }
        guard let session = coordinator.resourceSessions.sessions.first(where: { $0.name == sessionName }) else {
            throw FileBrowserError.message("The session is still being discovered. Try again shortly.")
        }
        return try await coordinator.handleResourceTab(.init(sessionID: session.id, operation: .open(kind: kind, location: location)))
    }

    private func openIndependentResource(_ kind: ResourceTabKind, hostID: String?, sessionName: String, location: String? = nil, selectedFile: String? = nil, focusSearch: Bool = false) {
        let target = ManualBrowserTarget(hostID: hostID, sessionName: sessionName)
        let selection = browserOpenSelection(for: target)
        Task {
            do {
                let result = try await requestIndependentResource(kind, hostID: hostID, sessionName: sessionName, location: location)
                if let file = result.file {
                    _ = try claimHostFileTab(file, hostID: hostID)
                    guard browserOpenSelection(for: target) == selection else { return }
                    let tab = try presentHostFileTab(file, hostID: hostID, windowID: nil)
                    tab.selectedFile = selectedFile
                    if focusSearch {
                        tab.searchMode = .content
                        tab.searchFocusRequest += 1
                    }
                }
                if let id = result.browser?.id ?? result.simulator?.id {
                    var tab = BrowserTab(
                        id: id,
                        url: result.browser.flatMap { URL(string: $0.url) } ?? URL(staticString: "about:blank"),
                        displayTitle: result.browser?.title ?? result.simulator?.title
                    )
                    tab.isAgentBrowser = result.browser != nil
                    tab.isSimulator = result.simulator != nil
                    guard
                        coordinator.detachedWindows.claimOpenedBrowser(
                            tab, hostID: hostID, session: sessionName, workspaceID: detachedWorkspace?.id, resolveSession: terminalSession
                        ) else { return }
                    if let hostID, let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient {
                        syncHostBrowserTabs(hostId: hostID, sessionName: sessionName, client: client)
                        guard browserOpenSelection(for: target) == selection else { return }
                        selectRemoteBrowserTab(id, hostId: hostID, sessionName: sessionName)
                    } else {
                        coordinator.agentBrowser.register(agentBrowserWorkspace)
                        coordinator.agentSimulator.register(simulatorWorkspace)
                        guard browserOpenSelection(for: target) == selection else { return }
                        if location == nil {
                            manualBrowserTabs(for: target)?.agentBrowserStates[id]?.requestsInitialAddressFocus = true
                        }
                        selectBrowserTab(id, sessionName: sessionName, windowId: nil)
                    }
                }
            } catch is CancellationError { }
            catch { attachError = error.localizedDescription }
        }
    }

    private func openLinkedFiles(paneID: String, hostID: String?, sessionName: String) {
        let windowID: String?
        if let hostID {
            windowID = remoteSessionWindows(hostId: hostID, sessionName: sessionName)
                .first { window in
                    window.panes.contains { $0.paneId == paneID && $0.sessionName == sessionName }
                }?.id
        } else {
            windowID = tmuxService.windows
                .first { window in
                    window.sessionName == sessionName && window.panes.contains { $0.paneId == paneID }
                }?.id
        }

        guard let windowID else {
            attachError = "This tab's source terminal is no longer available."
            return
        }
        openDirectoryTab(
            sessionName: sessionName,
            windowID: windowID,
            hostID: hostID,
            paneIDs: [paneID],
            fallbackPaneID: paneID
        )
    }

    private func openLinkedSimulator(paneID: String, hostID: String?, sessionName: String) {
        if supportsIndependentResources(hostID: hostID) {
            openIndependentResource(.simulator, hostID: hostID, sessionName: sessionName)
            return
        }
        guard detachedWorkspace == nil else {
            attachError = "Open iOS Simulator from the main CtrlX window."
            return
        }
        if let hostID {
            openRemoteLinkedSimulator(paneID: paneID, hostID: hostID, sessionName: sessionName)
        } else {
            openLocalLinkedSimulator(paneID: paneID, sessionName: sessionName)
        }
    }

    private func openLocalLinkedSimulator(paneID: String, sessionName: String) {
        guard
            selectedRemoteSession == nil,
            let pane = windowManager.paneStates[paneID],
            pane.sessionName == sessionName,
            tmuxService.windows.contains(where: {
                $0.sessionName == sessionName && $0.panes.contains { $0.paneId == paneID }
            }) else {
            attachError = "This tab's source terminal is no longer available."
            return
        }
        guard let identity = pane.workspaceIdentity else {
            attachError = "The source terminal is still being recovered. Try again in a moment."
            return
        }

        Task { @MainActor in
            do {
                let tab = try await coordinator.agentSimulator.openPaneSimulator(
                    OpenPaneSimulator(sessionName: sessionName, sourcePaneID: paneID),
                    expectedWorkspacePane: identity
                )
                guard
                    selectedRemoteSession == nil,
                    currentLocalSession()?.sessionName == sessionName,
                    sessionFileTabsStates[sessionName]?.simulatorStates[tab.id] != nil else { return }
                selectBrowserTab(tab.id, sessionName: sessionName, windowId: pane.windowId)
            } catch is CancellationError {
                return
            } catch {
                guard selectedRemoteSession == nil, currentLocalSession()?.sessionName == sessionName else { return }
                attachError = "Cannot open iOS Simulator: \(error.localizedDescription)"
            }
        }
    }

    private func openRemoteLinkedSimulator(paneID: String, hostID: String, sessionName: String) {
        guard
            let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient,
            client.isHostConnected,
            client.hostSupportsPaneSimulator else {
            attachError = "Connect and update the Host Mac to open this pane's iOS Simulator."
            return
        }
        guard
            let sourceWindow = remoteSessionWindows(hostId: hostID, sessionName: sessionName)
                .first(where: { $0.panes.contains { $0.paneId == paneID } }) else {
            attachError = "This tab's source terminal is no longer available."
            return
        }
        let inputBinding = client.workspaceInputState.binding(paneID: paneID)
        let key = remoteTabsKey(hostId: hostID, sessionName: sessionName)
        let knownSimulatorIDs = SessionFileTabsState.simulatorIDsBeforeOpening(
            current: remoteSessionTabsStates[key],
            hostSimulators: client.simulatorTabs,
            sessionName: sessionName
        )

        Task { @MainActor in
            do {
                let tab = try await RemoteSimulatorSession.open(
                    sessionName: sessionName,
                    sourcePaneID: paneID,
                    client: client,
                    inputBinding: inputBinding
                )
                guard
                    selectedRemoteSession?.hostId == hostID,
                    selectedRemoteSession?.sessionName == sessionName else { return }
                let tabs = remoteSessionTabsStates[key]
                let isNewTab = !knownSimulatorIDs.contains(tab.id)
                syncHostBrowserTabs(hostId: hostID, sessionName: sessionName, client: client)
                tabs?.placeNewLinkedBrowserTab(tab.id, sourceWindowID: sourceWindow.stableId, isNew: isNewTab)
                selectRemoteBrowserTab(tab.id, hostId: hostID, sessionName: sessionName)
            } catch is CancellationError {
                return
            } catch {
                guard
                    selectedRemoteSession?.hostId == hostID,
                    selectedRemoteSession?.sessionName == sessionName else { return }
                attachError = "Cannot open iOS Simulator: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Embedded Agent Browser

    private func openPaneBrowser(hostID: String?, sessionName: String, paneID: String?, url: URL? = nil) {
        if supportsIndependentResources(hostID: hostID) {
            openIndependentResource(.browser, hostID: hostID, sessionName: sessionName, location: url?.absoluteString)
            return
        }
        guard let paneID else {
            attachError = "This window no longer has a source pane."
            return
        }
        let opensLinkedPage = url != nil
        let destination = url ?? BrowserWebURL.homepage
        let target = ManualBrowserTarget(hostID: hostID, sessionName: sessionName)
        let tabs = manualBrowserTabs(for: target)
        let existingIDs = Set(tabs?.openBrowserTabs.map(\.id) ?? [])
        let selection = browserOpenSelection(for: target)
        let isCurrent = { browserOpenSelection(for: target) == selection }
        let openInSplit = opensLinkedPage && settings.alwaysOpenLinksInSplit
        browserOpenTask?.cancel()
        browserOpenTask = Task {
            do {
                if let hostID {
                    guard
                        let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient,
                        client.isHostConnected, client.hostSupportsPaneBrowser else {
                        throw RemoteBrowserError.message("Connect and update the Host Mac to open this pane's browser.")
                    }
                    let tab = try await RemoteBrowserSession.open(sessionName: sessionName, sourcePaneID: paneID, url: destination, client: client)
                    try Task.checkCancellation()
                    guard isCurrent() else { return }
                    claimBrowser(tab.id, hostID: hostID, session: sessionName, windowID: tab.windowID)
                    syncHostBrowserTabs(hostId: hostID, sessionName: sessionName, client: client)
                    let sourceWindow = remoteSessionWindows(hostId: hostID, sessionName: sessionName)
                        .first { $0.panes.contains { $0.paneId == paneID } }
                    let sourceOnRight = sourceWindow.map {
                        manualBrowserTabs(for: target)?.rightSide.contains(.window($0.stableId)) == true
                    } == true
                    if !existingIDs.contains(tab.id), openInSplit || sourceOnRight {
                        manualBrowserTabs(for: target)?.rightSide.insert(.browser(tab.id))
                    }
                    selectRemoteBrowserTab(tab.id, hostId: hostID, sessionName: sessionName)
                } else {
                    let tab = try await coordinator.agentBrowser.openPaneBrowser(sessionName: sessionName, paneID: paneID, url: destination)
                    try Task.checkCancellation()
                    guard isCurrent() else { return }
                    claimBrowser(
                        tab.id,
                        hostID: nil,
                        session: sessionName,
                        windowID: tmuxService.windows.first { $0.panes.contains { $0.paneId == paneID } }?.stableId
                    )
                    if openInSplit, !existingIDs.contains(tab.id) {
                        manualBrowserTabs(for: target)?.rightSide.insert(.browser(tab.id))
                    }
                    selectManualBrowserTab(tab, target: target)
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, isCurrent() {
                    attachError = "Cannot open Host browser: \(error.localizedDescription)"
                }
            }
        }
    }

    private func browserOpenSelection(for target: ManualBrowserTarget) -> BrowserOpenSelection {
        BrowserOpenSelection(
            localWindowID: selectedWindow?.id,
            remoteSession: selectedRemoteSession,
            remoteWindowID: selectedRemoteWindowId,
            tabs: manualBrowserTabs(for: target),
            fileBrowserActiveWindowIDs: fileBrowserActiveWindowIds
        )
    }

    private func manualBrowserTabs(for target: ManualBrowserTarget) -> SessionFileTabsState? {
        if let hostID = target.hostID {
            return remoteSessionTabsStates[remoteTabsKey(hostId: hostID, sessionName: target.sessionName)]
        }
        return sessionFileTabsStates[target.sessionName]
    }

    private func selectManualBrowserTab(_ state: AgentBrowserTabState, target: ManualBrowserTarget) {
        guard manualBrowserTabs(for: target)?.agentBrowserStates[state.id] === state else { return }
        tabStore.userDidSelectTab(hostID: target.hostID, session: target.sessionName)
        if let hostID = target.hostID {
            guard let host = settings.pairedHosts.first(where: { $0.id == hostID }) else { return }
            if selectedRemoteSession?.hostId != hostID || selectedRemoteSession?.sessionName != target.sessionName {
                selectedRemoteWindowId = nil
            }
            selectedWindow = nil
            selectRemoteSession(.init(
                hostId: hostID, hostName: host.displayName, sessionName: target.sessionName
            ))
            selectRemoteBrowserTab(state.id, hostId: hostID, sessionName: target.sessionName)
        } else {
            let window = tmuxService.windows.first(where: { $0.sessionName == target.sessionName })
            selectedLocalSessionName = target.sessionName
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            if selectedWindow?.sessionName != target.sessionName {
                selectedWindow = window
            }
            selectBrowserTab(state.id, sessionName: target.sessionName, windowId: selectedWindow?.id ?? window?.id)
        }
        agentBrowserWorkspace.window?.makeKeyAndOrderFront(nil)
    }

    private func registerAgentBrowserWorkspace() {
        agentBrowserWorkspace.acceptsSession = { session in detachedWorkspace == nil && tmuxService.sessions.contains { $0.sessionName == session } }
        agentBrowserWorkspace.acceptsTab = { tab in
            coordinator.detachedWindows.browserOwner(
                hostID: nil,
                session: tab.sessionName,
                id: tab.id,
                windowID: tmuxService.windows.first { $0.panes.contains { $0.paneId == tab.paneID } }?.stableId
            ) == detachedWorkspace?.id
        }
        agentBrowserWorkspace.acceptsPane = { pane in
            tmuxService.windows.contains {
                $0.id == pane.windowId && ownsTerminal(hostID: nil, windowID: $0.stableId)
            }
        }
        agentBrowserWorkspace.onCreate = { state, parent in
            if let target = state.manualTarget {
                if target.hostID == nil, sessionFileTabsStates[target.sessionName] == nil {
                    sessionFileTabsStates[target.sessionName] = SessionFileTabsState()
                }
                guard let tabs = manualBrowserTabs(for: target) else { return }
                tabs.agentBrowserStates[state.id] = state
                guard !tabs.openBrowserTabs.contains(where: { $0.id == state.id }) else { return }
                var tab = BrowserTab(
                    id: state.id,
                    url: URL(staticString: "about:blank"),
                    originWindowId: state.windowID,
                    parentTabId: parent
                )
                // All native Chromium pages are transient; never restore them as
                // WebKit or implicitly give a future agent control of a page.
                tab.isAgentBrowser = true
                tabs.openBrowserTabs.append(tab)
                state.requestsInitialAddressFocus = parent == nil
                let sourceWindow = tmuxService.windows.first { $0.panes.contains { $0.paneId == state.paneID } }
                if
                    parent.map({ tabs.rightSide.contains(.browser($0)) }) == true
                    || sourceWindow.map({ tabs.rightSide.contains(.window($0.stableId)) }) == true {
                    tabs.rightSide.insert(.browser(state.id))
                }
                return
            }
            guard let window = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == state.paneID } }) else {
                state.service.close(state)
                return
            }
            let tabs = sessionFileTabsStates[window.sessionName] ?? SessionFileTabsState()
            sessionFileTabsStates[window.sessionName] = tabs
            guard !tabs.openBrowserTabs.contains(where: { $0.id == state.id }) else { return }
            var tab = BrowserTab(
                id: state.id,
                url: URL(staticString: "about:blank"),
                originWindowId: window.id,
                parentTabId: parent
            )
            tab.isAgentBrowser = true
            tabs.openBrowserTabs.append(tab)
            tabs.agentBrowserStates[state.id] = state
            // Follow the source terminal's side, not the currently focused tab.
            if tabs.rightSide.contains(.window(window.id)) || parent.map({ tabs.rightSide.contains(.browser($0)) }) == true {
                tabs.rightSide.insert(.browser(state.id))
            }
        }
        agentBrowserWorkspace.onChange = { state in
            if let target = state.manualTarget {
                guard
                    let tabs = manualBrowserTabs(for: target),
                    let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == state.id }) else { return }
                if tabs.openBrowserTabs[index].displayTitle != state.title {
                    tabs.openBrowserTabs[index].displayTitle = state.title
                }
                if let url = URL(string: state.url), tabs.openBrowserTabs[index].url != url {
                    tabs.openBrowserTabs[index].url = url
                }
                if tabs.openBrowserTabs[index].originWindowId != state.windowID {
                    tabs.openBrowserTabs[index].originWindowId = state.windowID
                }
                return
            }
            guard let (session, _) = sessionFileTabsStates.first(where: { $0.value.agentBrowserStates[state.id] != nil }) else { return }
            updateBrowserTabTitle(tabId: state.id, sessionName: session, title: state.title)
            if let url = URL(string: state.url) {
                updateBrowserTabURL(tabId: state.id, sessionName: session, url: url)
            }
        }
        agentBrowserWorkspace.onSelect = { state in
            if let target = state.manualTarget {
                selectManualBrowserTab(state, target: target)
                return
            }
            guard
                let (session, tabs) = sessionFileTabsStates.first(where: { $0.value.agentBrowserStates[state.id] != nil }),
                let window = tmuxService.windows.first(where: { $0.sessionName == session && $0.panes.contains { $0.paneId == state.paneID } })
                ?? tmuxService.windows.first(where: { $0.sessionName == session }) else { return }
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            // A browser selection does not move terminal windows between sides.
            // When coming from another session, select a LEFT-side terminal as
            // the session anchor even if this agent is in the right-side one.
            if selectedWindow?.sessionName != session {
                selectedWindow = tmuxService.windows.first {
                    $0.sessionName == session && !tabs.rightSide.contains(.window($0.id))
                } ?? window
            }
            selectBrowserTab(state.id, sessionName: session, windowId: window.id)
            agentBrowserWorkspace.window?.makeKeyAndOrderFront(nil)
        }
        agentBrowserWorkspace.onClose = { state in
            if let target = state.manualTarget {
                if let hostID = target.hostID {
                    closeRemoteBrowserTab(state.id, hostId: hostID, sessionName: target.sessionName)
                } else {
                    closeBrowserTab(state.id, sessionName: target.sessionName)
                }
                return
            }
            guard let (session, _) = sessionFileTabsStates.first(where: { $0.value.agentBrowserStates[state.id] != nil }) else { return }
            closeBrowserTab(state.id, sessionName: session)
        }
        agentBrowserWorkspace.onDetach = agentBrowserWorkspace.onClose
        coordinator.agentBrowser.register(agentBrowserWorkspace)
    }

    private func registerSimulatorWorkspace() {
        simulatorWorkspace.acceptsSession = { session in detachedWorkspace == nil && tmuxService.sessions.contains { $0.sessionName == session } }
        simulatorWorkspace.acceptsPane = { pane in
            tmuxService.windows.contains { $0.stableId == pane.stableWindowId && ownsTerminal(hostID: nil, windowID: $0.stableId) }
        }
        simulatorWorkspace.acceptsTab = { state in
            coordinator.detachedWindows.browserOwner(
                hostID: nil, session: state.sessionName, id: state.id, windowID: state.sourcePane?.stableWindowId
            ) == detachedWorkspace?.id
        }
        simulatorWorkspace.onCreate = { state in
            let tabs = sessionFileTabsStates[state.sessionName] ?? SessionFileTabsState()
            sessionFileTabsStates[state.sessionName] = tabs
            tabs.attachSimulator(state)
        }
        simulatorWorkspace.onSelect = { state, split in
            guard let (session, tabs) = sessionFileTabsStates.first(where: { $0.value.simulatorStates[state.id] != nil }) else { return }
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            if
                selectedWindow?.sessionName != session,
                let window = tmuxService.windows.first(where: { $0.sessionName == session && $0.panes.contains { $0.paneId == state.paneID } }) {
                selectedWindow = tmuxService.windows.first { $0.sessionName == session && !tabs.rightSide.contains(.window($0.id)) } ?? window
            }
            if split, !tabs.rightSide.contains(.browser(state.id)) {
                toggleSplit(.browser(state.id), sessionName: session, windowId: state.sourcePane?.windowId)
            }
            selectBrowserTab(state.id, sessionName: session, windowId: state.sourcePane?.windowId)
            simulatorWorkspace.window?.makeKeyAndOrderFront(nil)
        }
        simulatorWorkspace.onClose = { state in
            guard let (session, _) = sessionFileTabsStates.first(where: { $0.value.simulatorStates[state.id] != nil }) else { return }
            closeBrowserTab(state.id, sessionName: session)
        }
        simulatorWorkspace.onDetach = { state in
            guard let (session, tabs) = sessionFileTabsStates.first(where: { $0.value.simulatorStates[state.id] != nil }) else { return }
            tabs.simulatorStates.removeValue(forKey: state.id)
            closeBrowserTab(state.id, sessionName: session)
        }
        coordinator.agentSimulator.register(simulatorWorkspace)
    }

    // MARK: - Remote Browser Tab Helpers

    /// Looks up the windows for a remote `(hostId, sessionName)` via the
    /// session store, sorted by `windowIndex`. Used as a window-list parameter
    /// for the right-pane reconciler so background sessions get reconciled
    /// against their own window list instead of the currently-selected one.
    private func remoteSessionWindows(hostId: String, sessionName: String) -> [TmuxWindow] {
        guard
            let sessionStore = coordinator.remoteSessionStore,
            coordinator.viewerWorkspaceRecovery.allowsRendering(hostID: hostId, session: sessionName, store: tabStore) else { return [] }
        return sessionStore.windows(for: hostId)
            .filter { $0.sessionName == sessionName }
            .sorted { $0.windowIndex < $1.windowIndex }
    }

    private func selectRemoteSession(_ selection: RemoteSessionSelection) {
        coordinator.viewerWorkspaceRecovery.selectSession(hostID: selection.hostId, session: selection.sessionName, store: tabStore)
        selectedRemoteSession = selection
    }

    /// Composite key into `remoteSessionTabsStates` for `(hostId, sessionName)`.
    /// Two paired hosts can have a session with the same name, so the hostId
    /// has to participate in the key — keying on `sessionName` alone would
    /// collide their tab strips. A typed struct (rather than a `String` like
    /// `"\(hostId):\(sessionName)"`) keeps the two components separate so a
    /// session name that happens to contain `:` can't collide with another
    /// host/session pair.
    private func remoteTabsKey(hostId: String, sessionName: String) -> RemoteSessionTabsKey {
        RemoteSessionTabsKey(hostId: hostId, sessionName: sessionName)
    }

    /// Opens (or re-selects) a browser tab inside a remote session's tab
    /// strip. Mirrors `openBrowserTab` for local sessions but reads/writes
    /// `remoteSessionTabsStates`.
    private func openRemoteBrowserTab(
        url: URL,
        hostId: String,
        sessionName: String,
        originWindowId: String? = nil,
        parentTabId: UUID? = nil
    ) {
        tabStore.userDidSelectTab(hostID: hostId, session: sessionName)
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        let tabs: SessionFileTabsState
        if let existing = remoteSessionTabsStates[key] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            remoteSessionTabsStates[key] = tabs
        }
        // De-dup on the live `currentURL` from the WKWebView, not the value
        // stored on `BrowserTab`. After the user navigates the tab away from
        // its opening URL, `BrowserTab.url` advances with them; matching on
        // it would let a re-click of the original URL spawn a duplicate tab.
        let sourcePaneID = parentTabId.flatMap { tabs.sourcePaneID(for: .browser($0)) }
            ?? browserSourcePane(sessionName: sessionName, hostID: hostId, windowID: originWindowId)
        let existingIndex = tabs.openBrowserTabs.firstIndex { tab in
            tabs.browserStates[tab.id]?.currentURL == url && tab.sourcePaneID == sourcePaneID
        }
        if let existingIndex {
            if let originWindowId {
                tabs.openBrowserTabs[existingIndex].originWindowId = originWindowId
            }
            tabs.selectedBrowserTabId = tabs.openBrowserTabs[existingIndex].id
        } else {
            let newTab = BrowserTab(url: url, originWindowId: originWindowId, sourcePaneID: sourcePaneID, parentTabId: parentTabId)
            tabs.openBrowserTabs.append(newTab)
            tabs.browserStates[newTab.id] = BrowserTabState(initialURL: url)
            tabs.browserStates[newTab.id]?.sourceAgent = parentTabId.flatMap { tabs.browserStates[$0]?.sourceAgent }
                ?? browserSourceAgent(sessionName: sessionName, hostID: hostId, windowID: originWindowId)
            tabs.selectedBrowserTabId = newTab.id
        }
        tabs.selectedFileTabId = nil
    }

    /// Selects an existing browser tab in a remote session's tab strip.
    /// Mirrors `selectBrowserTab` for local sessions: when the tab is pinned
    /// to the right pane, route the click to `selectedRight` so the left
    /// pane keeps its current content instead of also rendering the browser.
    private func selectRemoteBrowserTab(
        _ tabId: UUID,
        hostId: String,
        sessionName: String
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        tabStore.userDidSelectTab(hostID: hostId, session: sessionName)
        _ = tabs.selectLinkedBrowserTab(tabId)
    }

    /// Caches a remote browser tab's latest page title so the tab strip can
    /// re-render with the new label.
    private func updateRemoteBrowserTabTitle(
        tabId: UUID,
        hostId: String,
        sessionName: String,
        title: String?
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard
            let tabs = remoteSessionTabsStates[key],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].displayTitle != title {
            tabs.openBrowserTabs[index].displayTitle = title
        }
    }

    /// Records a remote browser tab's current URL as the user navigates so
    /// re-clicking the original URL re-focuses the existing tab.
    private func updateRemoteBrowserTabURL(
        tabId: UUID,
        hostId: String,
        sessionName: String,
        url: URL
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard
            let tabs = remoteSessionTabsStates[key],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].url != url {
            tabs.openBrowserTabs[index].url = url
        }
    }

    /// Removes a remote browser tab and its live web view. When the closed
    /// tab was selected and originated from a remote terminal click, the
    /// originating tmux window becomes selected again — same return-to-origin
    /// behaviour as `closeBrowserTab` for local tabs. If the closed tab was
    /// spawned from another browser tab (`target="_blank"` / `window.open()`),
    /// the parent tab is selected first instead.
    private func closeRemoteBrowserTab(
        _ tabId: UUID,
        hostId: String,
        sessionName: String
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        guard tabs.remoteSimulatorTabs[tabId] == nil else { return }
        if
            let tab = tabs.remoteBrowserTabs[tabId],
            let client = coordinator.viewerConnectionManager?.connection(for: hostId)?.relayClient {
            if selectedRemoteSession?.hostId == hostId, selectedRemoteSession?.sessionName == sessionName {
                tabs.beginClosingHostBrowserTab(tabId)
            }
            Task {
                do { try await RemoteBrowserSession.close(tab: tab, client: client) }
                catch {
                    tabs.cancelClosingHostBrowserTab(tabId)
                    attachError = error.localizedDescription
                }
            }
            return
        }
        guard let closedIndex = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        defer {
            reconcileRemoteRightPaneSelection(
                hostId: hostId,
                sessionName: sessionName,
                sessionWindows: remoteSessionWindows(hostId: hostId, sessionName: sessionName)
            )
        }
        let closedTab = tabs.openBrowserTabs[closedIndex]
        let payload = TabDragPayload.browser(tabId)
        let wasOnRight = tabs.rightSide.contains(payload)
        let wasSelectedLeft = tabs.selectedBrowserTabId == tabId
        defer {
            if
                wasSelectedLeft, selectedRemoteSession?.hostId == hostId,
                selectedRemoteSession?.sessionName == sessionName {
                requestAutomaticTabFit()
            }
        }
        tabs.openBrowserTabs.remove(at: closedIndex)
        tabs.tabOrder.removeAll { $0 == .browser(tabId) }
        // Cancel in-flight downloads before dropping the state — a
        // deallocated `BrowserTabState` can't clean up its partial files.
        tabs.browserStates[tabId]?.cancelActiveDownloads()
        tabs.browserStates.removeValue(forKey: tabId)
        if let state = tabs.agentBrowserStates.removeValue(forKey: tabId) {
            state.service.close(state)
        }
        tabs.rightSide.remove(payload)
        if tabs.selectedRight == payload {
            tabs.selectedRight = nil
        }
        // Prefer parent-tab return whether the popup was on the left or the
        // right pane, so closing it always lands back on its opener.
        if
            let parentTabId = closedTab.parentTabId,
            tabs.openBrowserTabs.contains(where: { $0.id == parentTabId }) {
            if tabs.rightSide.contains(.browser(parentTabId)) {
                tabs.selectedRight = .browser(parentTabId)
            } else {
                tabs.selectedBrowserTabId = parentTabId
                tabs.selectedFileTabId = nil
            }
            return
        }
        guard wasSelectedLeft else { return }
        tabs.selectedBrowserTabId = nil
        // Right-side tabs were opened explicitly by the user; we don't bounce
        // them back to a terminal window on close. Only the left-side close
        // path preserves the original "return to origin terminal" behaviour.
        guard !wasOnRight else { return }
        guard
            let originWindowId = closedTab.originWindowId,
            let sessionStore = coordinator.remoteSessionStore
        else { return }
        let remoteWindows = sessionStore.windows(for: hostId)
            .filter { $0.sessionName == sessionName }
        if remoteWindows.contains(where: { $0.id == originWindowId }) {
            selectedRemoteWindowId = originWindowId
        } else {
            // Origin window no longer exists (e.g., closed on the host).
            // Drop the stale selection so the UI lands on a clean
            // "no window selected" state instead of a phantom id.
            selectedRemoteWindowId = nil
        }
    }

    private var remoteBrowserCatalogs: [String: [RemoteBrowserTab]] {
        guard let manager = coordinator.viewerConnectionManager else { return [:] }
        return Dictionary(uniqueKeysWithValues: manager.managedHostIDs.compactMap { hostID in
            manager.connection(for: hostID).map { (hostID, $0.relayClient.browserTabs) }
        })
    }

    private func syncRemoteBrowserCatalogs() {
        var keys = Set(remoteSessionTabsStates.keys)
        if let remote = selectedRemoteSession {
            keys.insert(remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName))
        }
        for key in keys {
            guard let client = coordinator.viewerConnectionManager?.connection(for: key.hostId)?.relayClient else { continue }
            syncHostBrowserTabs(hostId: key.hostId, sessionName: key.sessionName, client: client)
        }
    }

    private var remoteSimulatorCatalogs: [String: [RemoteSimulatorTab]] {
        guard let manager = coordinator.viewerConnectionManager else { return [:] }
        return Dictionary(uniqueKeysWithValues: manager.managedHostIDs.compactMap { hostID in
            manager.connection(for: hostID).map { (hostID, $0.relayClient.simulatorTabs) }
        })
    }

    private func syncHostBrowserTabs(hostId: String, sessionName: String, client: ViewerRelayClient) {
        guard
            let store = coordinator.remoteSessionStore,
            RemoteSessionStructure(panes: store.paneStates).canSyncBrowserCatalog(client.browserTabs, simulators: client.simulatorTabs, hostID: hostId, sessionName: sessionName) else { return }
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        let tabs = remoteSessionTabsStates[key] ?? SessionFileTabsState()
        remoteSessionTabsStates[key] = tabs
        let values = client.browserTabs.filter {
            $0.sessionName == sessionName && coordinator.detachedWindows.browserOwner(hostID: hostId, session: sessionName, id: $0.id, windowID: $0.windowID) == detachedWorkspace?.id
        }
        let windows = remoteSessionWindows(hostId: hostId, sessionName: sessionName)
            .filter { ownsTerminal(hostID: hostId, windowID: $0.stableId) }
        let update = tabs.syncHostBrowserTabs(values, sessionWindowIDs: windows.map(\.stableId))
        let simulatorsCollapsed = tabs.syncHostSimulatorTabs(
            coordinator.detachedWindows.simulatorTabs(client.simulatorTabs, hostID: hostId, session: sessionName, workspaceID: detachedWorkspace?.id),
            sessionWindowIDs: windows.map(\.stableId)
        )
        if update.restoreLeftWindow || simulatorsCollapsed {
            restoreRemoteLeftWindowSelection(hostId: hostId, sessionName: sessionName, sessionWindows: windows)
        }
        guard
            selectedRemoteSession?.hostId == hostId,
            selectedRemoteSession?.sessionName == sessionName, client.isHostConnected else { return }
        switch update.automaticFit {
        case .left:
            requestAutomaticTabFit()
        case let .right(windowID):
            requestAutomaticTabFit(windowID: windowID)
        case nil:
            break
        }
    }

    /// Toggles which side of the split a remote tab strip entry lives on.
    /// Mirrors `toggleSplit` for local sessions but operates on remote state.
    /// Only `.window` and `.browser` payloads are valid for remote sessions;
    /// `.fileExplorer` and `.file` cases are silently ignored.
    private func toggleRemoteSplit(_ payload: TabDragPayload, hostId: String, sessionName: String) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        let tabs: SessionFileTabsState
        if let existing = remoteSessionTabsStates[key] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            remoteSessionTabsStates[key] = tabs
        }
        // Reject payloads whose underlying data has gone away between the
        // last reconcile and the click — otherwise a stale `.window` would
        // get inserted into `tabs.rightSide` and the right pane would show
        // "No Tab Selected" until the next prune fires.
        switch payload {
        case let .browser(id) where !tabs.openBrowserTabs.contains(where: { $0.id == id }): return
        case let .window(id) where !ownsTerminal(hostID: hostId, windowID: id): return
        case let .window(id) where !selectedRemoteSessionWindows.contains(where: { $0.stableId == id }): return
        case let .file(id) where !tabs.openFileTabs.contains(where: { $0.id == id }): return
        case .fileExplorer,
             .git: return
        default: break
        }

        if tabs.rightSide.contains(payload) {
            // Moving back to the left side — receiving side becomes this entry.
            tabs.rightSide.remove(payload)
            if tabs.selectedRight == payload {
                tabs.selectedRight = nil
            }
            switch payload {
            case let .window(id):
                if let window = selectedRemoteSessionWindows.first(where: { $0.stableId == id }) {
                    selectedRemoteWindowId = window.id
                }
                tabs.selectedFileTabId = nil
                tabs.selectedBrowserTabId = nil
            case let .browser(id):
                tabs.selectedBrowserTabId = id
                tabs.selectedFileTabId = nil
            case let .file(id):
                tabs.selectedFileTabId = id
                tabs.selectedBrowserTabId = nil
            case .fileExplorer,
                 .git:
                break
            }
        } else {
            // Moving to the right side — becomes the right pane's selection.
            tabs.rightSide.insert(payload)
            tabs.selectedRight = payload
            switch payload {
            case let .window(id):
                // If the moved window was the left-pane selection, pick a
                // different left-side window so both panes show distinct
                // content.
                if selectedRemoteWindow?.stableId == id {
                    let leftSessionWindows = selectedRemoteSessionWindows
                        .filter { ownsTerminal(hostID: hostId, windowID: $0.stableId) && !tabs.rightSide.contains(.window($0.stableId)) }
                    selectedRemoteWindowId = (leftSessionWindows.first(where: \.isWindowActive) ?? leftSessionWindows.first)?.id
                }
            case let .browser(id):
                if tabs.selectedBrowserTabId == id {
                    tabs.selectedBrowserTabId = nil
                }
            case let .file(id):
                if tabs.selectedFileTabId == id {
                    tabs.selectedFileTabId = nil
                }
            case .fileExplorer,
                 .git:
                break
            }
        }
        reconcileRemoteRightPaneSelection(
            hostId: hostId,
            sessionName: sessionName,
            sessionWindows: remoteSessionWindows(hostId: hostId, sessionName: sessionName)
        )
    }

    /// Forget seed/persist bookkeeping — and the live tab state — for remote
    /// sessions killed on a host that is *currently reporting* (connected and
    /// syncing). The analogue of the local
    /// `seededSessions.formIntersection(currentSessionNames)` cleanup: without
    /// it a stale `(hostId, sessionName)` key makes `seedRemoteLayoutIfNeeded`
    /// short-circuit, so a recreated same-named session never re-seeds from the
    /// persisted folder layout, and the dead session's `BrowserTabState`
    /// (`WKWebView`s) leaks (issue #608).
    ///
    /// Gated on `hasSessions(for:)`: a host clears its pane state on *disconnect*
    /// too (`AppCoordinator.onHostDisconnected` → `clearSessions`), which is
    /// indistinguishable here from a kill — so a host that currently reports
    /// nothing is treated as disconnected and its bookkeeping is retained for
    /// reconnect, matching `remoteSessionTabsStates` (only fully cleared on
    /// unpair). Residual gap: a host whose *only* session is recycled under the
    /// same name on a *different* folder won't re-seed until reconnect;
    /// same-folder recycles are unaffected (the retained state already equals
    /// that folder's record).
    private func pruneStaleRemoteSessionBookkeeping() {
        guard let sessionStore = coordinator.remoteSessionStore else { return }

        // Live keys for hosts that currently report sessions. Hosts reporting
        // nothing (disconnected, or briefly between a kill and a recreate) are
        // absent, so none of their keys are treated as stale below.
        var liveKeys: Set<RemoteSessionTabsKey> = []
        var reportingHosts: Set<String> = []
        for host in settings.pairedHosts where sessionStore.hasSessions(for: host.id) {
            reportingHosts.insert(host.id)
            for session in sessionStore.sessions(for: host.id) {
                liveKeys.insert(RemoteSessionTabsKey(hostId: host.id, sessionName: session.sessionName))
            }
        }
        guard !reportingHosts.isEmpty else { return }

        func isStale(_ key: RemoteSessionTabsKey) -> Bool {
            reportingHosts.contains(key.hostId) && !liveKeys.contains(key)
        }

        for key in seededRemoteSessions where isStale(key) {
            seededRemoteSessions.remove(key)
        }
        for key in seedingRemoteSessions where isStale(key) {
            seedingRemoteSessions.remove(key)
        }
        for key in lastPersistedRemoteLayouts.keys where isStale(key) {
            lastPersistedRemoteLayouts.removeValue(forKey: key)
        }
        // Save-chain task isn't cancelled — let a final write for the just-killed
        // session land before forgetting it (matches the unpair path).
        for key in pendingRemoteLayoutSaves.keys where isStale(key) {
            pendingRemoteLayoutSaves.removeValue(forKey: key)
        }
        // Release the dead session's live tab state (browser `WKWebView`s) so a
        // recreate starts clean — the analogue of the local
        // `sessionFileTabsStates` removal.
        for key in remoteSessionTabsStates.keys where isStale(key) {
            remoteSessionTabsStates[key]?.cancelActiveBrowserDownloads()
            remoteSessionTabsStates.removeValue(forKey: key)
        }
    }

    /// Prune any right-side window entries that point at remote terminals
    /// the host has just removed (a window was closed remotely). Without
    /// this, `isSplit` stays true and the right pane shows "No Tab Selected"
    /// forever even though the referenced window is gone.
    private func pruneStaleRemoteRightSideEntries() {
        guard coordinator.remoteSessionStore != nil else { return }
        // GC bookkeeping + tab state for sessions killed on a still-connected
        // host before reconciling the survivors' right-side entries (issue #608).
        pruneStaleRemoteSessionBookkeeping()
        for (key, tabs) in remoteSessionTabsStates {
            let liveWindows = remoteSessionWindows(hostId: key.hostId, sessionName: key.sessionName)
            let liveIds = Set(liveWindows.map(\.stableId))
            let stale = tabs.rightSide.filter {
                if case let .window(id) = $0 {
                    !liveIds.contains(id)
                } else {
                    false
                }
            }
            guard !stale.isEmpty else { continue }
            tabs.rightSide.subtract(stale)
            if let sel = tabs.selectedRight, stale.contains(sel) {
                tabs.selectedRight = nil
            }
            reconcileRemoteRightPaneSelection(
                hostId: key.hostId,
                sessionName: key.sessionName,
                sessionWindows: liveWindows
            )
        }
    }

    /// Keeps the remote right pane's selection coherent with the tabs still
    /// on that side. Mirrors `reconcileRightPaneSelection` for local sessions,
    /// including directory tabs. Auto-collapses the split when every
    /// remaining tab lives on the right pane and the left
    /// section is effectively empty.
    ///
    /// `sessionWindows` is taken as a parameter (rather than read from the
    /// `selectedRemoteSessionWindows` computed property) because the prune
    /// path calls this for every cached session — including background ones —
    /// and the computed property always returns the currently-selected
    /// session's windows.
    private func reconcileRemoteRightPaneSelection(
        hostId: String,
        sessionName: String,
        sessionWindows: [TmuxWindow]
    ) {
        guard coordinator.remoteSessionStore?.hasReceivedState(for: hostId) == true else { return }
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        let owned = sessionWindows.filter { ownsTerminal(hostID: hostId, windowID: $0.stableId) }
        let ownedIDs = Set(owned.map(\.stableId))
        tabs.rightSide = tabs.rightSide.filter {
            if case let .window(id) = $0 {
                ownedIDs.contains(id)
            } else {
                true
            }
        }
        tabs.reconcileRemoteRightPaneSelection(sessionWindowIDs: owned.map(\.stableId))
        restoreRemoteLeftWindowSelection(hostId: hostId, sessionName: sessionName, sessionWindows: owned)
    }

    private func restoreRemoteLeftWindowSelection(hostId: String, sessionName: String, sessionWindows: [TmuxWindow]) {
        // A background session's auto-collapse must not change the visible session's focus.
        if
            let remote = selectedRemoteSession,
            remote.hostId == hostId, remote.sessionName == sessionName {
            selectedRemoteWindowId = selectedRemoteWindow?.id
            remoteSessionTabsStates[remoteTabsKey(hostId: hostId, sessionName: sessionName)]?
                .repairLeftContent(hasTerminal: selectedRemoteWindow != nil)
        }
    }

    /// Pushes the new window order to the remote host via `MoveTmuxWindows`.
    /// The host swaps stable window identities into the requested order and
    /// pushes a refreshed session state on success.
    private func reorderRemoteWindows(
        hostId: String,
        sessionName: String,
        to newOrder: [String],
        rollbackOrder: [TabDragPayload],
        connection: ViewerConnection
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        let currentWindows = remoteSessionWindows(hostId: hostId, sessionName: sessionName)
        guard let newOrder = TabDragPayload.mergingWindowOrder(newOrder, into: currentWindows.map(\.stableId)) else {
            tabs.tabOrder = rollbackOrder
            tabs.isWindowReorderPending = false
            return
        }
        guard
            newOrder.count == currentWindows.count,
            Set(newOrder).count == newOrder.count,
            Set(newOrder) == Set(currentWindows.map(\.stableId))
        else {
            tabs.tabOrder = rollbackOrder
            tabs.isWindowReorderPending = false
            attachError = "Failed to reorder remote windows: the host window set changed during the drag."
            return
        }
        let selectedStableId = selectedRemoteWindow?.stableId
        let oldSelectedId = selectedRemoteWindowId
        let targetIndices = currentWindows.map(\.windowIndex).sorted()
        let newIndexByStableId = Dictionary(uniqueKeysWithValues: zip(newOrder, targetIndices))
        let targetMapping: [String: String] = Dictionary(uniqueKeysWithValues: currentWindows.compactMap { window -> (String, String)? in
            guard let newIndex = newIndexByStableId[window.stableId] else { return nil }
            return (window.id, "\(sessionName):\(newIndex)")
        })
        let binding = connection.relayClient.workspaceInputState.sessionBinding(name: sessionName)

        Task {
            defer { tabs.isWindowReorderPending = false }
            let result = await connection.relayClient.sendCommand(
                MoveTmuxWindows(sessionName: sessionName, windowIds: newOrder),
                paneId: "",
                inputBinding: binding
            )
            do {
                _ = try binding.expectedPane(current: connection.relayClient.workspaceInputState.sessionBinding(name: sessionName))
            } catch {
                attachError = error.localizedDescription
                return
            }
            if case .success = result {
                tabs.remapWindowIDs(targetMapping)
                guard let selectedStableId else { return }
                // The refreshed session state arrives asynchronously via the
                // WebSocket push, so `selectedRemoteSessionWindows` may still
                // be the pre-move list right after `sendCommand` returns.
                for _ in 0..<20 {
                    guard selectedRemoteSession?.hostId == hostId, selectedRemoteSession?.sessionName == sessionName else { return }
                    do {
                        _ = try binding.expectedPane(current: connection.relayClient.workspaceInputState.sessionBinding(name: sessionName))
                    } catch { return }
                    if
                        let refreshed = selectedRemoteSessionWindows.first(where: {
                            $0.sessionName == sessionName && $0.stableId == selectedStableId
                        }) {
                        selectedRemoteWindowId = refreshed.id
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                }
                attachError = "Window reordered, but the refreshed host state did not arrive in time."
            } else {
                tabs.tabOrder = TabDragPayload.restoringWindowOrder(
                    from: rollbackOrder,
                    in: tabs.tabOrder
                )
                selectedRemoteWindowId = oldSelectedId
                if case let .failure(error) = result {
                    attachError = "Failed to reorder remote windows: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Reorders the open browser tabs for a remote session.
    private func reorderRemoteBrowserTabs(
        hostId: String,
        sessionName: String,
        to newOrder: [UUID]
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        let indexed = Dictionary(uniqueKeysWithValues: tabs.openBrowserTabs.map { ($0.id, $0) })
        let reordered: [BrowserTab] = newOrder.compactMap { indexed[$0] }
        guard reordered.count == tabs.openBrowserTabs.count else { return }
        tabs.openBrowserTabs = reordered
    }

    /// Resolves the user's choice from the link confirmation dialog: opens the
    /// URL via the chosen path and — depending on `rememberScope` — either
    /// updates the global `settings.browserLinkBehavior` or adds a per-domain
    /// rule via `settings.setBrowserBehavior(_:for:)` so subsequent clicks
    /// skip the prompt for matching URLs.
    private func resolveBrowserURLPrompt(
        _ prompt: PendingBrowserURLPrompt,
        choice: BrowserPromptChoice,
        rememberScope: BrowserPromptRememberScope
    ) {
        let resolved: BrowserLinkBehavior
        switch choice {
        case .inApp:
            openPaneBrowser(hostID: prompt.hostId, sessionName: prompt.sessionName, paneID: prompt.paneID, url: prompt.url)
            resolved = .alwaysInApp
        case .defaultBrowser:
            @Dependency(URLOpener.self) var urlOpener
            urlOpener.openInDefaultBrowser(prompt.url)
            resolved = .alwaysInDefaultBrowser
        }

        switch rememberScope {
        case .none:
            break
        case .global:
            settings.browserLinkBehavior = resolved
        case let .domain(host):
            settings.setBrowserBehavior(resolved, for: host)
        }
    }

    /// Removes a file tab. If the closed tab was selected, clears the selection.
    ///
    /// When the tab carries an `originWindowId` (set when opened from a
    /// terminal click), the originating terminal is reselected and its file
    /// browser is hidden so the user deterministically lands back on the
    /// terminal rather than the file tree. If the origin window is gone we
    /// still drop the file-browser membership for that id so the content area
    /// doesn't fall back to the tree — the user simply stays on whichever
    /// window is currently selected (or the empty state if none).
    ///
    /// Tabs without an origin (opened from the file browser tree, markdown
    /// suggestions, etc.) keep the legacy fallback so the file tree remains
    /// visible underneath.
    ///
    /// Host catalog removal and private closes share `removeFileTab`; only an
    /// explicit close runs the origin/Fit completion in the requesting scene.
    private func closeOpenFileTab(_ tabId: UUID, sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        if tabs.directoryTabs[tabId]?.hostTab != nil {
            guard
                tabs.beginClosingHostFileTab(tabId, onClose: { result in
                    finishLocalFileTabClose(result, sessionName: sessionName)
                }) else { return }
            coordinator.hostFileTabs.close(tabId)
            syncHostFiles(hostID: nil, descriptors: coordinator.hostFileTabs.tabs)
            return
        }
        if let result = tabs.removeFileTab(tabId) {
            finishLocalFileTabClose(result, sessionName: sessionName)
        }
    }

    private func finishLocalFileTabClose(_ result: SessionFileTabsState.FileTabCloseResult, sessionName: String) {
        defer { reconcileRightPaneSelection(sessionName: sessionName) }
        guard
            result.wasSelectedLeft, selectedRemoteSession == nil, currentLocalSession()?.sessionName == sessionName,
            let tabs = sessionFileTabsStates[sessionName] else { return }
        switch result.origin {
        case nil: break
        case let .terminalWindow(windowId):
            restoreFileTabOrigin(windowId: windowId, showGit: false)
        case let .gitTab(windowId):
            restoreFileTabOrigin(windowId: windowId, showGit: true)
        }
        if tabs.selectedFileTabId == nil, tabs.selectedBrowserTabId == nil, !tabs.isGitSelected {
            requestAutomaticTabFit()
        }
    }

    /// On closing the left-pane file tab, returns the left pane to where the tab
    /// was opened from: the origin window's terminal, or — when `showGit` — its
    /// Git tab. Opening a file tab forces file-browser mode, so this undoes that
    /// and reselects the origin window if focus drifted.
    @MainActor
    private func restoreFileTabOrigin(windowId: String, showGit: Bool) {
        // Drop membership unconditionally so the content area falls off the
        // tree even when the origin window is gone (closed/renamed). The
        // entry is otherwise only cleaned up by the panes-change observer,
        // which would briefly keep the tree visible.
        fileBrowserActiveWindowIds.remove(windowId)

        guard
            let originWindow = tmuxService.windows.first(where: { $0.id == windowId }),
            ownsTerminal(hostID: nil, windowID: originWindow.stableId),
            sessionFileTabsStates[originWindow.sessionName]?.rightSide.contains(.window(originWindow.stableId)) != true else {
            return
        }
        // Only restore the Git tab for a live window; a gone window falls back
        // to the terminal/default like the terminal-origin case.
        if showGit, sessionFileTabsStates[originWindow.sessionName]?.isGitOpen == true {
            sessionFileTabsStates[originWindow.sessionName]?.selectLeftGit()
        }
        if selectedWindow?.id != originWindow.id {
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            selectedWindow = originWindow
            Task {
                try? await tmuxService.selectWindow(originWindow.id, expectedWorkspacePane: originWindow.panes.first?.workspaceIdentity)
            }
        }
    }

    // MARK: - Remote Close

    private func requestCloseRemoteWindow(_ window: TmuxWindow, hostId: String) {
        guard ownsTerminal(hostID: hostId, windowID: window.stableId) else { return }
        guard let manager = coordinator.viewerConnectionManager else { return }
        let binding = manager.connection(for: hostId)?.relayClient.workspaceInputState.windowBinding(target: window.stableId) ?? .unavailable
        let sessionBinding = manager.connection(for: hostId)?.relayClient.workspaceInputState.sessionBinding(name: window.sessionName) ?? .unavailable
        let target = CloseConfirmation.Target.remoteWindow(window, hostId: hostId, binding: binding)
        Task {
            let spec = CheckRunningProcesses(target: .window(window.stableId))
            let result = await manager.sendCommand(spec, paneId: "", hostId: hostId, inputBinding: binding)
            guard ownsTerminal(hostID: hostId, windowID: window.stableId) else { return }
            switch result {
            case let .success(response):
                let processes = response.runningProcesses ?? []
                let windows = remoteSessionWindows(hostId: hostId, sessionName: window.sessionName)
                let closesSession = windows.count == 1 && windows.first?.stableId == window.stableId && !hasIndependentResources(hostID: hostId, sessionName: window.sessionName)
                if processes.isEmpty, !closesSession {
                    performClose(target)
                } else {
                    closeConfirmation = CloseConfirmation(
                        target: closesSession ? .remoteSession(sessionName: window.sessionName, hostId: hostId, binding: sessionBinding) : target,
                        runningProcesses: processes,
                        closesLastWindow: closesSession
                    )
                }
            case let .failure(error):
                attachError = error.localizedDescription
            }
        }
    }

    private func requestCloseRemoteSession(_ sessionName: String, hostId: String) {
        if let session = coordinator.viewerConnectionManager?.connection(for: hostId)?.relayClient.resourceSessions.first(where: { $0.name == sessionName }) {
            closeConfirmation = .init(target: .resourceSession(session, hostID: hostId), runningProcesses: [])
            return
        }
        guard let manager = coordinator.viewerConnectionManager else { return }
        let binding = manager.connection(for: hostId)?.relayClient.workspaceInputState.sessionBinding(name: sessionName) ?? .unavailable
        let target = CloseConfirmation.Target.remoteSession(sessionName: sessionName, hostId: hostId, binding: binding)
        Task {
            let spec = CheckRunningProcesses(target: .session(sessionName))
            let result = await manager.sendCommand(spec, paneId: "", hostId: hostId, inputBinding: binding)
            switch result {
            case let .success(response):
                let processes = response.runningProcesses ?? []
                if processes.isEmpty {
                    performClose(target)
                } else {
                    closeConfirmation = CloseConfirmation(
                        target: target,
                        runningProcesses: processes
                    )
                }
            case let .failure(error):
                attachError = error.localizedDescription
            }
        }
    }

    private func performClose(_ target: CloseConfirmation.Target) {
        Task {
            do {
                switch target {
                case let .resourceSession(session, hostID):
                    if let hostID, let client = coordinator.viewerConnectionManager?.connection(for: hostID)?.relayClient {
                        _ = try await ResourceTabClient.request(.init(sessionID: session.id, operation: .closeSession), client: client)
                        await client.requestSessionState()
                    } else if hostID == nil {
                        try await coordinator.closeResourceSession(session)
                    }
                case let .session(sessionName, identity):
                    try await tmuxService.killSession(sessionName, expectedWorkspacePane: identity)
                    if selectedRemoteSession == nil, selectedLocalSessionName == sessionName {
                        selectedWindow = nil
                        selectedLocalSessionName = nil
                    }
                case let .window(window, identity):
                    guard ownsTerminal(hostID: nil, windowID: window.stableId) else { return }
                    try await tmuxService.killWindow(window.stableId, expectedWorkspacePane: identity)
                    // If the closed window was selected, select another window in the session
                    if selectedWindow?.stableId == window.stableId {
                        repairLocalLeftSelection(sessionName: window.sessionName)
                    }
                case let .remoteWindow(window, hostId, binding):
                    guard ownsTerminal(hostID: hostId, windowID: window.stableId) else { return }
                    guard let manager = coordinator.viewerConnectionManager else { return }
                    let result = await manager.sendCommand(
                        KillTmuxWindow(windowId: window.stableId),
                        paneId: "",
                        hostId: hostId,
                        inputBinding: binding
                    )
                    if case .success = result {
                        // Select another window if the closed one was selected
                        if selectedRemoteSession?.hostId == hostId, selectedRemoteWindow?.stableId == window.stableId {
                            let rightIDs = remoteSessionTabsStates[remoteTabsKey(hostId: hostId, sessionName: window.sessionName)]?.rightSideWindowIds ?? []
                            let remaining = selectedRemoteSessionWindows.filter {
                                $0.stableId != window.stableId && ownsTerminal(hostID: hostId, windowID: $0.stableId) && !rightIDs.contains($0.stableId)
                            }
                            selectedRemoteWindowId = remaining.first?.id
                        }
                    } else if case let .failure(error) = result {
                        attachError = error.localizedDescription
                    }
                case let .remoteSession(sessionName, hostId, binding):
                    guard let manager = coordinator.viewerConnectionManager else { return }
                    let result = await manager.sendCommand(
                        KillTmuxSession(sessionName: sessionName),
                        paneId: "",
                        hostId: hostId,
                        inputBinding: binding
                    )
                    if case let .failure(error) = result {
                        attachError = error.localizedDescription
                    } else if selectedRemoteSession?.hostId == hostId, selectedRemoteSession?.sessionName == sessionName {
                        selectedRemoteWindowId = nil
                        selectedRemoteSession = nil
                    }
                }
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    private func openSettingsToRemoteAccess() {
        // Set the tab to Remote Access before opening settings
        settings.selectedSettingsTab = .remoteAccess
        NSApp.setActivationPolicy(.regular)
        openSettings()
        MenuBarExtraView.bringAppToFront()
    }

    // MARK: - New Session

    private var localNewSessionPopover: some View {
        NewSessionContent(
            title: "New Session",
            projects: projects,
            isLoadingProjects: isLoadingProjects,
            creatingSelection: creatingSelection,
            onCreate: { request in
                createNewSession(request: request)
            },
            launchAgents: localLaunchAgents,
            directorySource: localDirectorySource,
            pluginShortName: { coordinator.pluginRegistry?.manifest($0)?.shortName ?? $0 }
        )
    }

    // MARK: - New Session Actions

    private var localDirectorySource: SessionDirectorySource {
        SessionDirectorySource(id: "local", create: { request in
            @Dependency(SessionDirectoryClient.self) var client
            return try await client.create(request)
        }, prepareWorktree: { path in
            try await SessionLaunchPreparation.inspectWorktree(path: path)
        }) { request in
            @Dependency(SessionDirectoryClient.self) var client
            return try await client.list(request)
        }
    }

    private var localLaunchAgents: [SessionLaunchAgent] {
        coordinator.localAgentLaunchAgents()
    }

    private func agentTabConfiguration(
        sessionName: String, hostID: String?, fallbackDirectory: String?
    ) -> NewAgentTabConfiguration {
        let store = coordinator.remoteSessionStore
        let connection = hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0) }
        let source: SessionDirectorySource
        let agents: [SessionLaunchAgent]
        let reason: String?
        if let hostID {
            agents = store?.launchAgents(for: hostID) ?? []
            source = .remote(
                hostID: hostID,
                connection: connection,
                supportsBrowsing: store?.hostsSupportingDirectoryBrowsing.contains(hostID) == true,
                supportsCreation: store?.hostsSupportingDirectoryCreation.contains(hostID) == true
            )
            reason = agentTabUnavailableReason(hostID: hostID)
        } else {
            agents = localLaunchAgents
            source = localDirectorySource
            reason = nil
        }

        // A right-hand tab or non-active pane may own native keyboard focus.
        // Scope that focus to this Host/session before inheriting its cwd.
        var directory = fallbackDirectory
        if let focused = terminalQuickActions.active, focused.isAvailable, focused.hostID == hostID {
            if
                let hostID,
                let pane = store?.paneStates[PaneKey(pairId: hostID, paneId: focused.paneID)],
                pane.sessionName == sessionName {
                directory = pane.currentPath
            } else if
                hostID == nil,
                let pane = tmuxService.panes.first(where: { $0.paneId == focused.paneID && $0.sessionName == sessionName }) {
                directory = pane.currentPath
            }
        }
        let initialDirectory = directory.flatMap { SessionDirectoryPath.isValid($0) ? $0 : nil } ?? "~/"
        let localIdentity = tmuxService.panes.first { $0.sessionName == sessionName }?.workspaceIdentity
        let remoteBinding = connection?.relayClient.workspaceInputState.sessionBinding(name: sessionName) ?? .unavailable
        return NewAgentTabConfiguration(
            id: .init(hostID: hostID, sessionName: sessionName),
            initialDirectory: initialDirectory,
            agents: agents,
            directorySource: source,
            unavailableReason: reason,
            start: { request in try await createAgentTab(request, hostID: hostID, localIdentity: localIdentity, remoteBinding: remoteBinding) }
        )
    }

    private func agentTabUnavailableReason(hostID: String) -> String? {
        guard let store = coordinator.remoteSessionStore else {
            return "Host is offline. Reconnect before starting an agent."
        }
        return store.agentWindowLaunchUnavailableReason(
            hostID: hostID,
            isConnected: coordinator.viewerConnectionManager?.connection(for: hostID)?.isHostConnected == true
        )
    }

    private func agentForkUnavailableReason(hostID: String, requiresDirectory: Bool = false) -> String? {
        let isConnected = coordinator.viewerConnectionManager?.connection(for: hostID)?.isHostConnected == true
        guard isConnected else {
            return "Host is offline. Reconnect before forking an Agent."
        }
        guard let store = coordinator.remoteSessionStore else {
            return "Update this Host to fork Agent conversations."
        }
        return store.agentForkUnavailableReason(hostID: hostID, isConnected: isConnected, requiresDirectory: requiresDirectory)
    }

    private func agentForkConfiguration(panes: [PaneState], hostID: String?, destination: AgentForkDestination, focusedPaneID: String? = nil) -> AgentForkConfiguration {
        let focused = focusedPaneID ?? terminalQuickActions.active.flatMap { $0.hostID == hostID ? $0.paneID : nil }
        let sources = AgentForkConfiguration.orderedSources(panes: panes, focusedPaneID: focused)
        let inputState = hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.workspaceInputState }
        let store = coordinator.remoteSessionStore
        let directorySource: SessionDirectorySource? = if let hostID {
            store?.hostsSupportingAgentForkDirectory.contains(hostID) == true ? .remote(
                hostID: hostID,
                connection: coordinator.viewerConnectionManager?.connection(for: hostID),
                supportsBrowsing: store?.hostsSupportingDirectoryBrowsing.contains(hostID) == true,
                supportsCreation: store?.hostsSupportingDirectoryCreation.contains(hostID) == true
            ) : nil
        } else {
            localDirectorySource
        }
        return AgentForkConfiguration(
            sources: sources, destination: destination, directorySource: directorySource,
            prepare: { source in
                if let hostID {
                    if let reason = agentForkUnavailableReason(hostID: hostID) {
                        throw AgentForkError(reason)
                    }
                    guard let connection = coordinator.viewerConnectionManager?.connection(for: hostID) else {
                        throw AgentForkError("Viewer connection is unavailable.")
                    }
                    let response = try await connection.sendCommand(PrepareAgentFork(source: source), paneId: "", timeout: 30, inputBinding: inputState?.binding(paneID: source.paneID) ?? .unavailable).get()
                    guard let preparation = response.forkPreparation else { throw AgentForkError("Host returned no Fork preparation.") }
                    return preparation
                }
                return try await coordinator.prepareAgentFork(source)
            },
            fork: { request in try await createAgentFork(request, hostID: hostID, inputState: inputState) }
        )
    }

    private func createAgentFork(_ request: ForkAgentSession, hostID: String?, inputState: ViewerWorkspaceInputState?) async throws {
        guard !isCreatingAgentTab else { throw AgentForkError("An Agent tab is already being created. Please wait.") }
        isCreatingAgentTab = true
        defer { isCreatingAgentTab = false }
        let paneID: String
        if let hostID {
            if let reason = agentForkUnavailableReason(hostID: hostID, requiresDirectory: request.workingDirectory != nil) {
                throw AgentForkError(reason)
            }
            guard let connection = coordinator.viewerConnectionManager?.connection(for: hostID) else {
                throw AgentForkError("Viewer connection is unavailable.")
            }
            let sessionBinding = inputState?.sessionBinding(name: request.source.sessionName) ?? .unavailable
            let response = try await connection.sendCommand(request, paneId: "", timeout: 180, inputBinding: inputState?.binding(paneID: request.source.paneID) ?? .unavailable).get()
            guard let newPane = response.paneId else { throw AgentForkError("Host returned no new pane. Check its tabs before retrying.") }
            paneID = newPane
            await connection.relayClient.requestSessionState()
            for _ in 0..<PaneSurfaceRetry.attempts {
                _ = try sessionBinding.expectedPane(current: connection.relayClient.workspaceInputState.sessionBinding(name: request.source.sessionName))
                if
                    let window = coordinator.remoteSessionStore?.windows(for: hostID).first(where: {
                        $0.sessionName == request.source.sessionName && $0.panes.contains(where: { $0.paneId == paneID })
                    }) {
                    adoptCreatedWindow(hostID: hostID, windowID: window.stableId)
                    if selectedRemoteSession?.hostId == hostID && selectedRemoteSession?.sessionName == request.source.sessionName {
                        selectTerminalWindow(stableId: window.stableId)
                    }
                    return
                }
                try await Task.sleep(for: PaneSurfaceRetry.delay)
            }
        } else {
            paneID = try await coordinator.forkAgentSession(request)
            if let window = await PaneSurfaceRetry.localWindow(containing: paneID, windows: { tmuxService.windows }, refresh: { _ = await tmuxService.refreshPanes() }) {
                guard
                    let identity = request.source.workspaceIdentity,
                    window.panes.contains(where: { $0.workspaceIdentity?.isSameSession(as: identity) == true }) else {
                    throw AgentForkError("The session changed while creating the Fork. Select the restored session.")
                }
                adoptCreatedWindow(hostID: nil, windowID: window.stableId)
                if currentLocalSession()?.sessionName == request.source.sessionName {
                    selectTerminalWindow(stableId: window.stableId)
                }
                return
            }
        }
        attachError = "Fork created but not visible yet. Select its tab when it appears; do not create another Fork."
    }

    private func createAgentTab(_ request: CreateTmuxWindow, hostID: String?, localIdentity: WorkspacePaneIdentity?, remoteBinding: ViewerWorkspaceInputBinding) async throws {
        let resourceID = hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.resourceSessions.first { $0.name == request.sessionName }?.id }
            ?? (hostID == nil ? coordinator.resourceSessions.sessions.first { $0.name == request.sessionName }?.id : nil)
        let request = request.inResourceSession(resourceID)
        guard !isCreatingAgentTab else {
            throw NewAgentTabConfiguration.LaunchError("An Agent tab is already being created. Please wait.")
        }
        guard let pluginID = request.pluginID else {
            throw NewAgentTabConfiguration.LaunchError("Choose an Agent before starting.")
        }
        isCreatingAgentTab = true
        defer { isCreatingAgentTab = false }

        if let hostID {
            // Recheck after the popover opened: a disconnect/downgrade must not
            // turn the optional plugin field into an ordinary shell request.
            if let reason = agentTabUnavailableReason(hostID: hostID) {
                throw NewAgentTabConfiguration.LaunchError(reason)
            }
            guard let connection = coordinator.viewerConnectionManager?.connection(for: hostID) else {
                throw NewAgentTabConfiguration.LaunchError("Viewer connection is unavailable.")
            }
            let response = try await connection.sendCommand(request, paneId: "", inputBinding: remoteBinding).get()
            guard let paneID = response.paneId else {
                throw NewAgentTabConfiguration.LaunchError("Host returned no new pane. Check its tabs before retrying.")
            }
            if let initialization = response.agentModelShortcuts {
                coordinator.agentModelPreferences.initialize(initialization, hostID: hostID)
            }
            await connection.relayClient.requestSessionState()
            for _ in 0..<PaneSurfaceRetry.attempts {
                if resourceID == nil {
                    _ = try remoteBinding.expectedPane(current: connection.relayClient.workspaceInputState.sessionBinding(name: request.sessionName))
                }
                let windows = coordinator.remoteSessionStore?.windows(for: hostID) ?? []
                if let window = windows.first(where: { $0.sessionName == request.sessionName && $0.panes.contains(where: { $0.paneId == paneID }) }) {
                    adoptCreatedWindow(hostID: hostID, windowID: window.stableId)
                    if selectedRemoteSession?.hostId == hostID && selectedRemoteSession?.sessionName == request.sessionName {
                        selectTerminalWindow(stableId: window.stableId)
                    }
                    return
                }
                try await Task.sleep(for: PaneSurfaceRetry.delay)
            }
        } else {
            guard localIdentity != nil || resourceID != nil else { throw NewAgentTabConfiguration.LaunchError("Session identity is not available yet. Reopen this dialog after discovery.") }
            let shortcutDefaults = coordinator.newAgentModelShortcuts(pluginID: pluginID, providerID: request.providerID)
            let paneID = try await TmuxWindowCreation.create(
                request, core: coordinator.pluginRegistry?.core(pluginID), tmux: tmuxService, expectedWorkspacePane: localIdentity
            )
            if let captured = try? await tmuxService.captureWorkspacePane(target: paneID) {
                coordinator.agentModelPreferences.initialize(.init(pane: captured.identity, defaults: shortcutDefaults), hostID: "local")
            }
            let window = await PaneSurfaceRetry.localWindow(
                containing: paneID,
                windows: { tmuxService.windows },
                refresh: { _ = await tmuxService.refreshPanes() }
            )
            if let window {
                guard
                    window.panes.contains(where: { pane in
                        if let localIdentity {
                            return pane.workspaceIdentity?.isSameSession(as: localIdentity) == true
                        }
                        return pane.workspaceIdentity?.sessionID == resourceID
                    }) else {
                    throw NewAgentTabConfiguration.LaunchError("The session changed while creating the Agent. Select the restored session.")
                }
                adoptCreatedWindow(hostID: nil, windowID: window.stableId)
                if currentLocalSession()?.sessionName == request.sessionName {
                    selectTerminalWindow(stableId: window.stableId)
                }
                return
            }
        }
        // Creation already succeeded. Dismiss rather than offering a retry that
        // would launch a second agent just because the state push was delayed.
        attachError = "Agent tab created but not visible yet. Select it from the tab bar when it appears; do not launch it again."
    }

    private func loadProjects(showLoadingIndicator: Bool = true) async {
        if showLoadingIndicator {
            isLoadingProjects = true
        }
        projects = await coordinator.scanProjects()
        if showLoadingIndicator {
            isLoadingProjects = false
        }
    }

    /// Calculates optimal terminal dimensions based on available detail pane space.
    ///
    /// Uses the current font settings to determine character cell size and calculates
    /// how many columns and rows fit in the available space, accounting for UI padding.
    ///
    /// When the detail area is split between a left and right pane (issue #498),
    /// callers pass the rendered width of the specific pane via `widthOverride`
    /// so the terminal is resized to fit its half — not the full detail width.
    ///
    /// - Parameter widthOverride: Effective rendered width to use instead of
    ///   the full `detailPaneSize.width`. Pass `nil` for the unsplit layout.
    /// - Returns: A tuple of (columns, rows) for the terminal dimensions
    private func calculateOptimalTerminalDimensions(widthOverride: CGFloat? = nil) -> (columns: Int, rows: Int) {
        let effectiveWidth = widthOverride ?? detailPaneSize.width

        // Guard against uninitialized or invalid size
        guard effectiveWidth >= 100, detailPaneSize.height >= 100 else {
            return (columns: 120, rows: 40)
        }

        // Calculate cell size using current font settings
        let cellSize = FontMetrics.calculateCellSize(
            fontName: settings.fontName,
            fontSize: CGFloat(settings.fontSize)
        )

        // Horizontal padding: SwiftTerm scroller buffer
        let horizontalPadding = FontMetrics.horizontalBuffer

        // Vertical padding: window tab bar (~30px) + status bar (~28px) + some buffer for spacing
        let verticalPadding: CGFloat = 30 + (settings.showStatusBar ? 40 : 10)

        // Calculate available content area
        let availableWidth = max(0, effectiveWidth - horizontalPadding)
        let availableHeight = max(0, detailPaneSize.height - verticalPadding)

        // Apply reasonable bounds
        // Minimum: 80x24 (standard terminal size)
        // Maximum: 300x100 (prevent unreasonably large terminals)
        let columns = max(80, min(300, Int(availableWidth / cellSize.width)))
        let rows = max(24, min(100, Int(availableHeight / cellSize.height)))

        return (columns, rows)
    }

    /// Returns the rendered width for a visible terminal in the current CtrlX
    /// layout. `nil` means the terminal owns the full detail width.
    private func effectiveTerminalWidth(
        tabs: SessionFileTabsState?,
        windowId: String
    ) -> CGFloat? {
        guard let tabs, tabs.isSplit else { return nil }
        let isOnRight = tabs.rightSide.contains(.window(windowId))
        let ratio = isOnRight ? (1 - tabs.splitRatio) : tabs.splitRatio
        return max(0, detailPaneSize.width * ratio - SplitLayout.dividerWidth / 2)
    }

    /// Equatable snapshot of the currently selected session's split layout,
    /// used as the source for `.onChange(of:)` so shared layout publication
    /// fires for every split membership/selection change.
    /// Returns `nil` when nothing is selected so `.onChange` still fires on
    /// the first non-nil transition.
    private var currentSessionSplitSignal: SplitSignal? {
        if
            let sessionName = selectedWindow?.sessionName,
            let tabs = sessionFileTabsStates[sessionName] {
            return splitSignal(from: tabs)
        }
        if let remote = selectedRemoteSession {
            let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            guard let tabs = remoteSessionTabsStates[key] else { return nil }
            return splitSignal(from: tabs)
        }
        return nil
    }

    private func splitSignal(from tabs: SessionFileTabsState) -> SplitSignal {
        let rightWindowId: String? = {
            if case let .window(id) = tabs.selectedRight {
                return id
            }
            return nil
        }()
        return SplitSignal(
            isSplit: tabs.isSplit,
            splitRatio: tabs.splitRatio,
            rightWindowIds: tabs.rightSideWindowIds.sorted(),
            selectedRightWindowId: rightWindowId
        )
    }

    /// Equatable bundle of split-view state used to drive `.onChange(of:)`.
    private struct SplitSignal: Equatable {
        let isSplit: Bool
        let splitRatio: CGFloat
        /// Stable ordering avoids Set iteration noise while still observing a
        /// non-selected terminal moving across the divider.
        let rightWindowIds: [String]
        let selectedRightWindowId: String?
    }

    // MARK: - Shared Terminal Layout

    private var selectedLocalSharedTerminalLayout: SharedTerminalLayout? {
        guard
            selectedRemoteSession == nil,
            let sessionName = selectedWindow?.sessionName
        else { return nil }
        return windowManager.sharedTerminalLayouts[sessionName]
    }

    private var selectedRemoteSharedTerminalLayout: SharedTerminalLayout? {
        guard let remote = selectedRemoteSession else { return nil }
        return coordinator.remoteSessionStore?.sharedTerminalLayout(
            for: remote.hostId,
            sessionName: remote.sessionName
        )
    }

    private enum SharedLayoutSyncTarget {
        case local(SetSharedTerminalLayout)
        case remote(hostId: String, request: SetSharedTerminalLayout)
    }

    /// Coalesces divider drag updates into one logical layout publication.
    /// Host updates go straight into the canonical store; Viewer updates are
    /// requests that the Host validates and republishes with a new revision.
    private func scheduleSharedTerminalLayoutSync() {
        guard detachedWorkspace == nil else { return }
        sharedLayoutSyncTask?.cancel()
        let originalRemote = selectedRemoteSession
        let originalLocalIdentity = selectedWindow?.panes.first?.workspaceIdentity
        let originalRemoteBinding = originalRemote.flatMap { remote in
            coordinator.viewerConnectionManager?.connection(for: remote.hostId)?
                .relayClient.workspaceInputState.sessionBinding(name: remote.sessionName)
        }

        sharedLayoutSyncTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // Resolve the target after the debounce. Applying an incoming Host
            // layout can change both the split and the selected-left window in
            // one SwiftUI update; capturing either value before that update
            // settles can echo a stale layout back over the canonical one.
            let target: SharedLayoutSyncTarget?
            if selectedRemoteSession == nil, let request = currentLocalTerminalLayoutRequest() {
                target = .local(request)
            } else if
                let remote = selectedRemoteSession,
                coordinator.remoteSessionStore?.hasAuthoritativeSharedTerminalLayout(
                    for: remote.hostId,
                    sessionName: remote.sessionName
                ) == true,
                let request = currentRemoteTerminalLayoutRequest(remote: remote) {
                target = .remote(hostId: remote.hostId, request: request)
            } else {
                target = nil
            }
            guard let target else { return }

            switch target {
            case let .local(request):
                guard
                    originalRemote == nil,
                    let originalLocalIdentity,
                    selectedWindow?.panes.first?.workspaceIdentity?.isSameSession(as: originalLocalIdentity) == true
                else { return }
                if
                    windowManager.setSharedTerminalLayout(
                        sessionName: request.sessionName,
                        leftWindowId: request.leftWindowId,
                        rightWindowIds: request.rightWindowIds,
                        selectedRightWindowId: request.selectedRightWindowId,
                        splitRatio: request.splitRatio
                    ) {
                    await coordinator.connectedViewerManager?.pushSessionStateToAll()
                }

            case let .remote(hostId, request):
                guard
                    originalRemote?.hostId == hostId,
                    originalRemote?.sessionName == request.sessionName,
                    let originalRemoteBinding
                else { return }
                if
                    let current = coordinator.remoteSessionStore?.sharedTerminalLayout(
                        for: hostId,
                        sessionName: request.sessionName
                    ), terminalLayout(current, matches: request) {
                    return
                }
                guard let manager = coordinator.viewerConnectionManager else { return }
                let result = await manager.sendCommand(
                    request,
                    paneId: "",
                    hostId: hostId,
                    inputBinding: originalRemoteBinding
                )
                if let message = Self.sharedTerminalLayoutSyncError(result) {
                    attachError = message
                }
            }
        }
    }

    static func sharedTerminalLayoutSyncError(_ result: Result<CommandResponseMessage, Error>) -> String? {
        // Selection changes can cancel a task while it awaits a remote reply.
        // Its late result must not surface an error in the newly selected window.
        guard
            !Task.isCancelled,
            case let .failure(error) = result,
            !(error is CancellationError) else { return nil }
        return "Failed to update shared layout: \(error.localizedDescription)"
    }

    private func terminalLayout(_ layout: SharedTerminalLayout, matches request: SetSharedTerminalLayout) -> Bool {
        layout.leftWindowId == request.leftWindowId
            && layout.rightWindowIds == request.rightWindowIds
            && layout.selectedRightWindowId == request.selectedRightWindowId
            && layout.splitRatio == min(max(request.splitRatio, 0.15), 0.85)
    }

    private func currentLocalTerminalLayoutRequest() -> SetSharedTerminalLayout? {
        guard
            let leftWindow = selectedWindow,
            ownsTerminal(hostID: nil, windowID: leftWindow.stableId),
            // A missing Host entry is a cold-start initialization state, not an
            // implicit unsplit layout. Let persistence establish authority first
            // so the UI cannot overwrite a saved split with a default request.
            windowManager.sharedTerminalLayouts[leftWindow.sessionName] != nil
        else { return nil }
        let windows = tmuxService.windows.filter { $0.sessionName == leftWindow.sessionName }
        let tabs = sessionFileTabsStates[leftWindow.sessionName]
        let rightWindowIds = sharedRightWindowIds(
            tabs: tabs,
            orderedWindowIds: windows.map(\.stableId)
        )
        let selectedRightWindowId = sharedSelectedRightWindowId(
            tabs: tabs,
            rightWindowIds: rightWindowIds,
            existing: windowManager.sharedTerminalLayouts[leftWindow.sessionName]?.selectedRightWindowId
        )
        return SetSharedTerminalLayout(
            sessionName: leftWindow.sessionName,
            leftWindowId: leftWindow.stableId,
            rightWindowIds: rightWindowIds,
            selectedRightWindowId: selectedRightWindowId,
            splitRatio: Double(tabs?.splitRatio ?? 0.5)
        )
    }

    private func currentRemoteTerminalLayoutRequest(
        remote: RemoteSessionSelection
    ) -> SetSharedTerminalLayout? {
        guard let leftWindow = selectedRemoteWindow, ownsTerminal(hostID: remote.hostId, windowID: leftWindow.stableId) else { return nil }
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        let tabs = remoteSessionTabsStates[key]
        let windows = selectedRemoteSessionWindows
        let rightWindowIds = sharedRightWindowIds(
            tabs: tabs,
            orderedWindowIds: windows.map(\.stableId)
        )
        let selectedRightWindowId = sharedSelectedRightWindowId(
            tabs: tabs,
            rightWindowIds: rightWindowIds,
            existing: coordinator.remoteSessionStore?.sharedTerminalLayout(
                for: remote.hostId,
                sessionName: remote.sessionName
            )?.selectedRightWindowId
        )
        return SetSharedTerminalLayout(
            sessionName: remote.sessionName,
            leftWindowId: leftWindow.stableId,
            rightWindowIds: rightWindowIds,
            selectedRightWindowId: selectedRightWindowId,
            splitRatio: Double(tabs?.splitRatio ?? 0.5)
        )
    }

    private func sharedRightWindowIds(
        tabs: SessionFileTabsState?,
        orderedWindowIds: [String]
    ) -> [String] {
        guard let tabs else { return [] }
        return orderedWindowIds.filter { tabs.rightSide.contains(.window($0)) }
    }

    /// Browser/file focus is local. If it temporarily occupies the right pane,
    /// retain the canonical selected terminal rather than changing every peer.
    private func sharedSelectedRightWindowId(
        tabs: SessionFileTabsState?,
        rightWindowIds: [String],
        existing: String?
    ) -> String? {
        guard !rightWindowIds.isEmpty else { return nil }
        if case let .window(id) = tabs?.selectedRight, rightWindowIds.contains(id) {
            return id
        }
        if let existing, rightWindowIds.contains(existing) {
            return existing
        }
        return rightWindowIds.first
    }

    private func applySelectedLocalSharedTerminalLayout() {
        guard detachedWorkspace == nil else { return }
        guard
            selectedRemoteSession == nil,
            let currentWindow = selectedWindow,
            let layout = windowManager.sharedTerminalLayouts[currentWindow.sessionName]
        else { return }

        let windows = tmuxService.windows.filter { $0.sessionName == currentWindow.sessionName && ownsTerminal(hostID: nil, windowID: $0.stableId) }
        let liveIds = Set(windows.map(\.stableId))
        guard liveIds.contains(layout.leftWindowId) else { return }
        let tabs = sessionFileTabsStates[currentWindow.sessionName] ?? {
            let tabs = SessionFileTabsState()
            sessionFileTabsStates[currentWindow.sessionName] = tabs
            return tabs
        }()
        tabs.applySharedTerminalLayout(layout, liveWindowIds: liveIds)
        if let left = windows.first(where: { $0.stableId == layout.leftWindowId }) {
            selectedWindow = left
        }
        reconcileRightPaneSelection(sessionName: currentWindow.sessionName)
    }

    private func applySelectedRemoteSharedTerminalLayout() {
        guard detachedWorkspace == nil else { return }
        guard
            let remote = selectedRemoteSession,
            let layout = coordinator.remoteSessionStore?.sharedTerminalLayout(
                for: remote.hostId,
                sessionName: remote.sessionName
            )
        else { return }

        let windows = selectedRemoteSessionWindows.filter { ownsTerminal(hostID: remote.hostId, windowID: $0.stableId) }
        let liveIds = Set(windows.map(\.stableId))
        guard liveIds.contains(layout.leftWindowId) else { return }
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        let tabs = remoteSessionTabsStates[key] ?? {
            let tabs = SessionFileTabsState()
            remoteSessionTabsStates[key] = tabs
            return tabs
        }()
        tabs.applySharedTerminalLayout(layout, liveWindowIds: liveIds)
        if let left = windows.first(where: { $0.stableId == layout.leftWindowId }) {
            selectedRemoteWindowId = left.id
        }
        reconcileRemoteRightPaneSelection(
            hostId: remote.hostId,
            sessionName: remote.sessionName,
            sessionWindows: windows
        )
    }

    private func createNewSession(request: SessionLaunchRequest) {
        let project = request.project
        guard creatingSelection == nil else { return }
        creatingSelection = project.map { .project($0.id) } ?? .newTerminal

        Task {
            // Always clear the in-flight guard on any exit (including an early
            // return when the task is cancelled mid-retry), so a later create
            // isn't blocked by `guard creatingSelection == nil`.
            defer { creatingSelection = nil }
            var preparation: SessionLaunchPreparation?
            do {
                // Determine session name and working directory
                let sessionName = project?.name ?? "terminal"
                let shortcutDefaults = project.map { coordinator.newAgentModelShortcuts(pluginID: $0.pluginID, providerID: request.providerID) }

                // Resolve the launch command from the project's owning plugin core
                // (`commandForLaunch`, gated on the plugin's auto-run setting). A
                // nil runCommand means "open in a bare shell".
                let launch = if let project {
                    try await coordinator.resolveLaunch(
                        forPluginID: project.pluginID,
                        projectPath: project.path,
                        requireAgentLaunch: request.requiresAgentLaunch,
                        worktree: request.worktree,
                        providerID: request.providerID
                    )
                } else {
                    SessionLaunchPreparation(workingDirectory: nil, launch: nil)
                }
                preparation = launch
                let agentLaunch = try tmuxService.agentLaunch(launch)
                let workingDirectory = launch.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path()

                var extraEnvironment: [String] = []
                if let configDir = project?.configDir {
                    extraEnvironment.append("CLAUDE_CONFIG_DIR=\(configDir)")
                }
                // Calculate optimal dimensions based on available space
                let dimensions = calculateOptimalTerminalDimensions()

                // Create the session with calculated dimensions; name the first
                // window after the launch command's binary (or "terminal 1" for a
                // bare shell). Arguments are separate from the executable path.
                let firstWindowName: String = if let command = launch.launch?.command {
                    URL(fileURLWithPath: command).lastPathComponent
                } else {
                    "terminal 1"
                }
                let created = try await tmuxService.createSession(
                    baseName: sessionName,
                    width: dimensions.columns,
                    height: dimensions.rows,
                    workingDirectory: workingDirectory,
                    runCommand: agentLaunch?.command,
                    extraEnvironment: extraEnvironment,
                    launchPayload: agentLaunch?.payload,
                    firstWindowName: request.worktree?.name ?? firstWindowName
                )
                if
                    launch.launch != nil, let shortcutDefaults,
                    let captured = try? await tmuxService.captureWorkspacePane(target: created.paneId),
                    captured.identity.serverID == created.serverID {
                    coordinator.agentModelPreferences.initialize(.init(pane: captured.identity, defaults: shortcutDefaults), hostID: "local")
                }

                // Find the window containing the new pane and select it.
                //
                // The cached window list can momentarily lag tmux:
                // `createSession`'s own `refreshPanes()` early-returns the stale
                // cached list when a periodic refresh is already in flight (more
                // likely on a slow machine), so the just-created pane can be
                // missing on the first lookup, leaving the new session never
                // selected ("Select a Window"). The pane definitely exists — we
                // hold its id — so retry the refresh until its window shows up.
                // Mirrors the same retry in AppCoordinator's split-window path.
                //
                // Clearing the remote selection mirrors createRemoteSession's
                // own "clear the other side" step — without it, the sidebar's
                // local-row highlight stays suppressed (see the listRowBackground
                // check in sessionButton) whenever a remote session was the
                // last thing the user interacted with, even after that remote
                // session was closed.
                let newWindow = await PaneSurfaceRetry.localWindow(
                    containing: created.paneId,
                    serverID: created.serverID,
                    windows: { tmuxService.windows },
                    refresh: { _ = await tmuxService.refreshPanes() }
                )
                guard !Task.isCancelled else { return }
                if let newWindow {
                    selectedRemoteSession = nil
                    selectedRemoteWindowId = nil
                    selectedWindow = newWindow
                } else {
                    // The pane never surfaced within the retry budget — surface it
                    // rather than leaving the user on a silent "Select a Window".
                    attachError = "Session created but its window didn't appear in time. Try selecting it from the sidebar."
                }
            } catch {
                attachError = "Failed to create session: \(preparation?.failureDescription(error) ?? error.localizedDescription)"
            }
        }
    }

    // MARK: - Remote Session Rename / Creation

    private func renameRemoteSession(on host: PairedHost, from sessionName: String, to newName: String, inputBinding: ViewerWorkspaceInputBinding) {
        Task {
            guard let manager = coordinator.viewerConnectionManager else {
                attachError = "Viewer connection not available"
                return
            }

            let result = await manager.sendCommand(
                RenameTmuxSession(sessionName: sessionName, newName: newName),
                paneId: "",
                hostId: host.id,
                inputBinding: inputBinding
            )
            switch result {
            case .success:
                settings.replaceRemoteSessionName(sessionName, with: newName, for: host.id)
                // Every scene migrates from the authoritative snapshot, including
                // renames initiated on another Viewer or directly on the Host.
                await manager.requestSessionState(for: host.id)
            case let .failure(error):
                attachError = "Failed to rename session on \(host.displayName): \(error.localizedDescription)"
            }
        }
    }

    private func migrateRemoteSessionState(
        hostId: String,
        from oldName: String,
        to newName: String,
        windowIDs: [String: String]
    ) {
        coordinator.detachedWindows.renameSession(hostID: hostId, from: oldName, to: newName, windowIDs: windowIDs)
        let oldKey = remoteTabsKey(hostId: hostId, sessionName: oldName)
        let newKey = remoteTabsKey(hostId: hostId, sessionName: newName)
        coordinator.agentBrowser.renameManualTabs(
            in: agentBrowserWorkspace,
            from: ManualBrowserTarget(hostID: hostId, sessionName: oldName),
            to: ManualBrowserTarget(hostID: hostId, sessionName: newName)
        )

        if seededRemoteSessions.remove(oldKey) != nil {
            seededRemoteSessions.insert(newKey)
        }
        // Let the renamed session start a fresh read. The old in-flight task
        // validates its original session after awaiting and exits harmlessly.
        seedingRemoteSessions.remove(oldKey)
        if let layout = lastPersistedRemoteLayouts.removeValue(forKey: oldKey) {
            lastPersistedRemoteLayouts[newKey] = layout
        }
        if let save = pendingRemoteLayoutSaves.removeValue(forKey: oldKey) {
            pendingRemoteLayoutSaves[newKey] = save
        }

        guard
            let selected = selectedRemoteSession,
            selected.hostId == hostId,
            selected.sessionName == oldName
        else { return }

        selectedRemoteSession = RemoteSessionSelection(
            hostId: hostId,
            hostName: selected.hostName,
            sessionName: newName
        )
        if let selectedRemoteWindowId {
            self.selectedRemoteWindowId = windowIDs[selectedRemoteWindowId] ?? selectedRemoteWindowId
        }
    }

    private func createRemoteSession(on host: PairedHost, request: SessionLaunchRequest) async {
        guard creatingSelection == nil else { return }

        let project = request.project

        creatingSelection = project.map { .project($0.id) } ?? .newTerminal
        defer { creatingSelection = nil }

        let sessionName = project?.name ?? "terminal"
        let dimensions = calculateOptimalTerminalDimensions()

        let command = CreateTmuxSession(
            sessionName: sessionName,
            width: dimensions.columns,
            height: dimensions.rows,
            workingDirectory: project?.path,
            configDir: project?.configDir,
            pluginID: project?.pluginID ?? AgentLaunchDefaults.pluginID,
            requireAgentLaunch: request.requiresAgentLaunch,
            worktree: request.worktree,
            providerID: request.providerID
        )

        guard let manager = coordinator.viewerConnectionManager else {
            attachError = "Viewer connection not available"
            return
        }

        let result = await manager.sendCommand(command, paneId: "", hostId: host.id, timeout: request.worktree == nil ? 15 : 180)

        switch result {
        case let .success(response):
            // Request a refresh to update the remote session list
            if let initialization = response.agentModelShortcuts {
                coordinator.agentModelPreferences.initialize(initialization, hostID: host.id)
            }
            await manager.requestSessionState(for: host.id)

            guard let paneId = response.paneId else { return }
            for attempt in 0..<PaneSurfaceRetry.attempts {
                guard !Task.isCancelled, manager.connection(for: host.id)?.isHostConnected == true else { return }
                if
                    let paneState = coordinator.remoteSessionStore?.paneState(for: paneId, hostId: host.id),
                    manager.connection(for: host.id)?.relayClient.workspaceInputState.createdSessionBinding(
                        pane: paneState, scope: response.createdPaneScope
                    ) != nil {
                    selectRemoteSession(.init(
                        hostId: host.id,
                        hostName: host.displayName,
                        sessionName: paneState.sessionName
                    ))
                    selectedRemoteWindowId = paneState.windowId
                    selectedWindow = nil
                    return
                }
                guard attempt + 1 < PaneSurfaceRetry.attempts else { break }
                try? await Task.sleep(for: PaneSurfaceRetry.delay)
            }
            attachError = "Session created but its current window is unavailable. Select it from the sidebar after reconnecting."
        case let .failure(error):
            let projectContext = project?.name ?? "terminal"
            attachError = "Failed to create \(projectContext) on \(host.displayName): \(error.localizedDescription)"
        }
    }
}

/// Typed dictionary key for `remoteSessionTabsStates`. Stores the host id and
/// session name as separate fields so a session name that contains a colon
/// can't collide with another `(hostId, sessionName)` pair (tmux allows
/// colons in session names).
struct RemoteSessionTabsKey: Hashable {
    let hostId: String
    let sessionName: String
}

// MARK: - Folder layout persistence

/// Seeding and auto-save glue for per-folder workbench persistence. Kept in this
/// file so it can read `MainView`'s private session-tab `@State`. See
/// `docs/folder-layout-persistence-plan.md`.
private extension MainView {
    /// Host identifier for **locally-managed** sessions — a constant, since a
    /// host only ever owns one set of local sessions. Remote/viewer sessions are
    /// persisted too (issue #608) but key their records by the host's `pairId`
    /// (passed directly in the remote seed/persist paths), never this constant,
    /// so local and remote records on the same path can't collide. The pairId is
    /// a UUID-shaped string, so it never equals `"local"`.
    var layoutHost: String {
        SavedFolderRecord.localHost
    }

    /// Windows belonging to `sessionName`, in tmux order.
    func windows(forSession sessionName: String) -> [LocalTmuxWindow] {
        tmuxService.windows.filter { $0.sessionName == sessionName }
    }

    /// Canonical project folder for a session: the active pane's detected
    /// project path when known, else its working directory. `nil` until a pane
    /// (and thus a path) is available.
    func resolveFolder(forSession sessionName: String) -> String? {
        resolveFolder(in: windows(forSession: sessionName))
    }

    /// Same as `resolveFolder(forSession:)` but works off a precomputed window
    /// list, so a hot loop can group `tmuxService.windows` once instead of
    /// re-filtering per session.
    func resolveFolder(in sessionWindows: [LocalTmuxWindow]) -> String? {
        guard
            let active = sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first,
            let pane = active.activePane
        else { return nil }
        let raw = windowManager.paneStates[pane.paneId]?.agentSession?.detectedProjectPath
            ?? pane.currentPath
        return LayoutFolderKey.canonicalize(raw)
    }

    /// Restore the selected session's workbench from the folder's persisted
    /// layout — once, and only while it's still empty so user-opened tabs are
    /// never clobbered. Layout is keyed by folder, so a new session inherits the
    /// folder's current layout and a recycled session name no longer resurrects a
    /// stale per-session record (plan §4.3).
    func seedLayoutIfNeeded() {
        guard detachedWorkspace == nil else { return }
        guard isLayoutStoreReady, coordinator.workspaceRecoveryReady, let sessionName = selectedWindow?.sessionName else { return }
        guard !tabStore.restoredLocalSessions.contains(sessionName) else { return }

        // A selected session always owns tab-strip state, even when it only
        // contains terminals. Window drag/reorder mutates this model; treating
        // it as optional made a pure-terminal drop look successful while the
        // tmux reorder callback silently returned.
        let tabs: SessionFileTabsState
        if let existing = sessionFileTabsStates[sessionName] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            sessionFileTabsStates[sessionName] = tabs
        }

        guard
            !seededSessions.contains(sessionName),
            !seedingSessions.contains(sessionName)
        else { return }

        // Don't seed a session the user has already populated.
        if !tabs.isPrivateWorkbenchEmpty {
            seededSessions.insert(sessionName)
            return
        }
        guard let folder = resolveFolder(forSession: sessionName) else {
            // Folder not resolvable yet — leave unmarked so a later change retries.
            return
        }
        seedingSessions.insert(sessionName)

        let key = SavedFolderRecord.Key(host: layoutHost, folder: folder)
        Task {
            let chosen = await layoutStore.record(key)?.layout

            // The store await may have suspended across a cleanup pass that tore
            // this session down. Don't resurrect a dead session's tabs state.
            guard tmuxService.sessions.contains(where: { $0.sessionName == sessionName }) else {
                seedingSessions.remove(sessionName)
                return
            }

            // Re-check freshness now that we've awaited the store. Cleanup may
            // have removed the state while the read was suspended; never
            // resurrect a dead session from this task.
            guard let tabs = sessionFileTabsStates[sessionName] else {
                seedingSessions.remove(sessionName)
                return
            }
            defer {
                seedingSessions.remove(sessionName)
                seededSessions.insert(sessionName)
            }
            guard let chosen, !chosen.isEmpty else { return }
            guard tabs.isPrivateWorkbenchEmpty else { return }

            let sessionWindows = windows(forSession: sessionName)
            LayoutSnapshotMapper.apply(
                chosen,
                to: tabs,
                fileBrowser: fileBrowserStates[sessionName],
                includeGit: false,
                windowIdForIndex: { index in sessionWindows.first { $0.windowIndex == index }?.stableId },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            tabs.migrateLegacyExplorer(directory: folder)
            if let shared = windowManager.sharedTerminalLayouts[sessionName] {
                tabs.applySharedTerminalLayout(
                    shared,
                    liveWindowIds: Set(sessionWindows.map(\.stableId))
                )
            }
            // Baseline the change-gate from the *applied* state, not `chosen`:
            // apply clamps the split ratio and resolves selection/window refs, so
            // re-snapshotting avoids one redundant save right after seeding.
            lastPersistedLayouts[sessionName] = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: fileBrowserStates[sessionName],
                windowIndexForId: { id in sessionWindows.first { $0.stableId == id }?.windowIndex }
            )
        }
    }

    /// Persist every session whose layout changed since its last write. Empty
    /// workbenches aren't recorded (nothing to restore). Called on each tmux
    /// refresh — the change check keeps the disk write rare.
    func persistChangedLayouts() {
        guard detachedWorkspace == nil else { return }
        // Group the window list once instead of filtering per session below.
        let windowsBySession = Dictionary(grouping: tmuxService.windows, by: \.sessionName)
        for (sessionName, tabs) in sessionFileTabsStates {
            // Seeding owns the first store access. Persisting shared terminal
            // placement before it completes can destroy a saved private layout.
            guard seededSessions.contains(sessionName) else { continue }
            guard !hasDetachedTabs(hostID: nil, session: sessionName) else { continue }
            let sessionWindows = windowsBySession[sessionName] ?? []
            guard let folder = resolveFolder(in: sessionWindows) else { continue }
            let snapshot = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: fileBrowserStates[sessionName],
                windowIndexForId: { id in sessionWindows.first { $0.stableId == id }?.windowIndex }
            )
            guard !snapshot.isEmpty else { continue }
            guard lastPersistedLayouts[sessionName] != snapshot else { continue }
            lastPersistedLayouts[sessionName] = snapshot

            let record = SavedFolderRecord(
                host: layoutHost,
                folder: folder,
                lastActive: Date(),
                layout: snapshot
            )
            // Chain on the session's prior save so writes reach the store in the
            // order they were produced, even though each runs in its own Task.
            let previous = pendingLayoutSaves[sessionName]
            pendingLayoutSaves[sessionName] = Task {
                await previous?.value
                await layoutStore.save(record)
            }
        }
    }

    // MARK: - Remote (viewer) sessions — issue #608

    /// Canonical project folder for a remote session, read from the viewer's
    /// synced `SessionStore`. Mirrors `resolveFolder(forSession:)` but uses
    /// **string-only** normalization: a remote path lives on the host's disk, so
    /// it must never be expanded/symlink-resolved against the viewer's. `nil`
    /// until a pane (and thus a path) for the session has synced.
    func resolveRemoteFolder(hostId: String, sessionName: String) -> String? {
        guard let sessionStore = coordinator.remoteSessionStore else { return nil }
        let sessionWindows = sessionStore.windows(for: hostId)
            .filter { $0.sessionName == sessionName }
        return resolveRemoteFolder(in: sessionWindows)
    }

    /// Same as `resolveRemoteFolder(hostId:sessionName:)` but off a precomputed
    /// window list, so the persist loop can group a host's windows once.
    func resolveRemoteFolder(in sessionWindows: [TmuxWindow]) -> String? {
        guard
            let active = sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first,
            let pane = active.activePane
        else { return nil }
        let raw = pane.agentSession?.detectedProjectPath ?? pane.currentPath
        return LayoutFolderKey.canonicalizeRemote(raw)
    }

    /// Remote counterpart of `seedLayoutIfNeeded`: restore the selected remote
    /// session's workbench from the folder's persisted record — once, and only
    /// while still empty. Records are keyed by `(pairId, folder)`, so a viewer
    /// restores its own arrangement for that remote folder and never collides
    /// with local (`layoutHost`) records.
    ///
    /// Directory and web tabs are private. Terminal placement still comes from
    /// the Host's shared layout; remote Files never use the local legacy tree.
    func seedRemoteLayoutIfNeeded() {
        guard detachedWorkspace == nil else { return }
        guard isLayoutStoreReady, let remote = selectedRemoteSession else { return }
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        guard !tabStore.restoredRemoteSessions.contains(key) else { return }

        let tabs = remoteSessionTabsStates[key] ?? {
            let new = SessionFileTabsState()
            remoteSessionTabsStates[key] = new
            return new
        }()
        guard
            !seededRemoteSessions.contains(key),
            !seedingRemoteSessions.contains(key)
        else { return }

        // Don't seed a session the user has already populated.
        if !tabs.isPrivateWorkbenchEmpty {
            seededRemoteSessions.insert(key)
            return
        }
        guard let folder = resolveRemoteFolder(hostId: remote.hostId, sessionName: remote.sessionName) else {
            // Folder not synced yet — leave unmarked so a later change retries.
            return
        }
        seedingRemoteSessions.insert(key)

        let recordKey = SavedFolderRecord.Key(host: remote.hostId, folder: folder)
        Task {
            let stored = await layoutStore.record(recordKey)?.layout

            // The store await may have suspended across a disconnect/unpair that
            // cleared this host's sessions. Don't resurrect a gone session.
            guard
                let sessionStore = coordinator.remoteSessionStore,
                sessionStore.sessions(for: remote.hostId).contains(where: { $0.sessionName == remote.sessionName })
            else {
                seedingRemoteSessions.remove(key)
                return
            }

            guard let tabs = remoteSessionTabsStates[key] else {
                seedingRemoteSessions.remove(key)
                return
            }
            defer {
                seedingRemoteSessions.remove(key)
                seededRemoteSessions.insert(key)
            }

            let sessionWindows = remoteSessionWindows(hostId: remote.hostId, sessionName: remote.sessionName)
            if let stored {
                let chosen = LayoutSnapshotMapper.viewerPrivateLayout(from: stored)
                // Rewrite legacy/general-purpose Viewer records once so an app
                // upgrade heals the persisted source of an empty right split.
                if chosen != stored {
                    if chosen.isEmpty {
                        await layoutStore.remove(recordKey)
                    } else {
                        await layoutStore.save(SavedFolderRecord(
                            host: remote.hostId,
                            folder: folder,
                            lastActive: Date(),
                            layout: chosen
                        ))
                    }
                }
                if !chosen.isEmpty, tabs.isPrivateWorkbenchEmpty {
                    LayoutSnapshotMapper.apply(
                        chosen,
                        to: tabs,
                        fileBrowser: nil,
                        windowIdForIndex: { _ in nil },
                        makeBrowserState: { BrowserTabState(initialURL: $0.url) }
                    )
                }
            }
            if
                let shared = coordinator.remoteSessionStore?.sharedTerminalLayout(
                    for: remote.hostId,
                    sessionName: remote.sessionName
                ) {
                tabs.applySharedTerminalLayout(
                    shared,
                    liveWindowIds: Set(sessionWindows.map(\.stableId))
                )
            }
            // Baseline the change-gate from the *applied* state (apply clamps the
            // split ratio and resolves window refs) so seeding doesn't trigger an
            // immediate redundant re-save.
            lastPersistedRemoteLayouts[key] = LayoutSnapshotMapper.viewerPrivateLayout(
                from: LayoutSnapshotMapper.snapshot(
                    from: tabs,
                    fileBrowser: nil,
                    windowIndexForId: { id in sessionWindows.first { $0.stableId == id }?.windowIndex }
                )
            )
        }
    }

    /// Remote counterpart of `persistChangedLayouts`: persist every remote
    /// session whose private browser-tab layout changed since its last write,
    /// keyed by `(pairId, folder)`. `fileTabs` come out empty (remote file
    /// browsing doesn't exist). Sessions whose folder no longer resolves (host
    /// disconnected, panes cleared) are skipped, so a vanished session never
    /// writes a stale record.
    func persistChangedRemoteLayouts() {
        guard detachedWorkspace == nil else { return }
        guard let sessionStore = coordinator.remoteSessionStore else { return }
        // Fetch each host's windows once (groups all panes) instead of
        // re-deriving them per session below.
        let hostIds = Set(remoteSessionTabsStates.keys.map(\.hostId))
        let windowsByHost = Dictionary(
            uniqueKeysWithValues: hostIds.map { ($0, sessionStore.windows(for: $0)) }
        )
        for (key, tabs) in remoteSessionTabsStates {
            // The restore read owns the first store access. Never persist the
            // terminal-only state that exists while that read is in flight.
            guard seededRemoteSessions.contains(key) else { continue }
            guard !hasDetachedTabs(hostID: key.hostId, session: key.sessionName) else { continue }
            let sessionWindows = (windowsByHost[key.hostId] ?? [])
                .filter { $0.sessionName == key.sessionName }
            guard let folder = resolveRemoteFolder(in: sessionWindows) else { continue }
            let snapshot = LayoutSnapshotMapper.viewerPrivateLayout(
                from: LayoutSnapshotMapper.snapshot(
                    from: tabs,
                    fileBrowser: nil,
                    windowIndexForId: { id in sessionWindows.first { $0.stableId == id }?.windowIndex }
                )
            )
            guard lastPersistedRemoteLayouts[key] != snapshot else { continue }
            lastPersistedRemoteLayouts[key] = snapshot

            let recordKey = SavedFolderRecord.Key(host: key.hostId, folder: folder)
            let record = SavedFolderRecord(
                host: key.hostId,
                folder: folder,
                lastActive: Date(),
                layout: snapshot
            )
            // Chain on the session's prior save so writes land in order.
            let previous = pendingRemoteLayoutSaves[key]
            pendingRemoteLayoutSaves[key] = Task {
                await previous?.value
                if snapshot.isEmpty {
                    await layoutStore.remove(recordKey)
                } else {
                    await layoutStore.save(record)
                }
            }
        }
    }
}
