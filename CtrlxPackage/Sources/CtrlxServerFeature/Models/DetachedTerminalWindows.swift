import AppKit
import CtrlxCommon
import CtrlxNetworking
import Observation

/// Presentation identity, independent of session names and tmux window indices.
public struct DetachedTerminalTarget: Hashable, Codable, Sendable {
    let hostID: String?
    let windowID: String

    init?(hostID: String?, windowID: String) {
        // An old Host without stable window IDs cannot safely support detachment.
        guard windowID.first == "@", Int(windowID.dropFirst()) != nil else { return nil }
        self.hostID = hostID
        self.windowID = windowID
    }
}

@MainActor
@Observable
final class DetachedTerminalWindows {
    enum Action: Equatable {
        case show
        case files(paneID: String?)
        case fork(paneID: String?, destination: AgentForkDestination)
        case fileLink(TerminalFileLinkRequest)
        case url(String, paneID: String)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let target: DetachedTerminalTarget
        let action: Action
    }

    private(set) var workspaces: [UUID: DetachedTerminalWorkspace] = [:]
    let mainTabs = WorkbenchTabStore()
    var mainSceneID = UUID()
    private(set) var presentationRevision = 0
    var targets: Set<DetachedTerminalTarget> {
        Set(workspaces.values.flatMap(\.members))
    }

    struct SourcePaneRequest {
        let id = UUID()
        let hostID: String?
        let pane: PaneState
    }

    var sourcePaneRequest: SourcePaneRequest?
    var mainRequest: Request?
    var restoredWindowIDs: [UUID] = []
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var restoredFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var restoredMainFrame: CGRect?
    @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var positions: [UUID: CGPoint] = [:]
    @ObservationIgnored private var closeObservers: [UUID: NSObjectProtocol] = [:]

    isolated deinit {
        for observer in closeObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func contains(hostID: String?, windowID: String) -> Bool {
        guard let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID) else { return false }
        return targets.contains(target)
    }

    /// Reserve ownership before SwiftUI creates the scene, so the main renderer retires first.
    @discardableResult
    func reserve(_ target: DetachedTerminalTarget, position: CGPoint? = nil) -> Bool {
        guard !targets.contains(target) else { return false }
        let workspace = DetachedTerminalWorkspace(target: target)
        workspaces[workspace.id] = workspace
        positions[workspace.id] = position
        return true
    }

    func workspace(containing target: DetachedTerminalTarget) -> DetachedTerminalWorkspace? {
        workspaces.values.first { $0.members.contains(target) }
    }

    func detach(_ target: DetachedTerminalTarget, position: CGPoint?, session: (DetachedTerminalTarget) -> String?) -> DetachedTerminalWorkspace? {
        guard let sessionName = session(target) else { return nil }
        let sourceID = workspace(containing: target)?.id
        let destination = DetachedTerminalWorkspace(target: target, sessionName: sessionName)
        destination.members = []
        workspaces[destination.id] = destination
        positions[destination.id] = position
        let drag = WorkbenchTabDrag(
            workspaceID: sourceID,
            hostID: target.hostID,
            sessionName: sessionName,
            tab: .window(target.windowID)
        )
        guard transfer(drag, to: destination.id, session: session) else {
            workspaces.removeValue(forKey: destination.id)
            positions.removeValue(forKey: destination.id)
            return nil
        }
        return destination
    }

