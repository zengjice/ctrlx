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

    struct Hidden {
        var models: Set<String> = []
        var efforts: Set<String> = []

        func shows(model: AgentModelOption, selection: AgentModelSelection?) -> Bool {
            model.id == selection?.model || !models.contains(model.id)
        }

        func shows(effort: String, selection: AgentModelSelection?) -> Bool {
            effort == selection?.effort || !efforts.contains(effort)
        }
    }

    var tabs: [Key: Hidden] = [:]

    func prune(hostID: String, identities: [WorkspacePaneIdentity]) {
        let live = Set(identities.map { Key(hostID: hostID, serverID: $0.serverID, windowID: $0.windowID) })
        let retained = tabs.filter { $0.key.hostID != hostID || live.contains($0.key) }
        guard retained.count != tabs.count else { return }
        tabs = retained
    }
}
