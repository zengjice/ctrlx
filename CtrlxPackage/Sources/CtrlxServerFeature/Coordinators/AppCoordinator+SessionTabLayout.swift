import CtrlxNetworking
import Foundation

extension AppCoordinator {
    var sharedSessionTabLayouts: [UUID: SessionTabLayout] {
        Dictionary(uniqueKeysWithValues: sessionTabCatalogs.map { sessionID, catalog in
            (sessionID, sessionTabLayouts.snapshot(sessionID: sessionID, catalog: catalog))
        })
    }

    func editSessionTabLayout(_ request: EditSessionTabLayout) async throws {
        let session = try resourceSessions.resolve(request.sessionID)
        let sources: [SessionTabID]
        switch request.edit {
        case let .moveGroup(ids, _, _, _): sources = ids
        case let .move(id, _, _),
             let .moveToEnd(id, _, _),
             let .group(id, _): sources = [id]
        default: sources = []
        }
        let sourceWindows = sources.filter {
            if case .window = $0 {
                true
            } else {
                false
            }
        }
        let windows = tmuxService.windows.filter { $0.sessionName == session.name }
        let routes = Dictionary(windows.compactMap { window in
            window.panes.first?.workspaceIdentity.flatMap { identity in
                identity.sessionID == session.id ? (SessionTabID.window(identity.windowID), window.stableId) : nil
            }
        }, uniquingKeysWith: { first, _ in first })
        var original = windows.map(\.stableId)
        let identity = windows.lazy.compactMap { $0.panes.first?.workspaceIdentity }.first { $0.sessionID == session.id }
        if !sourceWindows.isEmpty {
            guard let identity else { throw TmuxError.invalidWindowOrder(reason: "the session has changed") }
            original = try await tmuxService.currentWindowOrder(in: session.name, expectedWorkspacePane: identity)
            guard Set(original) == Set(routes.values) else {
                throw TmuxError.invalidWindowOrder(reason: "the session's windows have changed; refresh the tabs")
            }
        }
        let sourcePanes = Dictionary(
            hostFileTabs.tabs.compactMap { tab in tab.sourcePaneID.map { (SessionTabID.file(tab.id), $0) } }
                + agentBrowser.sharedBrowserTabs.compactMap { tab in tab.sourcePaneID.map { (SessionTabID.browser(tab.id), $0) } }
                + agentSimulator.sharedSimulatorTabs.compactMap { tab in tab.sourcePaneID.map { (SessionTabID.browser(tab.id), $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let baseCatalog = sessionTabCatalogs[request.sessionID] ?? []
        let idsByRoute = Dictionary(routes.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let catalog = sourceWindows.isEmpty ? baseCatalog : original.compactMap { idsByRoute[$0] } + baseCatalog.filter {
            if case .window = $0 {
                false
            } else {
                true
            }
        }
        let paneOrder = original.flatMap { route in windows.first { $0.stableId == route }?.panes.map(\.paneId) ?? [] }
        try await sessionTabLayouts.apply(request, catalog: catalog, sourcePanes: sourcePanes, paneOrder: paneOrder) { layout in
            guard !sourceWindows.isEmpty else { return nil }
            let visible = request.visibleWindows.map(Set.init) ?? Set(routes.keys)
            guard sourceWindows.allSatisfy(visible.contains), visible.isSubset(of: Set(routes.keys)) else {
                throw TmuxError.invalidWindowOrder(reason: "the workbench window set has changed")
            }
            let desired = layout.order.filter(visible.contains).compactMap { routes[$0] }
            guard let order = TabDragPayload.mergingWindowOrder(desired, into: original) else {
                throw TmuxError.invalidWindowOrder(reason: "the workbench window order is invalid")
            }
            if order != original {
                guard let identity else {
                    throw TmuxError.invalidWindowOrder(reason: "the session has changed")
                }
                try await tmuxService.moveWindows(in: session.name, to: order, expectedWorkspacePane: identity, expectedOrder: original)
                windowManager.updatePaneStates(from: await tmuxService.refreshPanes())
            }
            guard request.visibleWindows != nil else { return nil }
            let ids = Dictionary(routes.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            return order.compactMap { ids[$0] }
        }
        await connectedViewerManager?.pushSessionStateToAll()
    }

    private var sessionTabCatalogs: [UUID: [SessionTabID]] {
        let sessions = resourceSessions.sessions
        let sessionIDs = Dictionary(sessions.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        var catalogs = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, [SessionTabID]()) })
        for window in tmuxService.windows {
            if let identity = window.panes.first?.workspaceIdentity {
                catalogs[identity.sessionID]?.append(.window(identity.windowID))
            }
        }
        for tab in hostFileTabs.tabs {
            if let id = tab.resourceSessionID ?? sessionIDs[tab.sessionName] {
                catalogs[id]?.append(.file(tab.id))
            }
        }
        for tab in agentBrowser.sharedBrowserTabs {
            if let id = tab.resourceSessionID ?? sessionIDs[tab.sessionName] {
                catalogs[id]?.append(.browser(tab.id))
            }
        }
        for tab in agentSimulator.sharedSimulatorTabs {
            if let id = tab.resourceSessionID ?? sessionIDs[tab.sessionName] {
                catalogs[id]?.append(.browser(tab.id))
            }
        }
        return catalogs
    }
}
