import AppKit
import CtrlxBrowserBridge
import CtrlxNetworking
import Dependencies
import Foundation
import Logging
import Observation

/// Legacy display route. New human pages are Host-local and require a source pane.
struct ManualBrowserTarget: Equatable, Sendable {
    let hostID: String?
    let sessionName: String

    init(hostID: String? = nil, sessionName: String) {
        self.hostID = hostID
        self.sessionName = sessionName
    }

    init?(route: [String: String]) {
        guard route["manual"] == "true", let session = route["session"], !session.isEmpty else { return nil }
        self.init(hostID: route["host"], sessionName: session)
    }

    func route(workspaceID: UUID) -> [String: String] {
        var route = ["workspace": workspaceID.uuidString, "manual": "true", "session": sessionName]
        route["host"] = hostID
        return route
    }
}

/// One Chromium runtime per CtrlX process. Page state outlives SwiftUI tab
/// representations; authority (agent run) is distinct from UI routing (pane).
@MainActor
final public class AgentBrowserService: NSObject, @preconcurrency CXBrowserHostDelegate {
    public static func prepareApplication() {
        _ = CXBrowserPrepareApplication()
        CXBrowserSetDiagnosticsDelegate(AppKitDiagnostics.shared)
    }

    var runtime: (any CXBrowserRuntime)?
    var extensionStore: BrowserExtensionStore?
    var extensionOperationInProgress = false
    var extensionControl: BrowserExtensionControl?
    var extensionCleanupTask: Task<Void, Never>?
    private var workspaces: [UUID: AgentBrowserWorkspace] = [:]
    private(set) var tabs: [String: AgentBrowserTabState] = [:]
    private let parkingID = UUID()
    private lazy var parkingWindow: NSWindow = {
        _ = NSApplication.shared
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }()

    var onTabsChanged: (() -> Void)?
    var imageTargetForPane: (String) -> AgentImageTarget? = { _ in nil }
    var resolveSourcePane: (@MainActor (String, String) async throws -> PaneInfo)?
    private var openingPaneTabs: [String: Task<AgentBrowserTabState, Error>] = [:]
    private var detachingTabs: Set<String> = []
    private var publishTask: Task<Void, Never>?
    private var routePanes: [PaneInfo] = []

