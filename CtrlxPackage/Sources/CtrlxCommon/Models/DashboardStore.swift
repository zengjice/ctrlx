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
    public var lowQuotaAlertsEnabled: Bool {
        didSet {
            preferences.setBool(lowQuotaAlertsEnabled, "dashboard.lowQuotaAlerts")
            quotaAlerts = DashboardQuotaAlertTracker()
        }
    }

    @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
    @ObservationIgnored @Dependency(DashboardNotificationClient.self) private var notifications
    @ObservationIgnored private var quotaAlerts = DashboardQuotaAlertTracker()
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var lastSavedAt: Date?
    private static let key = "dashboard.snapshots.v1"

    public init() {
        @Dependency(PreferencesService.self) var preferences
        self.lowQuotaAlertsEnabled = preferences.optionalBool("dashboard.lowQuotaAlerts") ?? true
    }

    public func quotaSummaries(at date: Date = Date()) -> [DashboardQuotaSummary] {
        DashboardOverview.accounts(in: hosts).map { DashboardQuotaSummary(group: $0, at: date) }
    }

    /// A lightweight account monitor; the open Dashboard still requests its faster resource refresh.
    public func monitor(endpoints: @MainActor () -> [DashboardEndpoint]) async {
        while !Task.isCancelled {
            await refresh(endpoints())
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
        }
    }

    public func refresh(_ endpoints: [DashboardEndpoint]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
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
            for alert in quotaAlerts.update(hosts: hosts, at: Date()) {
                do {
                    try await notifications.notify(alert)
                    notificationError = nil
                } catch { notificationError = "Could not deliver a low-quota notification." }
            }
        }
        if lastSavedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            do {
                try preferences.setData(JSONEncoder().encode(hosts), Self.key)
                lastSavedAt = Date()
                cacheError = nil
            } catch { cacheError = "Dashboard data could not be saved for offline viewing." }
        }
    }
}
