import AppKit
import CtrlxBrowserBridge
import CtrlxNetworking
import Foundation
import Logging
import Observation

/// Display routing for human tabs, independent of local tmux pane/process IDs.
/// Remote sessions still create pages on THIS Mac; hostID only identifies UI.
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
/// representations; authority (Codex run) is distinct from UI routing (pane).
@MainActor
public final class AgentBrowserService: NSObject, @preconcurrency CXBrowserHostDelegate {
    public static func prepareApplication() { _ = CXBrowserPrepareApplication() }

    var runtime: (any CXBrowserRuntime)?
    private var workspaces: [UUID: AgentBrowserWorkspace] = [:]
    private(set) var tabs: [String: AgentBrowserTabState] = [:]
    private let parkingID = UUID()
    private lazy var parkingWindow: NSWindow = {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                        styleMask: .borderless, backing: .buffered, defer: false)
    }()
    var onTabsChanged: (() -> Void)?
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
    private var closing = false
    private let logger = Logger(label: "com.ctrlx.agent-browser")

    public override init() { super.init() }

    // Tests inject the native boundary without starting Chromium or touching a profile.
    init(runtime: any CXBrowserRuntime) {
        self.runtime = runtime
        super.init()
    }

    func start(resolvePane: @escaping @MainActor (Int32) async throws -> PaneInfo) {
        guard runtime == nil, !closing else { return }
        self.resolvePane = resolvePane
        guard let runtime = CXBrowserCreateRuntime() else {
            if let error = CXBrowserLoadError() { logger.error("Agent Browser unavailable: \(error)") }
            return
        }
        do {
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var profile = support.appendingPathComponent("CtrlX/AgentBrowser", isDirectory: true)
            var state = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ctrlx/agent-browser", isDirectory: true)
            // Existing E2E isolation must also isolate browser cookies, IPC and
            // grants. A second test app must never take the user's profile lock.
            if CommandLine.arguments.contains("--e2e-test") {
                guard let index = CommandLine.arguments.firstIndex(of: "--ctrlx-state-root"),
                      index + 1 < CommandLine.arguments.count else { return }
                let root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                profile = root.appendingPathComponent("browser-profile", isDirectory: true)
                state = root.appendingPathComponent("agent-browser", isDirectory: true)
            }
            for directory in [profile, state] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // CEF canonicalizes the root itself. Resolve /var ↔ /private/var for
            // both paths or Chromium silently disables persistent cookies.
            self.runtime = runtime
            try runtime.start(with: self, profile: profile.resolvingSymlinksInPath().path,
                              state: state.resolvingSymlinksInPath().path)
        } catch {
            self.runtime = nil
            logger.error("Agent Browser startup failed: \(error.localizedDescription)")
        }
    }

    func register(_ workspace: AgentBrowserWorkspace) {
        workspaces[workspace.id] = workspace
        for tab in tabs.values where workspaces[tab.workspaceID] == nil && workspace.acceptsSession(tab.sessionName) {
            tab.workspaceID = workspace.id
            workspace.onCreate(tab, tab.parentID)
            workspace.onChange(tab)
        }
    }

    func park(_ tab: AgentBrowserTabState) {
        guard !tab.isClosed, let root = parkingWindow.contentView else { return }
        tab.view.removeFromSuperview()
        tab.view.autoresizingMask = []
        tab.view.isHidden = false
        root.addSubview(tab.view)
    }

    func openManualTab(in workspace: AgentBrowserWorkspace, target: ManualBrowserTarget) async throws {
        guard !closing, let runtime, workspaces[workspace.id] === workspace else {
            throw ManualBrowserError.unavailable
        }
        // Older optional native runtimes must fail visibly, never crash on a
        // missing selector or silently open a WebKit tab under this preference.
        guard runtime.responds(to: #selector(CXBrowserRuntime.openManualTab(route:url:completion:))) else {
            throw ManualBrowserError.unavailable
        }
        let routeID = UUID().uuidString
        manualRoutes[routeID] = (workspace.id, target)
        var route = target.route(workspaceID: workspace.id)
        route["manualRoute"] = routeID
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                runtime.openManualTab(route: route, url: "about:blank") { error in
                    if let error { continuation.resume(throwing: ManualBrowserError.creation(error)) }
                    else { continuation.resume() }
                }
            }
        } catch {
            manualRoutes.removeValue(forKey: routeID)
            throw error
        }
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
            if tab.manualTarget != nil { tab.manualTarget = ManualBrowserTarget(sessionName: new) }
        }
        publishBrowserTabs()
    }

    func updateBrowserRoutes(_ panes: [PaneInfo]) {
        for rename in SessionRenameMapping.detect(from: routePanes, to: panes) {
            renameHostSession(from: rename.oldName, to: rename.newName)
        }
        routePanes = panes
        for tab in tabs.values where tab.manualTarget == nil {
            guard let pane = panes.first(where: { $0.paneId == tab.paneID }),
                  tab.sessionName != pane.sessionName || tab.windowID != pane.windowId else { continue }
            tab.sessionName = pane.sessionName
            tab.windowID = pane.windowId
            publishBrowserTabs()
        }
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
    }

    public func resolveBrowserProcess(_ pid: Int32, completion: @escaping ([String: String]?, String?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, !self.closing, let resolvePane = self.resolvePane else {
                completion(nil, "CtrlX browser host is not ready."); return
            }
            do {
                let pane = try await resolvePane(pid)
                let candidates = self.workspaces.values.filter { $0.window != nil && $0.acceptsPane(pane) }
                let workspaceID = candidates.sorted { $0.id.uuidString < $1.id.uuidString }.first?.id ?? self.parkingID
                completion(["workspace": workspaceID.uuidString, "pane": pane.paneId,
                            "session": pane.sessionName, "window": pane.windowId], nil)
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
        guard let routedWorkspaceID = route["workspace"].flatMap(UUID.init(uuidString:)),
              let id = UUID(uuidString: identifier) else {
            runtime?.closeTab(identifier); return
        }
        let manualRouteID = route["manualRoute"]
        let registeredRoute = manualRouteID.flatMap { manualRoutes[$0] }
        let manualTarget = owner.isEmpty ? registeredRoute?.target : nil
        guard !closing, manualTarget != nil || (!owner.isEmpty && route["pane"] != nil) else {
            runtime?.closeTab(identifier); return
        }
        let paneID = route["pane"] ?? ""
        let workspaceID = parent.flatMap { tabs[$0]?.workspaceID } ?? routedWorkspaceID
        let state = AgentBrowserTabState(id: id, identifier: identifier, view: view,
            workspaceID: workspaceID, paneID: paneID, owner: owner, service: self,
            manualTarget: manualTarget, manualRouteID: manualRouteID)
        state.sessionName = manualTarget?.sessionName ?? parent.flatMap { tabs[$0]?.sessionName } ?? route["session"] ?? ""
        state.windowID = parent.flatMap { tabs[$0]?.windowID } ?? route["window"]
        state.parentID = parent.flatMap(UUID.init(uuidString:))
        state.suppressInitialSelection = route["remote"] == "true"
            || parent.flatMap { tabs[$0]?.isRemotelyControlled } == true
        tabs[identifier] = state
        workspaces[workspaceID]?.onCreate(state, state.parentID)
        publishBrowserTabs()
    }

    public func browserTabChanged(_ identifier: String, title: String, url: String, loading: Bool) {
        guard let tab = tabs[identifier] else { return }
        if tab.title != title { tab.title = title }
        if tab.url != url { tab.url = url }
        if tab.isLoading != loading { tab.isLoading = loading }
        workspaces[tab.workspaceID]?.onChange(tab)
        publishBrowserTabs()
    }
    public func browserTabSelected(_ identifier: String) {
        guard let tab = tabs[identifier] else { return }
        if tab.suppressInitialSelection { tab.suppressInitialSelection = false; return }
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
    func navigate(_ tab: AgentBrowserTabState, url: String) { runtime?.navigateTab(tab.identifier, url: url) }
    func back(_ tab: AgentBrowserTabState) { runtime?.goBack(tab.identifier) }
    func forward(_ tab: AgentBrowserTabState) { runtime?.goForward(tab.identifier) }
    func reload(_ tab: AgentBrowserTabState) { runtime?.reloadTab(tab.identifier) }
    func showDevTools(_ tab: AgentBrowserTabState) {
        guard !closing, !tab.isClosed, tabs[tab.identifier] === tab else { return }
        runtime?.showDevTools(tab.identifier)
    }
    func close(_ tab: AgentBrowserTabState) {
        guard !tab.isClosed, !detachingTabs.contains(tab.identifier) else { return }
        runtime?.closeTab(tab.identifier)
    }

    func shutdown() async {
        closing = true
        publishTask?.cancel()
        publishTask = nil
        controlExpiryTask?.cancel()
        controlExpiryTask = nil
        remoteControls.removeAll()
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

    func createSharedTab(sessionName: String) async throws -> AgentBrowserTabState {
        guard !closing, let runtime else { throw ManualBrowserError.unavailable }
        let workspaceID = workspaces.values.first { $0.acceptsSession(sessionName) }?.id ?? parkingID
        let target = ManualBrowserTarget(sessionName: sessionName)
        let routeID = UUID().uuidString
        manualRoutes[routeID] = (workspaceID, target)
        var route = target.route(workspaceID: workspaceID)
        route["manualRoute"] = routeID
        route["remote"] = "true"
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                runtime.openManualTab(route: route, url: "about:blank") { error in
                    if let error { continuation.resume(throwing: ManualBrowserError.creation(error)) }
                    else { continuation.resume() }
                }
            }
            guard let tab = tabs.values.first(where: { $0.manualRouteID == routeID }) else {
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
        case .unavailable: "Chromium is unavailable. Restart the updated CtrlX app or choose WebKit in Settings > Browser."
        case let .creation(message): message
        }
    }
}

@MainActor
final class AgentBrowserWorkspace {
    let id = UUID()
    weak var window: NSWindow?
    var acceptsPane: (PaneInfo) -> Bool = { _ in false }
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
    var suppressInitialSelection = false
    var isRemotelyControlled = false

    init(id: UUID, identifier: String, view: NSView, workspaceID: UUID, paneID: String,
         owner: String, service: AgentBrowserService, manualTarget: ManualBrowserTarget? = nil, manualRouteID: String? = nil) {
        self.id = id; self.identifier = identifier; self.view = view
        self.workspaceID = workspaceID; self.paneID = paneID; self.owner = owner; self.service = service
        self.manualTarget = manualTarget
        self.manualRouteID = manualRouteID
        self.requestsInitialAddressFocus = manualTarget != nil
    }
}
