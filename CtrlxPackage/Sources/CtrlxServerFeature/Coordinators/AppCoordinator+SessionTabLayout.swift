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
        try await sessionTabLayouts.apply(request, catalog: sessionTabCatalogs[request.sessionID] ?? []) { layout in
            let source: SessionTabID
            switch request.edit {
            case let .move(id, _, _),
                 let .moveToEnd(id, _, _),
                 let .group(id, _): source = id
            default: return nil
            }
            guard case .window = source else { return nil }
            let windows = tmuxService.windows.filter { $0.sessionName == session.name }
            let routes = Dictionary(windows.compactMap { window in
                window.panes.first?.workspaceIdentity.flatMap { identity in
                    identity.sessionID == session.id ? (SessionTabID.window(identity.windowID), window.stableId) : nil
                }
            }, uniquingKeysWith: { first, _ in first })
            let original = windows.map(\.stableId)
            let visible = request.visibleWindows.map(Set.init) ?? Set(routes.keys)
            guard visible.contains(source), visible.isSubset(of: Set(routes.keys)) else {
                throw TmuxError.invalidWindowOrder(reason: "the workbench window set has changed")
            }
            let desired = layout.order.filter(visible.contains).compactMap { routes[$0] }
            guard let order = TabDragPayload.mergingWindowOrder(desired, into: original) else {
                throw TmuxError.invalidWindowOrder(reason: "the workbench window order is invalid")
            }
            if order != original {
                guard let identity = windows.lazy.compactMap({ $0.panes.first?.workspaceIdentity }).first(where: { $0.sessionID == session.id }) else {
                    throw TmuxError.invalidWindowOrder(reason: "the session has changed")
                }
                try await tmuxService.moveWindows(in: session.name, to: order, expectedWorkspacePane: identity)
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
