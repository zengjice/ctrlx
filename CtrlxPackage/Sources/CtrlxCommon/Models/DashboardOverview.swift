import CtrlxNetworking
import Foundation

public struct DashboardHost: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var isLocal: Bool
    public var isConnected: Bool
    public var isSupported: Bool
    public var snapshot: DashboardSnapshot?
    public var legacyUsage: UsageOverview?
    public var requestedAt: Date?
    public var receivedAt: Date?
    public var error: String?

    public init(
        id: String, name: String, isLocal: Bool = false, isConnected: Bool = false,
        isSupported: Bool = false, snapshot: DashboardSnapshot? = nil,
        legacyUsage: UsageOverview? = nil,
        requestedAt: Date? = nil, receivedAt: Date? = nil, error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.isConnected = isConnected
        self.isSupported = isSupported
        self.snapshot = snapshot
        self.legacyUsage = legacyUsage
        self.requestedAt = requestedAt
        self.receivedAt = receivedAt
        self.error = error
    }

    public func currentUsage(at now: Date) -> UsageOverview? {
        guard
            let snapshot, let usage = snapshot.usage, let receivedAt,
            let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) else { return nil }
        // Compare with the Host's clock/day, including elapsed time while offline.
        let hostNow = snapshot.generatedAt.addingTimeInterval(max(0, now.timeIntervalSince(receivedAt)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: hostNow)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        return usage.generatedDay == key ? usage : nil
    }
}

public struct DashboardAccountGroup: Identifiable, Sendable {
    public enum ID: Hashable, Sendable {
        case verified(DashboardAccountIdentity)
        case source(hostID: String, sourceID: String)
    }

    public struct Source: Sendable {
        public var host: DashboardHost
        public var account: DashboardAccount

        /// Normalize the Host's sample age to this Viewer's clock. Request time
        /// bounds network uncertainty; overlapping observations cannot be ordered.
        var interval: ClosedRange<Date>? {
            guard
                let observed = account.quotaObservedAt,
                let generated = host.snapshot?.generatedAt,
                let received = host.receivedAt, let requested = host.requestedAt,
                generated >= observed, received >= requested else { return nil }
            let age = generated.timeIntervalSince(observed)
            return requested.addingTimeInterval(-age)...received.addingTimeInterval(-age)
        }
    }

    public var id: ID
    public var sources: [Source]

    public var selection: (source: Source, uncertain: Bool)? {
        let candidates = sources.filter { (!$0.account.windows.isEmpty || $0.account.credits != nil || $0.account.limitReached != nil) && $0.interval != nil }
        guard var selected = candidates.first else { return sources.first.map { ($0, false) } }
        for source in candidates.dropFirst() {
            if
                let newer = source.interval, let previous = selected.interval,
                newer.lowerBound > previous.upperBound {
                selected = source
            }
        }
        let uncertain = candidates.contains { source in
            guard
                let a = source.interval, let b = selected.interval,
                source.account.windows != selected.account.windows || source.account.credits != selected.account.credits || source.account.limitReached != selected.account.limitReached else { return false }
            return a.overlaps(b)
        }
        return (selected, uncertain)
    }
}

public enum DashboardOverview {
    public static func uniqueHosts(_ hosts: [DashboardHost]) -> [DashboardHost] {
        var result: [DashboardHost] = []
        var positions: [UUID: Int] = [:]
        for host in hosts {
            guard let identity = host.snapshot?.hostID else { result.append(host)
                continue
            }
            guard let index = positions[identity] else {
                positions[identity] = result.count
                result.append(host)
                continue
            }
            let current = result[index]
            if host.isConnected != current.isConnected ? host.isConnected : host.isLocal && !current.isLocal {
                result[index] = host
            }
        }
        return result
    }

    public static func accounts(in hosts: [DashboardHost]) -> [DashboardAccountGroup] {
        var groups: [DashboardAccountGroup] = []
        var positions: [DashboardAccountGroup.ID: Int] = [:]
        for host in uniqueHosts(hosts) {
            for account in host.snapshot?.accounts ?? [] {
                let identity = account.identity.flatMap { value in
                    [value.providerID, value.accountID, value.workspaceID, value.poolID].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? value : nil
                }
                let key: DashboardAccountGroup.ID = identity.map { .verified($0) }
                    ?? .source(hostID: host.id, sourceID: account.id)
                let source = DashboardAccountGroup.Source(host: host, account: account)
                if let index = positions[key] {
                    groups[index].sources.append(source)
                } else {
                    positions[key] = groups.count
                    groups.append(.init(id: key, sources: [source]))
                }
            }
        }
        return groups
    }

    public static func usage(in hosts: [DashboardHost], at date: Date) -> (tokens: Int, sessions: Int, currentHosts: Int) {
        uniqueHosts(hosts).reduce(into: (tokens: 0, sessions: 0, currentHosts: 0)) { result, host in
            guard let usage = host.currentUsage(at: date) else { return }
            result.tokens += usage.todayTokens
            result.sessions += usage.todaySessionCount
            if host.isConnected, host.error == nil, let received = host.receivedAt, date.timeIntervalSince(received) < 30 {
                result.currentHosts += 1
            }
        }
    }
}
