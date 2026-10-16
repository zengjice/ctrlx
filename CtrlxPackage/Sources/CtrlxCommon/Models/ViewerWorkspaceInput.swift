import CtrlxNetworking
import Foundation

/// Queued actions keep their original target. Refreshing the catalog must not
/// retarget pending input, layout actions or a close confirmation.
public enum ViewerWorkspaceInputBinding: Equatable, Sendable {
    case unavailable
    case legacy(pairID: String)
    case pane(pairID: String, hostID: UUID, identity: WorkspacePaneIdentity)
    case window(pairID: String, hostID: UUID, identity: WorkspacePaneIdentity)
    case session(pairID: String, hostID: UUID, identity: WorkspacePaneIdentity)

    public func expectedPane(current: Self) throws -> WorkspacePaneIdentity? {
        switch (self, current) {
        case let (.legacy(pair), .legacy(currentPair)) where pair == currentPair:
            return nil
        case let (.pane(pair, host, identity), .pane(currentPair, currentHost, currentIdentity))
            where pair == currentPair && host == currentHost && identity.isSamePane(as: currentIdentity):
            return identity
        case let (.window(pair, host, identity), .window(currentPair, currentHost, currentIdentity))
            where pair == currentPair && host == currentHost && identity.isSameWindow(as: currentIdentity):
            return identity
        case let (.session(pair, host, identity), .session(currentPair, currentHost, currentIdentity))
            where pair == currentPair && host == currentHost && identity.isSameSession(as: currentIdentity):
            return identity
        default:
            throw ViewerRelayClientError.commandFailed("The terminal changed or is reconnecting. Select the restored terminal and try again.")
        }
    }
}

public struct ViewerWorkspaceInputState: Equatable, Sendable {
    public private(set) var catalog: ViewerWorkspaceCatalog?
    private var pairID: String?
    private var windowPaneIDs: [String: String] = [:]
    public private(set) var supportsIdentity = false
    public private(set) var supportsStreamIdentity = false

    public init() { }

    public mutating func update(_ state: SessionStateMessage) {
        pairID = state.pairId
        supportsIdentity = state.supportsWorkspaceInputIdentity == true
        supportsStreamIdentity = state.supportsTerminalStreamIdentity == true
        catalog = ViewerWorkspaceCatalog(state: state)
        windowPaneIDs.removeAll()
        for pane in state.paneStates.values.sorted(by: { $0.paneId < $1.paneId }) {
            for target in [pane.paneId, pane.windowId, pane.stableWindowId] where windowPaneIDs[target] == nil {
                windowPaneIDs[target] = pane.paneId
            }
        }
    }

    public mutating func invalidate() {
        self = .init()
    }

    public func binding(paneID: String) -> ViewerWorkspaceInputBinding {
        guard let pairID else { return .unavailable }
        guard supportsIdentity else { return .legacy(pairID: pairID) }
        guard
            let catalog, let reference = catalog.reference(paneID: paneID),
            let route = catalog.resolve(reference) else { return .unavailable }
        return .pane(pairID: pairID, hostID: catalog.scope.hostID, identity: route.identity)
    }

    public func windowBinding(target: String) -> ViewerWorkspaceInputBinding {
        guard let pairID else { return .unavailable }
        guard supportsIdentity else { return .legacy(pairID: pairID) }
        guard
            let paneID = windowPaneIDs[target],
            case let .pane(pair, host, identity) = binding(paneID: paneID) else { return .unavailable }
        return .window(pairID: pair, hostID: host, identity: identity)
    }

    public func sessionBinding(name: String) -> ViewerWorkspaceInputBinding {
        guard let pairID else { return .unavailable }
        guard supportsIdentity else { return .legacy(pairID: pairID) }
        guard
            let catalog, let reference = catalog.reference(sessionName: name),
            let route = catalog.resolve(reference) else { return .unavailable }
        return .session(pairID: pairID, hostID: catalog.scope.hostID, identity: route.identity)
    }

    /// Numeric pane IDs are unique only within one tmux server. Wait for the
    /// creation's own catalog before adopting a delayed reply or fitting it.
    public func createdSessionBinding(pane: PaneState, scope: WorkspaceIdentityScope?) -> ViewerWorkspaceInputBinding? {
        guard let pairID else { return nil }
        if !supportsIdentity, scope == nil {
            return .legacy(pairID: pairID)
        }
        guard
            let scope, let catalog, scope == catalog.scope,
            case let .pane(pair, host, identity) = binding(paneID: pane.paneId),
            identity == pane.workspaceIdentity,
            catalog.routes[identity.paneID]?.sessionName == pane.sessionName
        else { return nil }
        return .session(pairID: pair, hostID: host, identity: identity)
    }
}
