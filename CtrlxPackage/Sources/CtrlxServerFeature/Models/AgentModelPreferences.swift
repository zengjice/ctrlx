import CtrlxNetworking
import Foundation

/// Display preferences belong to this client's live tab, not the Agent or disk.
@Observable
@MainActor
final class AgentModelPreferences {
    struct Key: Hashable {
        let hostID: String
        let serverID: String
        let windowID: UUID
    }

    typealias Hidden = AgentModelShortcuts

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