    func detachSession(
        hostID: String?, name: String, windowIDs: [String], selectedWindowID: String?, position: CGPoint?,
        session: (DetachedTerminalTarget) -> String?,
    ) -> DetachedTerminalWorkspace? {
        let live = windowIDs.compactMap { DetachedTerminalTarget(hostID: hostID, windowID: $0) }
        guard !live.isEmpty, live.count == windowIDs.count, live.allSatisfy({ session($0) == name }) else { return nil }
        if let existing = workspaces.values.first(where: { $0.isSessionWindow && $0.anchor.hostID == hostID && $0.resolvedSession(using: session) == name }) {
            return existing
        }
        let members = live.filter { workspace(containing: $0) == nil }
        guard let anchor = members.first else {
            return live.first(where: { $0.windowID == selectedWindowID }).flatMap(workspace(containing:))
                ?? live.compactMap(workspace(containing:)).first
        }
        mainTabs.capturePresentation?()
        _ = mainTabs.tabs(hostID: hostID, session: name)
        let selection = WorkbenchTabStore.Selection(
            hostID: hostID, sessionName: name,
            windowID: members.first(where: { $0.windowID == selectedWindowID })?.windowID ?? anchor.windowID,
        )
        let destination = DetachedTerminalWorkspace(target: anchor, sessionName: name)
        destination.isSessionWindow = true
        destination.members = members
        workspaces[destination.id] = destination
        positions[destination.id] = position
        mainTabs.moveSession(hostID: hostID, session: name, to: destination.tabs, selection: selection)
        presentationRevision += 1
        return destination
    }

    /// Validate against live session metadata, never a drag payload's claimed session name.
    @discardableResult
    func merge(
        _ target: DetachedTerminalTarget,
        into workspaceID: UUID,
        session: (DetachedTerminalTarget) -> String?
    ) -> Bool {
        guard
            let destination = workspaces[workspaceID], target.hostID == destination.anchor.hostID,
            let sourceSession = session(target),
            destination.resolvedSession(using: session) == sourceSession else { return false }
        destination.sessionName = sourceSession
        if let old = workspace(containing: target), old !== destination {
            old.members.removeAll { $0 == target }
        }
        if !destination.members.contains(target) {
            destination.members.append(target)
        }
        destination.select(target)
        closeEmptyWorkspaces()
        return true
    }

    func returnToMain(_ target: DetachedTerminalTarget) {
        guard let workspace = workspace(containing: target) else { return }
        workspace.members.removeAll { $0 == target }
        closeEmptyWorkspaces()
    }

    func closeEmptyWorkspaces() {
        for workspace in workspaces.values where workspace.members.isEmpty && workspace.tabs.isEmpty {
            closeWorkspace(workspace.id)
        }
    }

    func store(for workspaceID: UUID?) -> WorkbenchTabStore? {
        if let workspaceID {
            return workspaces[workspaceID]?.tabs
        }
        return mainTabs
    }

    /// Migrate every owner before any scene reconciles a renamed browser catalog.
    func renameSession(hostID: String?, from oldName: String, to newName: String, windowIDs: [String: String]) {
        mainTabs.renameSession(hostID: hostID, from: oldName, to: newName, windowIDs: windowIDs)
        for workspace in workspaces.values {
            workspace.renameSession(hostID: hostID, from: oldName, to: newName, windowIDs: windowIDs)
        }
    }

