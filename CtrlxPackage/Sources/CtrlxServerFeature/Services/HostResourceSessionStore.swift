import CtrlxCommon
import CtrlxNetworking
import Foundation
import Observation

@MainActor @Observable
final class HostResourceSessionStore {
    private(set) var sessions: [ResourceSession] = []
    @ObservationIgnored private var terminalIDs: Set<UUID> = []
    @ObservationIgnored private var resourceIDs: Set<UUID> = []
    @ObservationIgnored private var reservations: [UUID: Int] = [:]
    @ObservationIgnored private var closedIDs: Set<UUID> = []

    func update(_ panes: [PaneInfo]) {
        var live: [UUID: ResourceSession] = [:]
        for pane in panes {
            guard let id = pane.workspaceIdentity?.sessionID, !closedIDs.contains(id) else { continue }
            if live[id] == nil {
                live[id] = .init(id: id, name: pane.sessionName, directory: pane.currentPath)
            }
        }
        terminalIDs = Set(live.keys)
        var retained = sessions.filter { live[$0.id] == nil && (resourceIDs.contains($0.id) || reservations[$0.id] != nil) }
        // A later tmux session with a reused name cannot inherit human resources.
        var names = Set(live.values.map(\.name))
        for index in retained.indices {
            if names.contains(retained[index].name) {
                retained[index].name += " · " + retained[index].id.uuidString.prefix(8)
            }
            names.insert(retained[index].name)
        }
        sessions = (Array(live.values) + retained).sorted { $0.name < $1.name }
    }

    func retainResources(in ids: Set<UUID>) {
        resourceIDs = ids
        prune()
    }

    func restore(_ saved: [ResourceSession]) {
        for var session in saved where !closedIDs.contains(session.id) && !sessions.contains(where: { $0.id == session.id }) {
            if sessions.contains(where: { $0.name == session.name }) {
                session.name += " · " + session.id.uuidString.prefix(8)
            }
            sessions.append(session)
        }
    }

    func resolve(_ id: UUID) throws -> ResourceSession {
        guard !closedIDs.contains(id), let session = sessions.first(where: { $0.id == id }) else {
            throw FileBrowserError.message("This session is no longer available. Refresh the session list.")
        }
        return session
    }

    func reserve(_ id: UUID) throws -> ResourceSession {
        let session = try resolve(id)
        reservations[id, default: 0] += 1
        return session
    }

    func release(_ id: UUID) {
        if let count = reservations[id], count > 1 {
            reservations[id] = count - 1
        } else {
            reservations.removeValue(forKey: id)
        }
        prune()
    }

    func beginClosing(_ id: UUID) {
        closedIDs.insert(id)
    }

    func cancelClosing(_ session: ResourceSession) {
        closedIDs.remove(session.id)
        if !sessions.contains(where: { $0.id == session.id }) {
            sessions.append(session)
        }
    }

    func remove(_ id: UUID) {
        closedIDs.insert(id)
        sessions.removeAll { $0.id == id }
        terminalIDs.remove(id)
        resourceIDs.remove(id)
        reservations.removeValue(forKey: id)
    }

    private func prune() {
        sessions.removeAll { !terminalIDs.contains($0.id) && !resourceIDs.contains($0.id) && reservations[$0.id] == nil }
    }
}
