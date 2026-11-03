import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Host-owned display preferences, plus local preferences for legacy remote Hosts.
@Observable
@MainActor
final class AgentModelPreferences {
    struct Key: Hashable {
        let hostID: String
        let serverID: String
        let windowID: UUID
    }

    typealias Hidden = AgentModelShortcuts

    typealias Snapshot = AgentModelShortcutPreferences

    var tabs: [Key: Hidden] = [:]
    private(set) var defaults: [Key: Hidden] = [:]
    private var revisions: [Key: UInt64] = [:]

    func preferences(for key: Key) -> Snapshot {
        .init(hidden: tabs[key] ?? .init(), defaults: defaults[key], revision: revisions[key])
    }

    @discardableResult
    func update(_ hidden: Hidden, for key: Key) -> Snapshot {
        if hidden != tabs[key] {
            tabs[key] = hidden
            revisions[key] = (revisions[key] ?? 0) + 1
        }
        return preferences(for: key)
    }

    func shared(identities: [WorkspacePaneIdentity]) -> [UUID: Snapshot] {
        Dictionary(identities.map { identity in
            (identity.windowID, preferences(for: .init(hostID: "local", serverID: identity.serverID, windowID: identity.windowID)))
        }, uniquingKeysWith: { first, _ in first })
    }

    func update(_ request: SetAgentModelShortcuts, current: WorkspacePaneIdentity) throws -> Snapshot {
        guard request.pane.isSamePane(as: current), request.pane.isSameWindow(as: current) else {
            throw AgentModelError("The terminal changed. Reopen this tab's model controls.")
        }
        return update(request.hidden, for: .init(hostID: "local", serverID: current.serverID, windowID: current.windowID))
    }

    func initialize(_ snapshot: AgentModelShortcutInitialization, hostID: String) {
        let key = Key(hostID: hostID, serverID: snapshot.pane.serverID, windowID: snapshot.pane.windowID)
        guard defaults[key] == nil else { return }
        defaults[key] = snapshot.defaults
        revisions[key] = (revisions[key] ?? 0) + 1
        if tabs[key] == nil {
            tabs[key] = snapshot.defaults
        }
    }

    func capture(hostID: String, serverID: String?, windowIDs: [UUID]) -> [UUID: Snapshot]? {
        guard let serverID else { return nil }
        let saved = Dictionary(uniqueKeysWithValues: windowIDs.compactMap { id -> (UUID, Snapshot)? in
            let key = Key(hostID: hostID, serverID: serverID, windowID: id)
            guard let hidden = tabs[key] else { return nil }
            return (id, Snapshot(hidden: hidden, defaults: defaults[key], revision: revisions[key]))
        })
        return saved.isEmpty ? nil : saved
    }

    func restore(_ saved: [UUID: Snapshot]?, hostID: String, serverID: String?, windowIDs: [UUID]) {
        guard let serverID, let saved else { return }
        for id in windowIDs {
            guard let snapshot = saved[id] else { continue }
            let key = Key(hostID: hostID, serverID: serverID, windowID: id)
            // A retry must not overwrite edits made after the tab became available.
            let restoringHidden = tabs[key] == nil
            if restoringHidden {
                tabs[key] = snapshot.hidden
                revisions[key] = snapshot.revision
            }
            if defaults[key] == nil, let original = snapshot.defaults {
                defaults[key] = original
                if !restoringHidden {
                    revisions[key] = (revisions[key] ?? 0) + 1
                }
            }
        }
    }

    func prune(hostID: String, identities: [WorkspacePaneIdentity]) {
        let live = Set(identities.map { Key(hostID: hostID, serverID: $0.serverID, windowID: $0.windowID) })
        let retained = tabs.filter { $0.key.hostID != hostID || live.contains($0.key) }
        if retained.count != tabs.count {
            tabs = retained
        }
        let retainedDefaults = defaults.filter { $0.key.hostID != hostID || live.contains($0.key) }
        if retainedDefaults.count != defaults.count {
            defaults = retainedDefaults
        }
        let retainedRevisions = revisions.filter { $0.key.hostID != hostID || live.contains($0.key) }
        if retainedRevisions.count != revisions.count {
            revisions = retainedRevisions
        }
    }
}
