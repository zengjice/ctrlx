import CtrlxCommon
import CtrlxNetworking
import Foundation

/// A presentation of the existing session and Dashboard snapshots, without its own polling.
struct IOSDashboardStatus {
    enum Connection: Equatable {
        case unpaired
        case connected
        case partial
        case connecting
        case disconnected
    }

    let connection: Connection
    let connectedCount: Int
    let hostCount: Int
    let pendingCount: Int
    let attentionSymbol: Symbols
    let lowQuotaCount: Int

    init(
        pairedHostIDs: Set<String>, connectedHostIDs: Set<String>, isConnecting: Bool,
        paneStates: [PaneKey: PaneState], dashboardHosts: [DashboardHost], at now: Date
    ) {
        let connected = connectedHostIDs.intersection(pairedHostIDs)
        self.connectedCount = connected.count
        self.hostCount = pairedHostIDs.count
        if pairedHostIDs.isEmpty {
            self.connection = .unpaired
        } else if connected.count == pairedHostIDs.count {
            self.connection = .connected
        } else if !connected.isEmpty {
            self.connection = .partial
        } else {
            self.connection = isConnecting ? .connecting : .disconnected
        }

        let pending = Self.pendingPanes(pairedHostIDs: pairedHostIDs, paneStates: paneStates)
        self.pendingCount = pending.count
        self.attentionSymbol = AgentAttention(panes: pending) == .question ? .questionmarkCircle : .bellFill

        let hosts = dashboardHosts.filter { pairedHostIDs.contains($0.id) }.map { host in
            var host = host
            // A live disconnect invalidates alerts before the next Dashboard refresh.
            host.isConnected = host.isConnected && connected.contains(host.id)
            return host
        }
        self.lowQuotaCount = DashboardOverview.accounts(in: hosts)
            .count { DashboardQuotaSummary(group: $0, at: now).isLow }
    }

    @MainActor
    static func badgeCount(pairedHostIDs: Set<String>, refreshedHostIDs: Set<String>, store: SessionStore) -> Int? {
        // An absent/disconnected Host is unknown, not an empty snapshot.
        guard
            pairedHostIDs.isSubset(of: refreshedHostIDs),
            pairedHostIDs.allSatisfy({ store.hasReceivedState(for: $0) }) else { return nil }
        return pendingPanes(pairedHostIDs: pairedHostIDs, paneStates: store.paneStates).count
    }

    private static func pendingPanes(pairedHostIDs: Set<String>, paneStates: [PaneKey: PaneState]) -> [PaneState] {
        let panesByHost = Dictionary(grouping: paneStates.filter { pairedHostIDs.contains($0.key.pairId) }, by: \.key.pairId)
        return panesByHost.values.flatMap { $0.map(\.value).pendingAttentionPanes }
    }

    var pendingText: String? {
        pendingCount > 0 ? (pendingCount > 99 ? "99+" : String(pendingCount)) : nil
    }

    var connectionDescription: String {
        switch connection {
        case .unpaired: "No Hosts paired"
        case .connected: hostCount == 1 ? "Connected" : "All \(hostCount) Hosts connected"
        case .partial: "\(connectedCount) of \(hostCount) Hosts connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        }
    }

    var dashboardAccessibilityValue: String {
        "\(connectionDescription) · \(lowQuotaCount) accounts low on quota"
    }

    var attentionAccessibilityValue: String {
        let count = "\(pendingCount) need attention"
        return attentionSymbol == .questionmarkCircle ? "\(count) · Questions waiting" : count
    }
}