    func publishBrowserTabs() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.publishTask = nil
            self?.onTabsChanged?()
        }
    }

    var remoteControls: [UUID: BrowserControlLease] = [:]
    var remoteCaptures: Set<UUID> = []
    var controlExpiryTask: Task<Void, Never>?
    // Stable display-route identity survives session renames and is not an
    // agent credential. Native popup callbacks inherit it from the parent.
    private var manualRoutes: [String: (workspaceID: UUID, target: ManualBrowserTarget)] = [:]
    private var resolvePane: (@MainActor (Int32) async throws -> PaneInfo)?
    private let startRuntime: @MainActor (AgentBrowserService) throws -> any CXBrowserRuntime
    private var startupError: (any Error)?
    private var closing = false
    @Dependency(ExternalApplicationClient.self) private var externalApplication
    private let logger = Logger(label: "com.ctrlx.agent-browser")

    public override init() {
        self.startRuntime = Self.createAndStartRuntime
        super.init()
    }

    /// Tests inject the native boundary without starting Chromium or touching a profile.
    init(runtime: any CXBrowserRuntime, extensionStore: BrowserExtensionStore? = nil) {
        self.runtime = runtime
        self.extensionStore = extensionStore
        self.startRuntime = Self.createAndStartRuntime
        super.init()
    }

    init(startRuntime: @escaping @MainActor (AgentBrowserService) throws -> any CXBrowserRuntime) {
        self.startRuntime = startRuntime
        super.init()
    }

    func configure(resolvePane: @escaping @MainActor (Int32) async throws -> PaneInfo) {
        guard !closing else { return }
        self.resolvePane = resolvePane
    }

    static func stateDirectory(arguments: [String] = CommandLine.arguments) throws -> URL {
        if arguments.contains("--e2e-browser-mock-keychain"), !arguments.contains("--e2e-test") {
            throw ManualBrowserError.creation("Mock keychain requires an isolated E2E host.")
        }
        if arguments.contains("--e2e-test") {
            guard
                let index = arguments.firstIndex(of: "--ctrlx-state-root"),
                index + 1 < arguments.count else { throw ManualBrowserError.unavailable }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                .appendingPathComponent("agent-browser", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ctrlx/agent-browser", isDirectory: true)
    }

    private static func createAndStartRuntime(_ service: AgentBrowserService) throws -> any CXBrowserRuntime {
        guard let runtime = CXBrowserCreateRuntime() else {
            throw ManualBrowserError.creation(CXBrowserLoadError() ?? "The bundled Chromium runtime is unavailable.")
        }
        let fm = FileManager.default
        let state = try stateDirectory()
        let profile: URL
        if CommandLine.arguments.contains("--e2e-test") {
            let name = CommandLine.arguments.contains("--e2e-browser-mock-keychain")
                ? "browser-mock-profile" : "browser-profile"
            profile = state.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        } else {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            profile = support.appendingPathComponent("CtrlX/AgentBrowser", isDirectory: true)
        }
        for directory in [profile, state] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // CEF canonicalizes the root itself. Resolve /var ↔ /private/var for
        // both paths or Chromium silently disables persistent cookies.
        try runtime.start(
            with: service,
            profile: profile.resolvingSymlinksInPath().path,
            state: state.resolvingSymlinksInPath().path
        )
        service.extensionStore = BrowserExtensionStore(profile: profile)
        return runtime
    }

    func prepareForAgentRequests(state: String) async throws {
        let expected = try Self.stateDirectory().resolvingSymlinksInPath()
        guard URL(fileURLWithPath: state).resolvingSymlinksInPath().path == expected.path else {
            throw ManualBrowserError.creation("Browser state belongs to a different CtrlX host. No browser was started.")
        }
        try await ensureStarted()
    }

    func ensureStarted() async throws {
        try Task.checkCancellation()
        guard !closing else { throw ManualBrowserError.unavailable }
        if let startupError {
            throw startupError
        }
        if runtime == nil {
            guard resolvePane != nil else { throw ManualBrowserError.unavailable }
            do {
                runtime = try startRuntime(self)
            } catch {
                startupError = error
                logger.error("Agent Browser startup failed: \(error.localizedDescription)")
                throw error
            }
        }
        guard
            let runtime, runtime.responds(to: #selector(CXBrowserRuntime.isReady)),
            runtime.responds(to: #selector(CXBrowserRuntime.startupError)) else {
            throw ManualBrowserError.unavailable
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !runtime.isReady() {
            guard !closing else { throw ManualBrowserError.unavailable }
            if let message = runtime.startupError() {
                let error = ManualBrowserError.creation(message)
                startupError = error
                logger.error("Agent Browser startup failed: \(message)")
                throw error
            }
            guard ContinuousClock.now < deadline else {
                throw ManualBrowserError.creation("Chromium startup timed out. No page action was sent.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard !closing else { throw ManualBrowserError.unavailable }
    }

    func register(_ workspace: AgentBrowserWorkspace) {
        workspaces[workspace.id] = workspace
        reconcileWorkspaces()
        for tab in tabs.values where workspaces[tab.workspaceID] == nil && workspace.acceptsSession(tab.sessionName) {
            guard !routePanes.contains(where: { $0.paneId == tab.paneID }) else { continue }
            tab.workspaceID = workspace.id
            workspace.onCreate(tab, tab.parentID)
            workspace.onChange(tab)
        }
    }

    /// Display ownership follows the source pane, independently of native page lifetime.
    private func reconcileWorkspaces() {
        for tab in tabs.values where tab.manualTarget?.hostID == nil {
            guard let pane = routePanes.first(where: { $0.paneId == tab.paneID }) else { continue }
            movePresentation(tab, to: displayWorkspace(for: tab, pane: pane))
        }
    }

    private func displayWorkspace(for tab: AgentBrowserTabState, pane: PaneInfo) -> AgentBrowserWorkspace? {
        workspaces.values.first { $0.acceptsTab?(tab) == true }
            ?? workspaces.values.first { $0.acceptsTab == nil && $0.acceptsPane(pane) }
            ?? workspaces.values.first { $0.acceptsTab == nil && $0.acceptsSession(pane.sessionName) }
    }

    private func movePresentation(_ tab: AgentBrowserTabState, to workspace: AgentBrowserWorkspace?) {
        let id = workspace?.id ?? parkingID
        guard tab.workspaceID != id else { return }
        detachingTabs.insert(tab.identifier)
        workspaces[tab.workspaceID]?.onDetach(tab)
        detachingTabs.remove(tab.identifier)
        tab.workspaceID = id
        if let routeID = tab.manualRouteID, let route = manualRoutes[routeID] {
            manualRoutes[routeID] = (id, route.target)
        }
        park(tab)
        workspace?.onCreate(tab, tab.parentID)
        workspace?.onChange(tab)
    }

    func park(_ tab: AgentBrowserTabState) {
        guard !tab.isClosed, let root = parkingWindow.contentView else { return }
        tab.view.removeFromSuperview()
        tab.view.autoresizingMask = []
        tab.view.isHidden = false
        root.addSubview(tab.view)
    }

    /// All manual entry points use this Host-owned registry, including local UI.
    /// Coalesce creation only; each caller retains its own navigation intent.
    func openPaneBrowser(sessionName: String, paneID: String, url: URL? = nil, new: Bool = false) async throws -> AgentBrowserTabState {
        guard !closing, let resolveSourcePane else { throw ManualBrowserError.unavailable }
        try await ensureStarted()
        guard
            !closing, let runtime,
            runtime.responds(to: #selector(CXBrowserRuntime.openManualTab(route:url:completion:))) else {
            throw ManualBrowserError.unavailable
        }
        let destination: URL?
        if let url {
            guard let normalized = BrowserWebURL.normalized(url) else {
                throw ManualBrowserError.creation("Only HTTP and HTTPS links without embedded usernames or passwords can open in the Host browser.")
            }
            destination = normalized
        } else {
            destination = nil
        }
        let pane = try await resolveSourcePane(sessionName, paneID)
        try Task.checkCancellation()
        let tab: AgentBrowserTabState
        if new {
            tab = try await createPaneTab(pane, primary: false)
        } else if
            let existing = tabs.values.first(where: {
                !$0.isClosed && $0.owner.isEmpty && $0.manualTarget?.hostID == nil
                    && $0.paneID == paneID && $0.parentID == nil && $0.isPrimary
            }) {
            tab = existing
        } else if let opening = openingPaneTabs[paneID] {
            tab = try await opening.value
        } else {
            let opening = Task { try await self.createPaneTab(pane) }
            openingPaneTabs[paneID] = opening
            defer { openingPaneTabs.removeValue(forKey: paneID) }
            tab = try await opening.value
        }
        try Task.checkCancellation()
        guard !closing, !tab.isClosed else { throw ManualBrowserError.unavailable }
        let current = try await resolveSourcePane(sessionName, paneID)
        try Task.checkCancellation()
        guard !closing, !tab.isClosed else { throw ManualBrowserError.unavailable }
        updateRoute(tab, pane: current)
        if let destination, URL(string: tab.url).flatMap(BrowserWebURL.normalized) != destination {
            expireBrowserControls()
            guard remoteControls[tab.id] == nil else {
                throw ManualBrowserError.creation("This pane's browser is controlled by a Viewer. Release control before opening another link.")
            }
            tab.requestsInitialAddressFocus = false
            runtime.navigateTab(tab.identifier, url: destination.absoluteString)
        }
        return tab
    }

    func renameManualTabs(in workspace: AgentBrowserWorkspace, from old: ManualBrowserTarget, to new: ManualBrowserTarget) {
        if old.hostID == nil {
            renameHostSession(from: old.sessionName, to: new.sessionName)
            return
        }
        for (id, route) in manualRoutes where route.target == old && (old.hostID == nil || route.workspaceID == workspace.id) {
            manualRoutes[id] = (route.workspaceID, new)
        }
        for tab in tabs.values where tab.manualTarget == old && (old.hostID == nil || tab.workspaceID == workspace.id) {
            tab.manualTarget = new
            tab.sessionName = new.sessionName
        }
        publishBrowserTabs()
    }

    private func renameHostSession(from old: String, to new: String) {
        for (id, route) in manualRoutes where route.target.hostID == nil && route.target.sessionName == old {
            manualRoutes[id] = (route.workspaceID, ManualBrowserTarget(sessionName: new))
        }
        for tab in tabs.values where tab.manualTarget?.hostID == nil && tab.sessionName == old {
            tab.sessionName = new
            if tab.manualTarget != nil {
                tab.manualTarget = ManualBrowserTarget(sessionName: new)
            }
        }
        publishBrowserTabs()
    }

    func updateBrowserRoutes(_ panes: [PaneInfo]) {
        for rename in SessionRenameMapping.detect(from: routePanes, to: panes) {
            renameHostSession(from: rename.oldName, to: rename.newName)
        }
        routePanes = panes
        for tab in tabs.values where tab.manualTarget?.hostID == nil {
            let matches = panes.filter { $0.paneId == tab.paneID }
            guard matches.count == 1, let pane = matches.first else { continue }
            updateRoute(tab, pane: pane)
        }
    }

    private func updateRoute(_ tab: AgentBrowserTabState, pane: PaneInfo) {
        guard tab.sessionName != pane.sessionName || tab.windowID != pane.windowId else {
            movePresentation(tab, to: displayWorkspace(for: tab, pane: pane))
            return
        }
        let changesSession = tab.sessionName != pane.sessionName
        if changesSession {
            detachingTabs.insert(tab.identifier)
            workspaces[tab.workspaceID]?.onDetach(tab)
            detachingTabs.remove(tab.identifier)
        }
        tab.sessionName = pane.sessionName
        tab.windowID = pane.windowId
        if tab.manualTarget != nil {
            tab.manualTarget = ManualBrowserTarget(sessionName: pane.sessionName)
            if let routeID = tab.manualRouteID, let route = manualRoutes[routeID] {
                manualRoutes[routeID] = (route.workspaceID, ManualBrowserTarget(sessionName: pane.sessionName))
            }
        }
        if changesSession {
            tab.workspaceID = workspaces.values.first { $0.acceptsPane(pane) }?.id ?? parkingID
            if let workspace = workspaces[tab.workspaceID] {
                workspace.onCreate(tab, tab.parentID)
            } else {
                park(tab)
            }
        }
        workspaces[tab.workspaceID]?.onChange(tab)
        publishBrowserTabs()
    }

    func unregister(_ workspace: AgentBrowserWorkspace) {
        guard workspaces.removeValue(forKey: workspace.id) === workspace else { return }
        manualRoutes = manualRoutes.filter { $0.value.workspaceID != workspace.id || $0.value.target.hostID == nil }
        let ownedTabs = tabs.values.filter { $0.workspaceID == workspace.id }
        for tab in ownedTabs {
            if tab.manualTarget?.hostID == nil {
                detachingTabs.insert(tab.identifier)
                workspace.onDetach(tab)
                detachingTabs.remove(tab.identifier)
                tab.workspaceID = parkingID
                park(tab)
                continue
            }
            // Native close callbacks arrive later, after this workspace is no
            // longer registered. Retire the UI state now, otherwise a reused
            // SwiftUI workspace retains blank, already-closed browser tabs.
            tabs.removeValue(forKey: tab.identifier)
            tab.isClosed = true
            workspace.onClose(tab)
            runtime?.closeTab(tab.identifier)
        }
        reconcileWorkspaces()
    }

    public func resolveBrowserProcess(_ pid: Int32, completion: @escaping ([String: String]?, String?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, !self.closing, let resolvePane = self.resolvePane else {
                completion(nil, "CtrlX browser host is not ready.")
                return
            }
            do {
                let pane = try await resolvePane(pid)
                let candidates = self.workspaces.values.filter { $0.window != nil && $0.acceptsPane(pane) }
                let workspaceID = candidates.sorted { $0.id.uuidString < $1.id.uuidString }.first?.id ?? self.parkingID
                completion([
                    "workspace": workspaceID.uuidString,
                    "pane": pane.paneId,
                    "session": pane.sessionName,
                    "window": pane.windowId,
                ], nil)
            } catch { completion(nil, error.localizedDescription) }
        }
    }

    public func browserContainer(forRoute route: [String: String]) -> NSView? {
        guard !closing, route["session"] != nil, let root = parkingWindow.contentView else { return nil }
        // CEF requires a real native parent at creation. SwiftUI reparents this
        // SAME view into the selected tab on the next update; no new browser.
        let container = NSView(frame: root.bounds)
        container.autoresizingMask = []
        root.addSubview(container)
        return container
    }

    public func browserTabCreated(_ identifier: String, view: NSView, route: [String: String], owner: String, parent: String?) {
        guard
            let routedWorkspaceID = route["workspace"].flatMap(UUID.init(uuidString:)),
            let id = UUID(uuidString: identifier) else {
            runtime?.closeTab(identifier)
            return
        }
        let manualRouteID = route["manualRoute"]
        let registeredRoute = manualRouteID.flatMap { manualRoutes[$0] }
        let manualTarget = owner.isEmpty ? registeredRoute?.target : nil
        guard !closing, manualTarget != nil || (!owner.isEmpty && route["pane"] != nil) else {
            runtime?.closeTab(identifier)
            return
        }
        let paneID = parent.flatMap { tabs[$0]?.paneID } ?? route["pane"] ?? ""
        guard !paneID.isEmpty else { runtime?.closeTab(identifier)
            return
        }
        let workspaceID = parent.flatMap { tabs[$0]?.workspaceID } ?? routedWorkspaceID
        let state = AgentBrowserTabState(
            id: id,
            identifier: identifier,
            view: view,
            workspaceID: workspaceID,
            paneID: paneID,
            owner: owner,
            service: self,
            manualTarget: manualTarget,
            manualRouteID: manualRouteID
        )
        state.sessionName = manualTarget?.sessionName ?? parent.flatMap { tabs[$0]?.sessionName } ?? route["session"] ?? ""
        state.sourceAgent = parent.flatMap { tabs[$0]?.sourceAgent } ?? imageTargetForPane(paneID)
        state.windowID = parent.flatMap { tabs[$0]?.windowID } ?? route["window"]
        state.parentID = parent.flatMap(UUID.init(uuidString:))
        state.isExtensionWindow = route["presentation"] == "extensionWindow"
        state.isPrimary = parent == nil && route["primary"] != "false"
        state.suppressInitialSelection = (parent == nil && route["remote"] == "true")
            || parent.flatMap { tabs[$0]?.isRemotelyControlled } == true
        tabs[identifier] = state
        workspaces[workspaceID]?.onCreate(state, state.parentID)
        publishBrowserTabs()
    }

    public func browserTabChanged(_ identifier: String, title: String, url: String, loading: Bool) {
        guard let tab = tabs[identifier] else { return }
        if tab.title != title {
            tab.title = title
        }
        if tab.url != url {
            tab.url = url
        }
        if tab.isLoading != loading {
            tab.isLoading = loading
        }
        workspaces[tab.workspaceID]?.onChange(tab)
        publishBrowserTabs()
    }

    public func browserTabSelected(_ identifier: String) {
        guard let tab = tabs[identifier] else { return }
        if tab.suppressInitialSelection {
            tab.suppressInitialSelection = false
            return
        }
        guard !tab.isRemotelyControlled else { return }
        workspaces[tab.workspaceID]?.onSelect(tab)
    }

    public func browserTabClosed(_ identifier: String) {
        guard let tab = tabs.removeValue(forKey: identifier) else { return }
        if let routeID = tab.manualRouteID, !tabs.values.contains(where: { $0.manualRouteID == routeID }) {
            manualRoutes.removeValue(forKey: routeID)
        }
        tab.isClosed = true
        releaseBrowserControl(tab.id)
        workspaces[tab.workspaceID]?.onClose(tab)
        publishBrowserTabs()
    }

    public func browserTab(_ identifier: String, openExternalURL address: String, controlToken: String?) {
        guard
            !closing, let tab = tabs[identifier], !tab.isClosed,
            tab.manualTarget?.hostID == nil, let url = URL(string: address) else { return }
        // This callback is private to the native runtime. Recheck the Viewer
        // grant at the OS boundary, including expiry before its next sweep.
        let extensionLease = extensionControl.flatMap {
            $0.anchorID == tab.id || $0.pageID == tab.id ? $0.lease : nil
        }
        let lease = remoteControls[tab.id] ?? extensionLease
        if let controlToken {
            guard let lease, lease.id.uuidString == controlToken, lease.expires > .now else { return }
        } else if lease != nil {
            return
        }
        do {
            let name = try externalApplication.open(url)
            tab.externalApplicationNotice = BrowserExternalApplicationNotice(message: "Opened \(name) on the Host Mac.", isError: false)
        } catch {
            tab.externalApplicationNotice = BrowserExternalApplicationNotice(message: error.localizedDescription, isError: true)
        }
        publishBrowserTabs()
    }

    func navigate(_ tab: AgentBrowserTabState, url: String) {
        runtime?.navigateTab(tab.identifier, url: url)
    }

    func back(_ tab: AgentBrowserTabState) {
        runtime?.goBack(tab.identifier)
    }

    func forward(_ tab: AgentBrowserTabState) {
        runtime?.goForward(tab.identifier)
    }

    func reload(_ tab: AgentBrowserTabState) {
        runtime?.reloadTab(tab.identifier)
    }

    func showDevTools(_ tab: AgentBrowserTabState) {
        guard !closing, !tab.isClosed, tabs[tab.identifier] === tab else { return }
        runtime?.showDevTools(tab.identifier)
    }

    func openExtensionWindow(_ tab: AgentBrowserTabState) async throws -> AgentBrowserTabState {
        guard
            !closing, !tab.isClosed, !tab.isRemotelyControlled, tab.manualTarget?.hostID == nil, tabs[tab.identifier] === tab,
            let runtime, runtime.responds(to: #selector(CXBrowserRuntime.openExtensionWindow(forTab:completion:))) else {
            throw ManualBrowserError.creation("This page cannot open an extension window. Update the Host if this capability is unavailable.")
        }
        let identifier: String = try await withCheckedThrowingContinuation { continuation in
            runtime.openExtensionWindow?(forTab: tab.identifier) { identifier, error in
                if let error {
                    continuation.resume(throwing: ManualBrowserError.creation(error))
                } else if let identifier {
                    continuation.resume(returning: identifier)
                } else {
                    continuation.resume(throwing: ManualBrowserError.creation("Chromium did not return an extension window."))
                }
            }
        }
        guard !closing, let result = tabs[identifier], !result.isClosed, result.isExtensionWindow else {
            throw ManualBrowserError.creation("The extension window was closed before it could be opened.")
        }
        // Creating/selecting the associated workspace tab raises the main
        // window. Reveal Chromium after those callbacks have completed.
        showBrowserWindow(result)
        return result
    }

    func showExtensionManager(_ tab: AgentBrowserTabState) async throws {
        guard
            !closing, !tab.isClosed, !tab.isRemotelyControlled, tab.manualTarget?.hostID == nil, tabs[tab.identifier] === tab,
            let runtime, runtime.responds(to: #selector(CXBrowserRuntime.showExtensionManager(forTab:completion:))) else {
            throw ManualBrowserError.creation("Extension management is unavailable for this page. Update the Host if needed.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            runtime.showExtensionManager?(forTab: tab.identifier) { error in
                if let error {
                    continuation.resume(throwing: ManualBrowserError.creation(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func extensionRuntime(for tab: AgentBrowserTabState, controlID: UUID? = nil) throws -> any CXBrowserRuntime {
        if let controlID {
            guard
                let control = extensionControl, control.lease.id == controlID,
                control.anchorID == tab.id, control.lease.expires > .now else {
                throw RemoteBrowserError.message("Extension control expired. Take Control again.")
            }
        } else if extensionControl != nil || tab.isRemotelyControlled {
            throw RemoteBrowserError.message("A Viewer controls browser extensions. Take control back first.")
        }
        guard
            !closing, !tab.isClosed, tab.manualTarget?.hostID == nil,
            tabs[tab.identifier] === tab, let runtime,
            runtime.responds(to: #selector(CXBrowserRuntime.requestBrowserExtensions(forTab:request:completion:))) else {
            throw ManualBrowserError.creation("Extension management is unavailable for this page. Update the Host if needed.")
        }
        return runtime
    }

    func showBrowserWindow(_ tab: AgentBrowserTabState) {
        guard
            !closing, !tab.isClosed, !tab.isRemotelyControlled, tab.manualTarget?.hostID == nil,
            tabs[tab.identifier] === tab, tab.isExtensionWindow else { return }
        runtime?.showBrowserWindow?(tab.identifier)
    }

    func close(_ tab: AgentBrowserTabState) {
        guard !tab.isClosed, !detachingTabs.contains(tab.identifier) else { return }
        runtime?.closeTab(tab.identifier)
    }

    func shutdown() async {
        closing = true
        releaseExtensionControl()
        await extensionCleanupTask?.value
        extensionCleanupTask = nil
        publishTask?.cancel()
        publishTask = nil
        controlExpiryTask?.cancel()
        controlExpiryTask = nil
        remoteControls.removeAll()
        for opening in openingPaneTabs.values {
            opening.cancel()
        }
        openingPaneTabs.removeAll()
        guard let runtime else { return }
        runtime.beginShutdown()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !runtime.finishShutdown() {
            guard ContinuousClock.now < deadline else {
                logger.error("Chromium shutdown timed out; leaving framework loaded until process exit.")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        self.runtime = nil
        tabs.removeAll()
        manualRoutes.removeAll()
    }

    private func createPaneTab(_ pane: PaneInfo, primary: Bool = true) async throws -> AgentBrowserTabState {
        guard !closing, let runtime else { throw ManualBrowserError.unavailable }
        let sessionName = pane.sessionName
        let workspaceID = (workspaces.values.first { $0.acceptsPane(pane) }
            ?? workspaces.values.first { $0.acceptsTab == nil && $0.acceptsSession(sessionName) })?.id ?? parkingID
        let target = ManualBrowserTarget(sessionName: sessionName)
        let routeID = UUID().uuidString
        manualRoutes[routeID] = (workspaceID, target)
        var route = target.route(workspaceID: workspaceID)
        route["pane"] = pane.paneId
        route["window"] = pane.windowId
        route["manualRoute"] = routeID
        route["remote"] = "true"
        route["primary"] = primary ? "true" : "false"
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                runtime.openManualTab(route: route, url: "about:blank") { error in
                    if let error {
                        continuation.resume(throwing: ManualBrowserError.creation(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
            guard let tab = tabs.values.first(where: { $0.manualRouteID == routeID && $0.parentID == nil }) else {
                throw ManualBrowserError.creation("The browser page was closed while opening.")
            }
            return tab
        } catch {
            manualRoutes.removeValue(forKey: routeID)
            throw error
        }
    }
}

private enum ManualBrowserError: LocalizedError {
    case unavailable
    case creation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Host Chromium is unavailable. Restart the updated CtrlX app."
        case let .creation(message): message
        }
    }
}

@MainActor
final class AgentBrowserWorkspace {
    let id = UUID()
    weak var window: NSWindow?
    var acceptsPane: (PaneInfo) -> Bool = { _ in false }
    var acceptsTab: ((AgentBrowserTabState) -> Bool)?
    var acceptsSession: (String) -> Bool = { _ in false }
    var onCreate: (AgentBrowserTabState, UUID?) -> Void = { _, _ in }
    var onChange: (AgentBrowserTabState) -> Void = { _ in }
    var onSelect: (AgentBrowserTabState) -> Void = { _ in }
    var onClose: (AgentBrowserTabState) -> Void = { _ in }
    var onDetach: (AgentBrowserTabState) -> Void = { _ in }
}

@MainActor @Observable
final class AgentBrowserTabState {
    let id: UUID
    let identifier: String
    let view: NSView
    var workspaceID: UUID
    let paneID: String
    let owner: String
    let service: AgentBrowserService
    var manualTarget: ManualBrowserTarget?
    let manualRouteID: String?
    var requestsInitialAddressFocus: Bool
    var title = "Agent Browser"
    var url = "about:blank"
    var isLoading = false
    var isClosed = false
    var sessionName = ""
    var windowID: String?
    var parentID: UUID?
    var isPrimary = true
    var suppressInitialSelection = false
    var isRemotelyControlled = false
    var isExtensionWindow = false
    var sourceAgent: AgentImageTarget?
    var externalApplicationNotice: BrowserExternalApplicationNotice?

    init(
        id: UUID,
        identifier: String,
        view: NSView,
        workspaceID: UUID,
        paneID: String,
        owner: String,
        service: AgentBrowserService,
        manualTarget: ManualBrowserTarget? = nil,
        manualRouteID: String? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.view = view
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.owner = owner
        self.service = service
        self.manualTarget = manualTarget
        self.manualRouteID = manualRouteID
        self.requestsInitialAddressFocus = manualTarget != nil
    }
}
