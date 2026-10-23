import Clocks
import CtrlxNetworking
import Dependencies
import Foundation

/// A route is local to this Viewer; only a snapshot's Host UUID deduplicates machines.
@MainActor
public struct DashboardEndpoint {
    public var host: DashboardHost
    public var read: @MainActor @Sendable () async throws -> DashboardSnapshot

    public init(host: DashboardHost, read: @escaping @MainActor @Sendable () async throws -> DashboardSnapshot) {
        self.host = host
        self.read = read
    }

    public static func remote(_ host: PairedHost, manager: ViewerConnectionManager?, usage: UsageOverview? = nil) -> Self {
        let connection = manager?.connection(for: host.id)
        return Self(host: DashboardHost(
            id: host.id, name: host.displayName, isConnected: connection?.isHostConnected == true,
            isSupported: connection?.relayClient.hostSupportsDashboard == true,
            legacyUsage: usage
        )) {
            guard let connection, connection.isHostConnected else { throw ViewerRelayClientError.notConnected }
            let response = try await connection.relayClient.sendCommand(ReadDashboard(), paneId: "").get()
            guard connection.isHostConnected else { throw ViewerRelayClientError.notConnected }
            guard response.success, let snapshot = response.dashboard else {
                throw ViewerRelayClientError.commandFailed(response.error ?? "Dashboard data is unavailable.")
            }
            return snapshot
        }
    }

    fileprivate func fetch() async -> DashboardHost {
        var result = host
        let started = Date()
        do {
            result.snapshot = try await read()
            result.requestedAt = started
            result.receivedAt = Date()
        } catch { result.error = "Could not refresh. Showing the last observation." }
        return result
    }
}

@Observable
@MainActor
final public class DashboardStore {
    public private(set) var hosts: [DashboardHost] = []
    public private(set) var isRefreshing = false
    public private(set) var cacheError: String?
    public private(set) var notificationError: String?
    public private(set) var quotaRecoveryNotices: [DashboardQuotaRecoveryNotice] = []
    public var lowQuotaAlertsEnabled: Bool {
        didSet {
            preferences.setBool(lowQuotaAlertsEnabled, "dashboard.lowQuotaAlerts")
            quotaAlerts = DashboardQuotaAlertTracker()
        }
    }

    @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
    @ObservationIgnored @Dependency(DashboardNotificationClient.self) private var notifications
    @ObservationIgnored private var quotaAlerts = DashboardQuotaAlertTracker()
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var lastSavedAt: Date?
    private static let key = "dashboard.snapshots.v1"
    private static let quotaRecoveryKey = "dashboard.quotaRecoveries.v1"

    public init() {
        @Dependency(PreferencesService.self) var preferences
        self.lowQuotaAlertsEnabled = preferences.optionalBool("dashboard.lowQuotaAlerts") ?? true
        if let data = preferences.data(Self.quotaRecoveryKey) {
            self.quotaRecoveryNotices = (try? JSONDecoder().decode([DashboardQuotaRecoveryNotice].self, from: data)) ?? []
        }
    }

    public func quotaSummaries(at date: Date = Date()) -> [DashboardQuotaSummary] {
        DashboardOverview.accounts(in: hosts).map { DashboardQuotaSummary(group: $0, at: date) }
    }

    public func markQuotaRecoveryRead(_ id: DashboardQuotaRecoveryNotice.ID) {
        guard quotaRecoveryNotices.contains(where: { $0.id == id }) else { return }
        quotaRecoveryNotices.removeAll { $0.id == id }
        saveQuotaRecoveryNotices()
    }

    /// A lightweight account monitor; the open Dashboard still requests its faster resource refresh.
    public func monitor(endpoints: @MainActor () -> [DashboardEndpoint]) async {
        @Dependency(\.continuousClock) var continuousClock
        let clock = AnyClock(continuousClock)
        let initialDeadline = clock.now.advanced(by: .seconds(60))
        var isStarting = true
        while !Task.isCancelled {
            // A replacement monitor must wait for the cancelled read to drain,
            // then resolve the latest connections rather than keep old endpoints.
            while isRefreshing {
                await withCheckedContinuation { refreshWaiters.append($0) }
                guard !Task.isCancelled else { return }
            }
            await refresh(endpoints())
            guard !Task.isCancelled else { return }
            isStarting = isStarting && clock.now < initialDeadline && awaitingInitialQuota
            do { try await clock.sleep(for: isStarting ? .seconds(5) : .seconds(30)) }
            catch { return }
        }
    }

