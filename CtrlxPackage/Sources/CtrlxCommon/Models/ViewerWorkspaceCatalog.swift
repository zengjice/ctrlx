import CtrlxNetworking
import Foundation

/// Only a fresh, internally consistent Host snapshot can resolve a durable
/// reference. The catalog contains routing metadata, never remote filesystem data.
public struct ViewerWorkspaceCatalog: Equatable, Sendable {
    public struct Route: Equatable, Sendable {
        public var identity: WorkspacePaneIdentity
        public var sessionName: String
        public var windowID: String
        public var paneID: String
    }

    public let pairID: String
    public let scope: WorkspaceIdentityScope
    public let routes: [UUID: Route]

    public init?(state: SessionStateMessage) {
        guard let scope = state.workspaceIdentity else { return nil }
        var routes: [UUID: Route] = [:]
        var sessionNames: [UUID: String] = [:]
        var sessionIDs: [String: UUID] = [:]
        var windows: [UUID: String] = [:]
        var windowIDs: [String: UUID] = [:]
        for (runtime, pane) in state.paneStates {
            guard let identity = pane.workspaceIdentity else { continue }
            guard
                identity.serverID == scope.serverID, !identity.serverID.isEmpty,
                runtime == pane.paneId, runtime.hasPrefix("%"), !pane.sessionName.isEmpty,
                let window = pane.tmuxWindowId, window.hasPrefix("@"), routes[identity.paneID] == nil,
                sessionNames[identity.sessionID].map({ $0 == pane.sessionName }) ?? true,
                sessionIDs[pane.sessionName].map({ $0 == identity.sessionID }) ?? true,
                windows[identity.windowID].map({ $0 == window }) ?? true,
                windowIDs[window].map({ $0 == identity.windowID }) ?? true else { return nil }
            routes[identity.paneID] = Route(identity: identity, sessionName: pane.sessionName, windowID: window, paneID: runtime)
            sessionNames[identity.sessionID] = pane.sessionName
            sessionIDs[pane.sessionName] = identity.sessionID
            windows[identity.windowID] = window
            windowIDs[window] = identity.windowID
        }
        self.pairID = state.pairId
        self.scope = scope
        self.routes = routes
    }

    public func reference(paneID: String) -> ViewerWorkspaceReference? {
        guard let route = routes.values.first(where: { $0.paneID == paneID }) else { return nil }
        return .init(
            pairID: pairID,
            hostID: scope.hostID,
            sessionID: route.identity.sessionID,
            windowID: route.identity.windowID,
            paneID: route.identity.paneID
        )
    }

    public func reference(sessionName: String, windowID: String? = nil) -> ViewerWorkspaceReference? {
        guard let route = routes.values.first(where: { $0.sessionName == sessionName && (windowID == nil || $0.windowID == windowID) }) else { return nil }
        return .init(
            pairID: pairID,
            hostID: scope.hostID,
            sessionID: route.identity.sessionID,
            windowID: windowID == nil ? nil : route.identity.windowID
        )
    }

    public func resolve(_ reference: ViewerWorkspaceReference) -> Route? {
        guard reference.pairID == pairID, reference.hostID == scope.hostID else { return nil }
        let candidates = reference.paneID.map { id in routes[id].map { [$0] } ?? [] } ?? Array(routes.values)
        return candidates.filter {
            $0.identity.sessionID == reference.sessionID && (reference.windowID == nil || $0.identity.windowID == reference.windowID)
        }.sorted { $0.paneID < $1.paneID }.first
    }
}
