import CtrlxNetworking

/// Last confirmed data can be displayed immediately, but must be rechecked before switching.
@MainActor
final class AgentModelDisplayCache {
    struct Key: Hashable {
        let hostID: String
        let pane: WorkspacePaneIdentity
        let pluginID: String
    }

    var snapshots: [Key: AgentModelSnapshot] = [:]

    func prune(hostID: String, identities: [WorkspacePaneIdentity]) {
        let live = Set(identities)
        snapshots = snapshots.filter { $0.key.hostID != hostID || live.contains($0.key.pane) }
    }
}
