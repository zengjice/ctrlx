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

        let panesByHost = Dictionary(grouping: paneStates.filter { pairedHostIDs.contains($0.key.pairId) }, by: \.key.pairId)
        self.pendingCount = panesByHost.values.reduce(0) { $0 + $1.map(\.value).pendingSessionCount }

        let hosts = dashboardHosts.filter { pairedHostIDs.contains($0.id) }.map { host in
            var host = host
            // A live disconnect invalidates alerts before the next Dashboard refresh.
            host.isConnected = host.isConnected && connected.contains(host.id)
            return host
        }
        self.lowQuotaCount = DashboardOverview.accounts(in: hosts)
            .count { DashboardQuotaSummary(group: $0, at: now).isLow }
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

    var accessibilityValue: String {
        "\(connectionDescription) · \(pendingCount) need attention · \(lowQuotaCount) accounts low on quota"
    }
}
