import Foundation

public struct RelayAccessStatus: Codable, Sendable, Equatable {
    public let metered: Bool
    public let quota: RelayQuotaStatus?
    public let failure: RelayAccessFailure?

    public init(metered: Bool, quota: RelayQuotaStatus? = nil, failure: RelayAccessFailure? = nil) {
        self.metered = metered
        self.quota = quota
        self.failure = failure
    }
}

/// Relay-owned billing metadata; contains no terminal or file contents.
public struct RelayQuotaStatus: Codable, Sendable, Equatable {
    public let accountID: String
    public let accountName: String
    public let enabled: Bool
    public let period: String
    public let resetsAt: Date
    public let baseBytes: Int64
    public let extraBytes: Int64
    public let usedBytes: Int64
    public let revision: Int64

    public var totalBytes: Int64 {
        baseBytes + extraBytes
    }

    public var remainingBytes: Int64 {
        totalBytes - usedBytes
    }

    public init(
        accountID: String,
        accountName: String,
        enabled: Bool,
        period: String,
        resetsAt: Date,
        baseBytes: Int64,
        extraBytes: Int64,
        usedBytes: Int64,
        revision: Int64
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.enabled = enabled
        self.period = period
        self.resetsAt = resetsAt
        self.baseBytes = baseBytes
        self.extraBytes = extraBytes
        self.usedBytes = usedBytes
        self.revision = revision
    }
}

public struct RelayAccessFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case authenticationRequired = "RELAY_AUTH_REQUIRED"
        case accessDenied = "RELAY_ACCESS_DENIED"
        case accountDisabled = "RELAY_ACCOUNT_DISABLED"
        case quotaExceeded = "RELAY_QUOTA_EXCEEDED"
        case unavailable = "RELAY_LEDGER_UNAVAILABLE"
        case rateLimited = "RELAY_RATE_LIMITED"
    }

    public let code: Code
    public let message: String
    public let quota: RelayQuotaStatus?
    public let requiredBytes: Int64?
    public var errorDescription: String? {
        message
    }

    public init(code: Code, message: String, quota: RelayQuotaStatus? = nil, requiredBytes: Int64? = nil) {
        self.code = code
        self.message = message
        self.quota = quota
        self.requiredBytes = requiredBytes
    }
}
