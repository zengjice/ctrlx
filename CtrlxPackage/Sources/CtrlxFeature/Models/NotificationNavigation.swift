import Clocks
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation

enum NotificationNavigation {
    struct Snapshot {
        var isConnected: Bool
        var id: UUID?
        var catalog: ViewerWorkspaceCatalog?
    }

    enum Issue: String, Error {
        case missingIdentity
        case hostNotConnected
        case directoryNotReady
        case targetUnavailable

        var message: String {
            switch self {
            case .missingIdentity:
                "This notification does not contain an Agent destination. Open its tab from the Host's session list."
            case .hostNotConnected:
                "Could not connect to this notification's Host. Connect to it, then tap the notification again."
            case .directoryNotReady:
                "The Host's session list has not finished syncing. Wait for it to load, then tap the notification again."
            case .targetUnavailable:
                "This notification's Agent tab is no longer available on the Host. Choose another tab from its session list."
            }
        }
    }

    /// A cached list cannot prove that a notified pane still exists. Request a
    /// fresh snapshot after connection, including when its contents are unchanged.
    @MainActor
    static func resolve(
        agentID: AgentID?, hostID: String,
        snapshot: () -> Snapshot,
        requestSnapshot: () async -> Bool
    ) async throws -> Result<SessionNavigation, Issue> {
        try Task.checkCancellation()
        guard let agentID else { return .failure(.missingIdentity) }
        @Dependency(\.continuousClock) var continuousClock
        let clock = AnyClock(continuousClock)
        let deadline = clock.now.advanced(by: .seconds(15))
        var requested = false
        var previousSnapshotID: UUID?
        while clock.now < deadline {
            try Task.checkCancellation()
            let current = snapshot()
            if !current.isConnected {
                requested = false
            } else if !requested {
                previousSnapshotID = current.id
                requested = await requestSnapshot()
                try Task.checkCancellation()
            }
            let refreshed = snapshot()
            if requested, refreshed.isConnected, let id = refreshed.id, id != previousSnapshotID, let catalog = refreshed.catalog {
                if let destination = SessionNavigation.notification(agentID: agentID, hostID: hostID, catalog: catalog) {
                    return .success(destination)
                }
                return .failure(.targetUnavailable)
            }
            try await clock.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        return .failure(snapshot().isConnected ? .directoryNotReady : .hostNotConnected)
    }
}
