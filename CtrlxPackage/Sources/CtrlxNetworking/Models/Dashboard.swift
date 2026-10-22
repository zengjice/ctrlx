import Foundation

/// Only provider-issued identities may merge an account across Hosts.
public struct DashboardAccountIdentity: Codable, Equatable, Hashable, Sendable {
    public var providerID: String
    public var accountID: String
    public var workspaceID: String
    public var poolID: String

    public init(providerID: String, accountID: String, workspaceID: String, poolID: String) {
        self.providerID = providerID
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.poolID = poolID
    }
}

public struct DashboardQuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var durationMinutes: Int?
    public var resetsAt: Date?

    public init(id: String, title: String, usedPercent: Double, durationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public func remainingPercent(at date: Date) -> Double? {
        guard usedPercent.isFinite, usedPercent >= 0, resetsAt.map({ $0 > date }) ?? true else { return nil }
        return max(0, 100 - usedPercent)
    }
}

public struct DashboardAccount: Codable, Equatable, Sendable, Identifiable {
    public enum Authentication: String, Codable, Sendable { case signedIn, signedOut, unknown }
    public enum Availability: String, Codable, Sendable { case available, waiting, unsupported, failed }

    /// Stable within this Host/configuration, including the quota pool.
    public var id: String
    public var pluginID: String
    public var providerName: String
    public var label: String
    public var configurationLabel: String
    public var identity: DashboardAccountIdentity?
    public var authentication: Authentication
    public var availability: Availability
    public var detail: String?
    /// Time the quota was read, not the time a cached value was sent to a Viewer.
    public var quotaObservedAt: Date?
    public var windows: [DashboardQuotaWindow]
    public var credits: DashboardCredits?
    public var limitReached: Bool?

    public init(
        id: String, pluginID: String, providerName: String, label: String, configurationLabel: String,
        identity: DashboardAccountIdentity? = nil, authentication: Authentication = .unknown,
        availability: Availability = .waiting, detail: String? = nil,
        quotaObservedAt: Date? = nil, windows: [DashboardQuotaWindow] = [],
        credits: DashboardCredits? = nil, limitReached: Bool? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.providerName = providerName
        self.label = label
        self.configurationLabel = configurationLabel
        self.identity = identity
        self.authentication = authentication
        self.availability = availability
        self.detail = detail
        self.quotaObservedAt = quotaObservedAt
        self.windows = windows
        self.credits = credits
        self.limitReached = limitReached
    }
}

public struct DashboardCredits: Codable, Equatable, Sendable {
    public var balance: String?
    public var unlimited: Bool

    public init(balance: String?, unlimited: Bool) {
        self.balance = balance
        self.unlimited = unlimited
    }
}

public struct DashboardMemory: Codable, Equatable, Sendable {
    public enum Pressure: String, Codable, Sendable { case normal, warning, critical, unknown }
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var compressedBytes: UInt64
    public var swapBytes: UInt64
    public var pressure: Pressure

    public init(totalBytes: UInt64, usedBytes: UInt64, compressedBytes: UInt64, swapBytes: UInt64, pressure: Pressure) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.compressedBytes = compressedBytes
        self.swapBytes = swapBytes
        self.pressure = pressure
    }
}

public struct DashboardDisk: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64

    public init(id: String, name: String, totalBytes: UInt64, availableBytes: UInt64) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

public struct DashboardResources: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var cpuPercent: Double?
    public var memory: DashboardMemory?
    public var disksObservedAt: Date?
    public var disks: [DashboardDisk]
    public var issues: [String: String]

    public init(
        observedAt: Date, cpuPercent: Double? = nil, memory: DashboardMemory? = nil,
        disksObservedAt: Date? = nil, disks: [DashboardDisk] = [], issues: [String: String] = [:]
    ) {
        self.observedAt = observedAt
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.disksObservedAt = disksObservedAt
        self.disks = disks
        self.issues = issues
    }
}

/// One Host's independent, bounded snapshot. It never contains credentials.
public struct DashboardSnapshot: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var generatedAt: Date
    public var timeZoneIdentifier: String
    public var resources: DashboardResources?
    public var accounts: [DashboardAccount]
    public var usage: UsageOverview?
    public var workingAgentCount: Int?

    public init(
        hostID: UUID, generatedAt: Date, timeZoneIdentifier: String,
        resources: DashboardResources? = nil, accounts: [DashboardAccount] = [],
        usage: UsageOverview? = nil, workingAgentCount: Int? = nil
    ) {
        self.hostID = hostID
        self.generatedAt = generatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.resources = resources
        self.accounts = accounts
        self.usage = usage
        self.workingAgentCount = workingAgentCount
    }
}
