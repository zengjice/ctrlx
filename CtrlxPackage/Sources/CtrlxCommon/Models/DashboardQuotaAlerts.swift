import CtrlxNetworking
import Foundation

public struct DashboardQuotaSummary: Identifiable, Sendable {
    public let id: DashboardAccountGroup.ID
    public let title: String
    public let hosts: String
    public let window: String?
    public let remaining: Double?
    public let isCurrent: Bool

    public var isLow: Bool {
        isCurrent && remaining.map { $0 <= 10 } == true
    }

    public var detail: String {
        guard let remaining, let window else { return "Quota unavailable" }
        let value = "\(window): \(remaining.formatted(.number.precision(.fractionLength(0))))% remaining"
        return isCurrent ? value : "Last observation · \(value)"
    }

    public init(group: DashboardAccountGroup, at now: Date) {
        self.id = group.id
        let selection = group.selection
        let account = selection?.source.account
        self.title = account.map { "\($0.providerName) · \($0.label)" } ?? "Account"
        self.hosts = Set(group.sources.map(\.host.name)).sorted().joined(separator: ", ")
        self.isCurrent = group.currentQuotaSource(at: now) != nil
        let lowest = account?.windows.compactMap { window in
            window.remainingPercent(at: now).map { (window.title, $0) }
        }.min { $0.1 < $1.1 }
        self.window = lowest?.0
        self.remaining = lowest?.1
    }
}

extension DashboardAccountGroup {
    /// The UI may keep an old reading, but only a recent, unambiguous reading can alert.
    func currentQuotaSource(at now: Date) -> Source? {
        guard case .verified = id, let selected = selection, !selected.uncertain else { return nil }
        let source = selected.source
        guard
            source.host.isConnected, source.host.error == nil,
            source.account.authentication == .signedIn, source.account.availability == .available,
            let received = source.host.receivedAt, now.timeIntervalSince(received) <= 120,
            let interval = source.interval,
            interval.lowerBound >= now.addingTimeInterval(-300), interval.upperBound <= now.addingTimeInterval(5)
        else { return nil }
        return source
    }
}

public struct DashboardQuotaAlert: Sendable, Equatable {
    public let account: String
    public let windows: [String]
    public let hosts: String

    public var body: String {
        "\(account) — \(windows.joined(separator: "; ")) · \(hosts)"
    }
}

/// One baseline per account and quota window, shared by every surface in a client.
public struct DashboardQuotaAlertTracker {
    private struct Key: Hashable {
        let account: DashboardAccountGroup.ID
        let window: String
    }

    private struct Observation {
        let remaining: Double
        let reset: Date?
        let observed: Date
        var warned: Bool
    }

    private var previous: [Key: Observation] = [:]

    public init() { }

    public mutating func update(hosts: [DashboardHost], at now: Date) -> [DashboardQuotaAlert] {
        var retained: Set<Key> = []
        var alerts: [DashboardQuotaAlert] = []
        for group in DashboardOverview.accounts(in: hosts) {
            if let source = group.selection?.source, source.account.authentication != .signedOut {
                for window in source.account.windows {
                    retained.insert(Key(account: group.id, window: window.id))
                }
            }
            guard let source = group.currentQuotaSource(at: now), let interval = source.interval else { continue }
            var crossed: [String] = []
            for window in source.account.windows {
                guard let remaining = window.remainingPercent(at: now) else { continue }
                let key = Key(account: group.id, window: window.id)
                retained.insert(key)
                let old = previous[key]
                guard old.map({ interval.upperBound > $0.observed }) ?? true else { continue }
                let advanced = old?.reset.map { reset in
                    now >= reset && window.resetsAt.map { $0 > reset } == true
                } ?? false
                var warned = advanced ? false : (old?.warned ?? (remaining <= 10))
                if
                    let old, now.timeIntervalSince(old.observed) <= 300,
                    !advanced, !warned, old.remaining > 10, remaining <= 10 {
                    crossed.append("\(window.title): \(remaining.formatted(.number.precision(.fractionLength(0))))% remaining")
                    warned = true
                }
                // A new cycle that is already low is a baseline, not a crossing.
                if advanced, remaining <= 10 {
                    warned = true
                }
                previous[key] = Observation(remaining: remaining, reset: window.resetsAt, observed: interval.upperBound, warned: warned)
            }
            if !crossed.isEmpty {
                alerts.append(.init(
                    account: "\(source.account.providerName) · \(source.account.label)",
                    windows: crossed,
                    hosts: Set(group.sources.map(\.host.name)).sorted().joined(separator: ", ")
                ))
            }
        }
        previous = previous.filter { retained.contains($0.key) }
        return alerts
    }
}