    func owner(hostID: String?, windowID: String) -> UUID? {
        guard let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID) else { return nil }
        return workspace(containing: target)?.id
    }

    /// Project each Host tab once across this Mac's native windows; retain navigation when moving it.
    func syncFileTabs(hostID: String?, descriptors: [HostFileTab], sessionWindows: [String: [String]]) {
        let stores = [mainTabs] + workspaces.values.map(\.tabs)
        func sessions(_ store: WorkbenchTabStore) -> [String: SessionFileTabsState] {
            if let hostID {
                return Dictionary(uniqueKeysWithValues: store.remote.filter { $0.key.hostId == hostID }.map { ($0.key.sessionName, $0.value) })
            }
            return store.local
        }
        let live = Set(descriptors.map(\.id))
        var movedFrom: Set<ObjectIdentifier> = []
        for descriptor in descriptors {
            let existing = stores.flatMap { store in sessions(store).map { (store, $0.key, $0.value) } }
                .first { $0.2.directoryTabs[descriptor.id] != nil }
            let old = existing?.2.directoryTabs[descriptor.id]?.hostTab
            let destinationStore: WorkbenchTabStore
            if let existing, old?.sessionName == descriptor.sessionName, old?.windowID == descriptor.windowID {
                destinationStore = existing.0
            } else {
                destinationStore = store(for: owner(hostID: hostID, windowID: descriptor.windowID)) ?? mainTabs
            }
            let destination = destinationStore.tabs(hostID: hostID, session: descriptor.sessionName)
            if let existing, existing.2 !== destination {
                existing.2.move(.file(descriptor.id), to: destination)
                movedFrom.insert(ObjectIdentifier(existing.2))
            }
            if let tab = destination.directoryTabs[descriptor.id] {
                tab.updateHostTab(descriptor)
            } else {
                destination.directoryTabs[descriptor.id] = FileBrowserTab(hostTab: descriptor)
                destination.openFileTabs.append(.init(id: descriptor.id, path: "Files", directoryPath: "", isDirectory: true))
            }
        }
        for store in stores {
            for (session, tabs) in sessions(store) {
                let removed = tabs.directoryTabs.values.filter { $0.hostTab != nil && !live.contains($0.id) }
                for tab in removed {
                    tabs.removeFileTab(tab.id)
                }
                guard !removed.isEmpty || movedFrom.contains(ObjectIdentifier(tabs)) else { continue }
                let ids = (sessionWindows[session] ?? []).filter { id in
                    self.store(for: owner(hostID: hostID, windowID: id)) === store
                }
                tabs.reconcileRightPaneSelection(sessionWindowIDs: ids, includeLocalTabs: hostID == nil)
                tabs.repairLeftContent(hasTerminal: ids.contains { !tabs.rightSide.contains(.window($0)) })
            }
        }
    }

    func claimFile(_ id: UUID, hostID: String?, session: String, workspaceID: UUID?) {
        guard let destination = store(for: workspaceID)?.tabs(hostID: hostID, session: session) else { return }
        for store in [mainTabs] + workspaces.values.map(\.tabs) {
            guard
                let source = store.existing(hostID: hostID, session: session), source !== destination,
                source.directoryTabs[id] != nil else { continue }
            if source.move(.file(id), to: destination) {
                presentationRevision += 1
                closeEmptyWorkspaces()
            }
        }
    }

    func browserOwner(hostID: String?, session: String, id: UUID, windowID: String?) -> UUID? {
        for workspace in workspaces.values where workspace.anchor.hostID == hostID {
            if workspace.tabs.existing(hostID: hostID, session: session)?.openBrowserTabs.contains(where: { $0.id == id }) == true {
                return workspace.id
            }
        }
        if mainTabs.existing(hostID: hostID, session: session)?.openBrowserTabs.contains(where: { $0.id == id }) == true {
            return nil
        }
        return windowID.flatMap { owner(hostID: hostID, windowID: $0) }
    }

    /// Simulator tabs follow their source terminal and cannot move independently.
    func simulatorTabs(_ catalog: [RemoteSimulatorTab], hostID: String, session: String, workspaceID: UUID?) -> [RemoteSimulatorTab] {
        catalog.filter {
            $0.sessionName == session && owner(hostID: hostID, windowID: $0.windowID) == workspaceID
        }
    }

    @discardableResult
    func transfer(_ drag: WorkbenchTabDrag, to destinationID: UUID?, session: (DetachedTerminalTarget) -> String?) -> Bool {
        guard
            drag.workspaceID != destinationID,
            let sourceStore = store(for: drag.workspaceID), let destinationStore = store(for: destinationID) else { return false }
        if let destinationID {
            guard
                let group = workspaces[destinationID], group.anchor.hostID == drag.hostID,
                group.resolvedSession(using: session) == drag.sessionName else { return false }
            group.sessionName = drag.sessionName
        }
        let source = sourceStore.tabs(hostID: drag.hostID, session: drag.sessionName)
        let destination = destinationStore.tabs(hostID: drag.hostID, session: drag.sessionName)
        if case let .window(id) = drag.tab {
            guard
                let target = DetachedTerminalTarget(hostID: drag.hostID, windowID: id),
                session(target) == drag.sessionName, owner(hostID: drag.hostID, windowID: id) == drag.workspaceID else { return false }
            if let old = workspace(containing: target) {
                old.members.removeAll { $0 == target }
            }
            if let destinationID {
                workspaces[destinationID]?.members.append(target)
            }
        }
        guard source.move(drag.tab, to: destination) else { return false }
        if let destinationID, let group = workspaces[destinationID] {
            group.selection = drag.tab
            group.selectionRevision += 1
        }
        presentationRevision += 1
        closeEmptyWorkspaces()
        return true
    }

    private func closeWorkspace(_ id: UUID) {
        if let window = windows[id] {
            window.performClose(nil)
        } else if let workspace = workspaces.removeValue(forKey: id) {
            let close = workspace.onClose
            workspace.onClose = { }
            close()
        }
    }

    func attach(_ window: NSWindow, to target: DetachedTerminalTarget) {
        guard let workspace = workspace(containing: target) else { return }
        attach(window, toWorkspace: workspace.id)
    }

    func attach(_ window: NSWindow, toWorkspace id: UUID?) {
        guard let id else {
            mainWindow = window
            return
        }
        guard workspaces[id] != nil, windows[id] !== window else { return }
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows[id] = window
        if let frame = restoredFrames.removeValue(forKey: id) {
            Self.restoreFrame(frame, to: window)
        }
        closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.didCloseWorkspace(id, window: window)
            }
        }
        if let position = positions.removeValue(forKey: id) {
            let screen = NSScreen.screens.first { $0.frame.contains(position) } ?? window.screen
            if let screen {
                let origin = Self.clampedOrigin(
                    CGPoint(x: position.x - 100, y: position.y - window.frame.height + 20),
                    size: window.frame.size, visibleFrame: screen.visibleFrame
                )
                window.setFrameOrigin(origin)
            }
        }
    }

    func didClose(_ target: DetachedTerminalTarget, window: NSWindow) {
        guard let workspace = workspace(containing: target) else { return }
        didCloseWorkspace(workspace.id, window: window)
    }

    private func didCloseWorkspace(_ id: UUID, window: NSWindow) {
        guard windows[id] === window else { return }
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows.removeValue(forKey: id)
        positions.removeValue(forKey: id)
        workspaces[id]?.tabs.capturePresentation?()
        guard let workspace = workspaces.removeValue(forKey: id) else { return }
        for (session, tabs) in workspace.tabs.local {
            if workspace.isSessionWindow {
                let selection = mainTabs.recoverySelection.flatMap { $0.hostID == nil && $0.sessionName == session ? workspace.tabs.recoverySelection : nil }
                workspace.tabs.moveSession(hostID: nil, session: session, to: mainTabs, selection: selection)
            } else {
                returnTabs(tabs, to: mainTabs.tabs(hostID: nil, session: session))
            }
        }
        for (key, tabs) in workspace.tabs.remote {
            if workspace.isSessionWindow {
                let selection = mainTabs.recoverySelection.flatMap { $0.hostID == key.hostId && $0.sessionName == key.sessionName ? workspace.tabs.recoverySelection : nil }
                workspace.tabs.moveSession(hostID: key.hostId, session: key.sessionName, to: mainTabs, selection: selection)
            } else {
                returnTabs(tabs, to: mainTabs.tabs(hostID: key.hostId, session: key.sessionName))
            }
        }
        let close = workspace.onClose
        workspace.onClose = { }
        close()
        presentationRevision += 1
    }

    private func returnTabs(_ source: SessionFileTabsState, to destination: SessionFileTabsState) {
        for tab in source.openFileTabs {
            source.move(.file(tab.id), to: destination)
        }
        for tab in source.openBrowserTabs {
            source.move(.browser(tab.id), to: destination)
        }
    }

    @discardableResult
    func focus(hostID: String?, windowID: String) -> Bool {
        guard
            let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID),
            let workspace = workspace(containing: target) else { return false }
        workspace.select(target)
        focusNativeWindow(workspaceID: workspace.id)
        return true
    }

    /// Resolve ownership when the notification is opened, not when it was delivered.
    func reveal(
        _ selection: PendingMenuBarSelection,
        localPanes: [PaneInfo], remoteSessions: SessionStore?,
        openMain: () -> Void
    ) -> UUID? {
        let hostID: String?
        let windowID: String?
        switch selection {
        case let .local(paneID):
            hostID = nil
            windowID = localPanes.first { $0.paneId == paneID }?.stableWindowId
        case let .remote(host, _, paneID):
            hostID = host
            windowID = remoteSessions?.paneState(for: paneID, hostId: host)?.stableWindowId
        }
        if let windowID, focus(hostID: hostID, windowID: windowID) {
            return owner(hostID: hostID, windowID: windowID)
        }
        openMain()
        return nil
    }

    /// Activation retries must not reselect tabs or bring unrelated windows forward.
    @discardableResult
    func focusNativeWindow(workspaceID: UUID?, activate: () -> Void = { }) -> Bool {
        let window = if let workspaceID {
            windows[workspaceID]
        } else {
            mainWindow
        }
        guard let window else { return false }
        activate()
        // A disconnected display must not strand the window off-screen.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }

    func close(_ target: DetachedTerminalTarget) {
        returnToMain(target)
    }

    func request(_ action: Action, from target: DetachedTerminalTarget) {
        mainRequest = Request(target: target, action: action)
    }

    static func clampedOrigin(_ origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width)),
            y: max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        )
    }

    static func restoreFrame(_ frame: CGRect, to window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else { return }
        let size = CGSize(width: min(max(400, frame.width), screen.visibleFrame.width), height: min(max(250, frame.height), screen.visibleFrame.height))
        window.setFrame(CGRect(origin: clampedOrigin(frame.origin, size: size, visibleFrame: screen.visibleFrame), size: size), display: true)
    }

    var mainFrame: CGRect? {
        restoredMainFrame ?? mainWindow?.frame
    }

    func restoreMainFrame(_ frame: CGRect) {
        restoredMainFrame = frame
        applyRestoredMainFrame()
    }

    func applyRestoredMainFrame() {
        // SwiftUI applies its initial window size when ordering the window on
        // screen. Keep the saved frame until that initial presentation finishes.
        guard let window = mainWindow, window.isVisible, let frame = restoredMainFrame else { return }
        restoredMainFrame = nil
        Self.restoreFrame(frame, to: window)
    }

    func frame(for workspaceID: UUID) -> CGRect? {
        windows[workspaceID]?.frame ?? restoredFrames[workspaceID]
    }

    func restoreWorkspace(id: UUID, members: [DetachedTerminalTarget], session: String, frame: CGRect?, fallbackAnchor: DetachedTerminalTarget? = nil) -> DetachedTerminalWorkspace? {
        if let existing = workspaces[id] {
            return existing
        }
        guard let anchor = members.first ?? fallbackAnchor, members.allSatisfy({ !targets.contains($0) }) else { return nil }
        let workspace = DetachedTerminalWorkspace(id: id, target: anchor, sessionName: session)
        workspace.members = members
        workspaces[id] = workspace
        restoredFrames[id] = frame
        restoredWindowIDs.append(id)
        return workspace
    }

    /// A returning right-side tab must not also become the left renderer.
    static func mainSelection(target: String, windows: [(stableID: String, id: String)], rightSide: Set<String>) -> String? {
        if !rightSide.contains(target) {
            return windows.first { $0.stableID == target }?.id
        }
        return windows.first { !rightSide.contains($0.stableID) }?.id
    }
}