    private var awaitingInitialQuota: Bool {
        hosts.contains { host in
            guard host.isConnected, host.isSupported, host.error == nil else { return false }
            guard let snapshot = host.snapshot else { return true }
            if snapshot.accounts.isEmpty {
                return true
            }
            return snapshot.accounts.contains { account in
                if account.availability == .waiting {
                    return true
                }
                guard
                    account.availability == .available, account.authentication == .signedIn,
                    let observed = account.quotaObservedAt else { return false }
                return snapshot.generatedAt.timeIntervalSince(observed) >= 60
            }
        }
    }

    public func refresh(_ endpoints: [DashboardEndpoint]) async {
        guard !isRefreshing, !Task.isCancelled else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        if !restored {
            restored = true
            if let data = preferences.data(Self.key) {
                do { hosts = try JSONDecoder().decode([DashboardHost].self, from: data) }
                catch { cacheError = "Saved Dashboard data could not be read." }
            }
        }
        let previous = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hosts = endpoints.map { endpoint in
            var host = endpoint.host
            if let cached = previous[host.id] {
                host.snapshot = cached.snapshot
                host.requestedAt = cached.requestedAt
                host.receivedAt = cached.receivedAt
                if host.legacyUsage == nil {
                    host.legacyUsage = cached.legacyUsage
                }
            }
            return host
        }
        await withTaskGroup(of: DashboardHost.self) { group in
            for endpoint in endpoints where endpoint.host.isConnected && endpoint.host.isSupported {
                group.addTask { await endpoint.fetch() }
            }
            for await host in group {
                guard !Task.isCancelled, let index = hosts.firstIndex(where: { $0.id == host.id }) else { continue }
                if host.snapshot != nil {
                    hosts[index] = host
                } else {
                    hosts[index].error = host.error
                }
            }
        }
        guard !Task.isCancelled else { return }
        if lowQuotaAlertsEnabled {
            let tracking = quotaAlerts.updateDetailed(hosts: hosts, at: Date())
            for alert in tracking.alerts {
                do {
                    try await notifications.notify(alert)
                    notificationError = nil
                } catch { notificationError = "Could not deliver a low-quota notification." }
            }
            recordQuotaRecoveries(tracking.recoveries)
        }
        reconcileQuotaRecoveries()
        if lastSavedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            do {
                try preferences.setData(JSONEncoder().encode(hosts), Self.key)
                lastSavedAt = Date()
                cacheError = nil
            } catch { cacheError = "Dashboard data could not be saved for offline viewing." }
        }
    }

    private func recordQuotaRecoveries(_ recoveries: [DashboardQuotaRecoveryNotice]) {
        guard !recoveries.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: quotaRecoveryNotices.map { ($0.id, $0) })
        for recovery in recoveries {
            byID[recovery.id] = recovery
        }
        quotaRecoveryNotices = byID.values.sorted { $0.recoveredAt < $1.recoveredAt }
        saveQuotaRecoveryNotices()
    }

    private func reconcileQuotaRecoveries() {
        // A waiting or failed account snapshot has no stable identity yet, so it
        // cannot prove that a previously known account was removed.
        guard !hasUnresolvedQuotaAccounts else { return }
        let accounts = Set(DashboardOverview.accounts(in: hosts).map { $0.id.quotaRecoveryID })
        let retained = quotaRecoveryNotices.filter { accounts.contains($0.accountID) }
        guard retained.count != quotaRecoveryNotices.count else { return }
        quotaRecoveryNotices = retained
        saveQuotaRecoveryNotices()
    }

    private var hasUnresolvedQuotaAccounts: Bool {
        hosts.contains { host in
            guard let snapshot = host.snapshot else {
                // Disconnect clears the advertised capability before account
                // identity is known. Only a connected Host may definitively
                // report that it does not support the Dashboard.
                return host.isSupported || !host.isConnected
            }
            return snapshot.accounts.contains {
                $0.availability == .waiting || $0.availability == .failed
            }
        }
    }

    private func saveQuotaRecoveryNotices() {
        do {
            let data = try JSONEncoder().encode(quotaRecoveryNotices)
            preferences.setData(data, Self.quotaRecoveryKey)
        } catch {
            cacheError = "Quota recovery notices could not be saved."
        }
    }
}
