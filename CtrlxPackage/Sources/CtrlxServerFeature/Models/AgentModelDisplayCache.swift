import CtrlxNetworking
import Foundation

/// Last confirmed data can be displayed immediately, but must be rechecked before switching.
@MainActor
final class AgentModelDisplayCache {
    struct Key: Hashable {
        let hostID: String
        let pane: WorkspacePaneIdentity
        let pluginID: String
    }

    struct Entry {
        let snapshot: AgentModelSnapshot
        let updatedAt: ContinuousClock.Instant
    }

    private var entries: [Key: Entry] = [:]

    func entry(for key: Key) -> Entry? {
        entries[key]
    }

    func store(_ snapshot: AgentModelSnapshot, for key: Key, now: ContinuousClock.Instant = .now) {
        entries[key] = Entry(snapshot: snapshot, updatedAt: now)
    }

    /// Briefly visited tabs do no work; recently read tabs keep the normal polling deadline.
    func refreshDelay(for key: Key, now: ContinuousClock.Instant = .now) -> Duration {
        guard let entry = entries[key] else { return .milliseconds(300) }
        return max(.milliseconds(300), .seconds(3) - (now - entry.updatedAt))
    }

    func prune(hostID: String, identities: [WorkspacePaneIdentity]) {
        let live = Set(identities)
        entries = entries.filter { $0.key.hostID != hostID || live.contains($0.key.pane) }
    }
}
