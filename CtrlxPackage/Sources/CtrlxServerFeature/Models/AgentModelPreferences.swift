import CtrlxNetworking
import Foundation

/// Display preferences belong to this client's tab; workspace recovery persists them.
@Observable
@MainActor
final class AgentModelPreferences {
    struct Key: Hashable {
        let hostID: String
        let serverID: String
        let windowID: UUID
    }

    typealias Hidden = AgentModelShortcuts

    struct Snapshot: Codable, Equatable, Sendable {
        var hidden: Hidden
        var defaults: Hidden?
    }

    var tabs: [Key: Hidden] = [:]
    private(set) var defaults: [Key: Hidden] = [:]

    func initialize(_ snapshot: AgentModelShortcutInitialization, hostID: String) {
        let key = Key(hostID: hostID, serverID: snapshot.pane.serverID, windowID: snapshot.pane.windowID)
        guard defaults[key] == nil else { return }
        defaults[key] = snapshot.defaults
        if tabs[key] == nil {
            tabs[key] = snapshot.defaults
        }
    }

    func capture(hostID: String, serverID: String?, windowIDs: [UUID]) -> [UUID: Snapshot]? {
        guard let serverID else { return nil }
        let saved = Dictionary(uniqueKeysWithValues: windowIDs.compactMap { id -> (UUID, Snapshot)? in
            let key = Key(hostID: hostID, serverID: serverID, windowID: id)
            guard let hidden = tabs[key] else { return nil }
            return (id, Snapshot(hidden: hidden, defaults: defaults[key]))
        })
        return saved.isEmpty ? nil : saved
    }

    func restore(_ saved: [UUID: Snapshot]?, hostID: String, serverID: String?, windowIDs: [UUID]) {
        guard let serverID, let saved else { return }
        for id in windowIDs {
            guard let snapshot = saved[id] else { continue }
            let key = Key(hostID: hostID, serverID: serverID, windowID: id)
            // A retry must not overwrite edits made after the tab became available.
            if tabs[key] == nil {
                tabs[key] = snapshot.hidden
            }
            if defaults[key] == nil, let original = snapshot.defaults {
                defaults[key] = original
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
    }
}
