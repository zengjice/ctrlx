import CtrlxCommon
import CtrlxNetworking
import Foundation

/// A tmux session rename inferred from two pane snapshots.
///
/// Pane IDs survive `rename-session`, while session/window textual IDs change.
/// Requiring the complete pane-ID set to match prevents a normal `move-window`
/// from being mistaken for a session rename.
struct SessionRenameMapping: Equatable, Sendable {
    let oldName: String
    let newName: String
    let windowIDs: [String: String]

    static func detect(from oldPanes: [PaneInfo], to newPanes: [PaneInfo]) -> [SessionRenameMapping] {
        let oldPaneIDs = Dictionary(grouping: oldPanes, by: \.sessionName)
            .mapValues { Set($0.map(\.paneId)) }
        let newPaneIDs = Dictionary(grouping: newPanes, by: \.sessionName)
            .mapValues { Set($0.map(\.paneId)) }

        return detectNames(from: oldPaneIDs, to: newPaneIDs).map { oldName, newName in
            let oldByPaneID = Dictionary(uniqueKeysWithValues: oldPanes
                .filter { $0.sessionName == oldName }
                .map { ($0.paneId, $0.windowId) })
            let windowIDs = Dictionary(
                newPanes
                    .filter { $0.sessionName == newName }
                    .compactMap { pane in
                        oldByPaneID[pane.paneId].map { ($0, pane.windowId) }
                    },
                uniquingKeysWith: { _, latest in latest }
            )

            return SessionRenameMapping(oldName: oldName, newName: newName, windowIDs: windowIDs)
        }
    }

    static func detectNames(
        from oldPaneIDs: [String: Set<String>],
        to newPaneIDs: [String: Set<String>]
    ) -> [(oldName: String, newName: String)] {
        let removedNames = oldPaneIDs.keys.filter { newPaneIDs[$0] == nil }
        let addedNames = newPaneIDs.keys.filter { oldPaneIDs[$0] == nil }

        return removedNames.compactMap { oldName in
            guard let paneIDs = oldPaneIDs[oldName], !paneIDs.isEmpty else { return nil }
            let matchingOldNames = removedNames.filter { oldPaneIDs[$0] == paneIDs }
            let matchingNewNames = addedNames.filter { newPaneIDs[$0] == paneIDs }
            guard matchingOldNames.count == 1, matchingNewNames.count == 1 else { return nil }
            return (oldName, matchingNewNames[0])
        }
        .sorted { $0.oldName < $1.oldName }
    }
}

/// Observe routing identity only; agent activity and pane rendering updates are not layout changes.
struct RemoteSessionStructure: Equatable {
    struct Location: Equatable {
        let sessionName: String
        let windowID: String
    }

    let locations: [PaneKey: Location]

    init(panes: [PaneKey: PaneState]) {
        self.locations = panes.mapValues { Location(sessionName: $0.sessionName, windowID: $0.windowId) }
    }

    /// The catalog and pane store are delivered separately. Wait for matching routing
    /// instead of treating a renamed page as deleted during that intermediate render.
    func canSyncBrowserCatalog(_ catalog: [RemoteBrowserTab], simulators: [RemoteSimulatorTab] = [], hostID: String, sessionName: String) -> Bool {
        guard locations.contains(where: { $0.key.pairId == hostID && $0.value.sessionName == sessionName }) else { return false }
        return catalog.allSatisfy { tab in
            guard let paneID = tab.sourcePaneID, let location = locations[PaneKey(pairId: hostID, paneId: paneID)] else { return true }
            return location.sessionName == tab.sessionName
        } && simulators.allSatisfy { tab in
            guard let location = locations[PaneKey(pairId: hostID, paneId: tab.sourcePaneID)] else { return true }
            return location.sessionName == tab.sessionName
        }
    }

    func renames(from previous: Self) -> [(hostID: String, mapping: SessionRenameMapping)] {
        Set(previous.locations.keys.map(\.pairId)).sorted().flatMap { hostID in
            let old = previous.locations.filter { $0.key.pairId == hostID }
            let new = locations.filter { $0.key.pairId == hostID }
            let oldGroups = Dictionary(grouping: old, by: { $0.value.sessionName })
                .mapValues { Set($0.map(\.key.paneId)) }
            let newGroups = Dictionary(grouping: new, by: { $0.value.sessionName })
                .mapValues { Set($0.map(\.key.paneId)) }
            return SessionRenameMapping.detectNames(from: oldGroups, to: newGroups).map { oldName, newName in
                let windowIDs = Dictionary(new.compactMap { key, location -> (String, String)? in
                    guard location.sessionName == newName, let source = old[key], source.sessionName == oldName else { return nil }
                    return (source.windowID, location.windowID)
                }, uniquingKeysWith: { _, latest in latest })
                return (hostID, SessionRenameMapping(oldName: oldName, newName: newName, windowIDs: windowIDs))
            }
        }
    }
}

/// Maps executable `session:index` targets across a tmux window reindex.
///
/// tmux's `window_id` is stable while a window remains alive, but a linked
/// window can appear in more than one session. The session name is therefore
/// part of the lookup key even though it is not part of the returned mapping.
enum WindowReindexMapping {
    private struct Key: Hashable {
        let sessionName: String
        let stableWindowId: String
    }

    static func detect(from oldPanes: [PaneInfo], to newPanes: [PaneInfo]) -> [String: String] {
        let newTargets = Dictionary(
            newPanes.map { pane in
                (Key(sessionName: pane.sessionName, stableWindowId: pane.stableWindowId), pane.windowId)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return Dictionary(
            oldPanes.compactMap { pane -> (String, String)? in
                let key = Key(sessionName: pane.sessionName, stableWindowId: pane.stableWindowId)
                guard let newTarget = newTargets[key], newTarget != pane.windowId else { return nil }
                return (pane.windowId, newTarget)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
