import AppKit
import CtrlxBrowserBridge
import CtrlxNetworking
import Foundation
import Logging
import Observation

/// One Chromium runtime per CtrlX process. Page state outlives SwiftUI tab
/// representations; authority (Codex run) is distinct from UI routing (pane).
@MainActor
public final class AgentBrowserService: NSObject, @preconcurrency CXBrowserHostDelegate {
    public static func prepareApplication() { _ = CXBrowserPrepareApplication() }

    private var runtime: (any CXBrowserRuntime)?
    private var workspaces: [UUID: AgentBrowserWorkspace] = [:]
    private var tabs: [String: AgentBrowserTabState] = [:]
    private var resolvePane: (@MainActor (Int32) async throws -> PaneInfo)?
    private var closing = false
    private let logger = Logger(label: "com.ctrlx.agent-browser")

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

    func register(_ workspace: AgentBrowserWorkspace) { workspaces[workspace.id] = workspace }
    func unregister(_ workspace: AgentBrowserWorkspace) {
        workspaces.removeValue(forKey: workspace.id)
        let ownedTabs = tabs.values.filter { $0.workspaceID == workspace.id }
        for tab in ownedTabs { close(tab) }
    }

    public func resolveBrowserProcess(_ pid: Int32, completion: @escaping ([String: String]?, String?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, !self.closing, let resolvePane = self.resolvePane else {
                completion(nil, "CtrlX browser host is not ready."); return
            }
            do {
                let pane = try await resolvePane(pid)
                let candidates = self.workspaces.values.filter { $0.window != nil && $0.acceptsPane(pane) }
                guard candidates.count == 1, let workspace = candidates.first else {
                    completion(nil, candidates.isEmpty
                        ? "Open the source session in CtrlX on this Mac first. No browser window was opened."
                        : "The source session has multiple CtrlX workspaces. Close the duplicate view before opening a browser tab.")
                    return
                }
                completion(["workspace": workspace.id.uuidString, "pane": pane.paneId,
                            "session": pane.sessionName, "window": pane.windowId], nil)
            } catch { completion(nil, error.localizedDescription) }
        }
    }

    public func browserContainer(forRoute route: [String: String]) -> NSView? {
        guard !closing, let id = route["workspace"].flatMap(UUID.init(uuidString:)),
              let workspace = workspaces[id], let root = workspace.window?.contentView else { return nil }
        // CEF requires a real native parent at creation. SwiftUI reparents this
        // SAME view into the selected tab on the next update; no new browser.
        let container = NSView(frame: root.bounds)
        container.isHidden = true
        root.addSubview(container)
        return container
    }

    public func browserTabCreated(_ identifier: String, view: NSView, route: [String: String], owner: String, parent: String?) {
        guard let workspaceID = route["workspace"].flatMap(UUID.init(uuidString:)),
              let paneID = route["pane"], let workspace = workspaces[workspaceID],
              let id = UUID(uuidString: identifier) else {
            runtime?.closeTab(identifier); return
        }
        let state = AgentBrowserTabState(id: id, identifier: identifier, view: view,
            workspaceID: workspaceID, paneID: paneID, owner: owner, service: self)
        tabs[identifier] = state
        workspace.onCreate(state, parent.flatMap(UUID.init(uuidString:)))
    }

    public func browserTabChanged(_ identifier: String, title: String, url: String, loading: Bool) {
        guard let tab = tabs[identifier] else { return }
        if tab.title != title { tab.title = title }
        if tab.url != url { tab.url = url }
        if tab.isLoading != loading { tab.isLoading = loading }
        workspaces[tab.workspaceID]?.onChange(tab)
    }
    public func browserTabSelected(_ identifier: String) {
        guard let tab = tabs[identifier] else { return }
        workspaces[tab.workspaceID]?.onSelect(tab)
    }
    public func browserTabClosed(_ identifier: String) {
        guard let tab = tabs.removeValue(forKey: identifier) else { return }
        tab.isClosed = true
        workspaces[tab.workspaceID]?.onClose(tab)
    }
    func navigate(_ tab: AgentBrowserTabState, url: String) { runtime?.navigateTab(tab.identifier, url: url) }
    func back(_ tab: AgentBrowserTabState) { runtime?.goBack(tab.identifier) }
    func forward(_ tab: AgentBrowserTabState) { runtime?.goForward(tab.identifier) }
    func reload(_ tab: AgentBrowserTabState) { runtime?.reloadTab(tab.identifier) }
    func close(_ tab: AgentBrowserTabState) {
        guard !tab.isClosed else { return }
        runtime?.closeTab(tab.identifier)
    }

    func shutdown() async {
        closing = true
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
    }
}

@MainActor
final class AgentBrowserWorkspace {
    let id = UUID()
    weak var window: NSWindow?
    var acceptsPane: (PaneInfo) -> Bool = { _ in false }
    var onCreate: (AgentBrowserTabState, UUID?) -> Void = { _, _ in }
    var onChange: (AgentBrowserTabState) -> Void = { _ in }
    var onSelect: (AgentBrowserTabState) -> Void = { _ in }
    var onClose: (AgentBrowserTabState) -> Void = { _ in }
}

@MainActor @Observable
final class AgentBrowserTabState {
    let id: UUID
    let identifier: String
    let view: NSView
    let workspaceID: UUID
    let paneID: String
    let owner: String
    let service: AgentBrowserService
    var title = "Agent Browser"
    var url = "about:blank"
    var isLoading = false
    var isClosed = false

    init(id: UUID, identifier: String, view: NSView, workspaceID: UUID, paneID: String,
         owner: String, service: AgentBrowserService) {
        self.id = id; self.identifier = identifier; self.view = view
        self.workspaceID = workspaceID; self.paneID = paneID; self.owner = owner; self.service = service
    }
}
