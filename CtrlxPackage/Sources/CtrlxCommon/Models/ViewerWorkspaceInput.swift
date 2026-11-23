import CtrlxNetworking
import Foundation

/// Queued actions keep their original target. Refreshing the catalog must not
/// retarget pending input, layout actions or a close confirmation.
public enum ViewerWorkspaceInputBinding: Equatable, Sendable {
    case unavailable
    case legacy(pairID: String)
    case legacyWindow(pairID: String, incarnation: UUID)
    case pane(pairID: String, hostID: UUID, identity: WorkspacePaneIdentity)
    case window(pairID: String, hostID: UUID, identity: WorkspacePaneIdentity)
    case session(pairID: String, hostID: UUID, identity: WorkspacePaneIdentity)

    public func expectedPane(current: Self) throws -> WorkspacePaneIdentity? {
        switch (self, current) {
        case let (.legacy(pair), .legacy(currentPair)) where pair == currentPair:
            return nil
        case let (.legacyWindow(pair, id), .legacyWindow(currentPair, currentID)) where pair == currentPair && id == currentID:
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
    private struct LegacyWindow: Equatable, Sendable {
        let stableID: String
        let incarnation: UUID
    }

    public private(set) var catalog: ViewerWorkspaceCatalog?
    private var pairID: String?
    private var windowPaneIDs: [String: String] = [:]
    private var legacyWindowsByPane: [String: LegacyWindow] = [:]
    public private(set) var supportsIdentity = false
    public private(set) var supportsStreamIdentity = false
    public private(set) var supportsGuardedTerminalTabClose = false

    public init() { }

    public mutating func update(_ state: SessionStateMessage) {
        let previousLegacyWindows = pairID == state.pairId ? legacyWindowsByPane : [:]
        pairID = state.pairId
        supportsIdentity = state.supportsWorkspaceInputIdentity == true
        supportsStreamIdentity = state.supportsTerminalStreamIdentity == true
        supportsGuardedTerminalTabClose = state.supportsGuardedTerminalTabClose == true
        catalog = ViewerWorkspaceCatalog(state: state)
        windowPaneIDs.removeAll()
        for pane in state.paneStates.values.sorted(by: { $0.paneId < $1.paneId }) {
            for target in [pane.paneId, pane.windowId, pane.stableWindowId] where windowPaneIDs[target] == nil {
                windowPaneIDs[target] = pane.paneId
            }
        }
        legacyWindowsByPane.removeAll(keepingCapacity: true)
        guard !supportsIdentity else { return }
        // An overlapping pane links consecutive full snapshots of a legacy window.
        // Once a window disappears, a later reuse of its numeric route gets a new identity.
        for (stableID, panes) in Dictionary(grouping: state.paneStates.values, by: \.stableWindowId) {
            let window = panes.lazy.compactMap { previousLegacyWindows[$0.paneId] }.first { $0.stableID == stableID }
                ?? LegacyWindow(stableID: stableID, incarnation: UUID())
            for pane in panes {
                legacyWindowsByPane[pane.paneId] = window
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
        guard supportsIdentity else {
            if let paneID = windowPaneIDs[target], let window = legacyWindowsByPane[paneID] {
                return .legacyWindow(pairID: pairID, incarnation: window.incarnation)
            }
            return .legacy(pairID: pairID)
        }
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
