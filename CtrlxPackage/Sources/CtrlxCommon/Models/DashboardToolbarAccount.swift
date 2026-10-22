import CtrlxNetworking
import Foundation

/// A titlebar reading uses the same account identity and freshness rules as Dashboard.
public struct DashboardToolbarAccount: Identifiable, Sendable {
    public enum Level: Sendable { case normal, warning, low, unknown }

    public let group: DashboardAccountGroup
    public let account: DashboardAccount
    public let remaining: Double?
    public let level: Level
    public let status: String?
    public let observedAt: Date?

    public var id: DashboardAccountGroup.ID {
        group.id
    }

    public var title: String {
        "\(account.providerName) · \(account.label)"
    }

    public init?(group: DashboardAccountGroup, at now: Date) {
        guard let selection = group.selection, selection.source.account.availability != .unsupported else { return nil }
        self.group = group
        self.account = selection.source.account
        self.observedAt = selection.source.interval?.upperBound
        let source = selection.source
        let values = account.windows.compactMap { $0.remainingPercent(at: now) }
        // A stale/expired constraint must not disappear behind another green window.
        let complete = !values.isEmpty && values.count == account.windows.count
        let current = group.currentQuotaSource(at: now) != nil
        self.remaining = current && complete ? (account.limitReached == true ? 0 : values.min()) : nil
        self.level = remaining.map { $0 <= 10 ? .low : ($0 <= 20 ? .warning : .normal) } ?? .unknown

        if selection.uncertain {
            self.status = "Sources disagree. Open Dashboard to compare observations."
        } else if !source.host.isConnected {
            self.status = "Host offline · Last observation"
        } else if source.host.error != nil {
            self.status = "Could not refresh · Last observation"
        } else if account.authentication == .signedOut {
            self.status = "Sign in on the Host to read quotas."
        } else if account.availability != .available {
            self.status = account.detail ?? "Quota unavailable"
        } else if !complete {
            self.status = account.windows.isEmpty ? "Quota unavailable" : "Waiting for updated quotas"
        } else if !current {
            self.status = "Last observation · Current quota unconfirmed"
        } else if account.limitReached == true {
            self.status = "Limit reached"
        } else {
            self.status = nil
        }
    }

    public static func accounts(in hosts: [DashboardHost], at now: Date) -> [Self] {
        DashboardOverview.accounts(in: hosts)
            .compactMap { Self(group: $0, at: now) }
            .sorted { $0.orderKey.lexicographicallyPrecedes($1.orderKey) }
    }

    /// Identity, not quota, selected Host, arrival order or display label, determines order.
    private var orderKey: [String] {
        switch id {
        case let .verified(identity):
            [identity.providerID, "0", identity.accountID, identity.workspaceID, identity.poolID]
        case let .source(hostID, sourceID):
            [account.pluginID, "1", hostID, sourceID]
        }
    }
}
