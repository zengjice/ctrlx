import Crypto
import CtrlxNetworking
import Foundation
import NIOPosix

struct RelayPrincipal: Sendable {
    let credentialHash: String
    let accountID: String
    let pairID: String?
    let role: String
    let deviceID: String?
}

public struct RelayAccountKey: Codable, Sendable {
    public let accountID: String
    public let key: String
}

/// All database work runs on one dedicated pool thread, never the network loop
/// or Swift's cooperative executor. Transactions also coordinate admin processes.
final public class RelayAccessService: Sendable {
    private let pool: NIOThreadPool
    private let database: RelaySQLite

    private init(pool: NIOThreadPool, database: RelaySQLite) {
        self.pool = pool
        self.database = database
    }

    public static func open(directory: URL) async throws -> RelayAccessService {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        do {
            let database = try await pool.runIfActive {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let path = directory.appendingPathComponent("relay-access.sqlite").path
                let database = try RelaySQLite(path: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                try database.installSchema()
                return database
            }
            return RelayAccessService(pool: pool, database: database)
        } catch {
            try await pool.shutdownGracefully()
            throw error
        }
    }

    public func shutdown() async throws {
        let database = database
        try await pool.runIfActive { try database.close() }
        try await pool.shutdownGracefully()
    }

    func perform<T: Sendable>(_ body: @escaping @Sendable (RelaySQLite) throws -> T) async throws -> T {
        let database = database
        return try await pool.runIfActive { try database.transaction { try body(database) } }
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func newKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    func authenticate(
        _ token: String?,
        pairID: String? = nil,
        role: String? = nil,
        deviceID: String? = nil
    ) async throws -> RelayPrincipal {
        guard let token, (40...128).contains(token.utf8.count) else {
            throw RelayAccessFailure(code: .authenticationRequired, message: "Enter a Relay access key or pair this device again.")
        }
        return try await perform { db in
            let principal = try db.principal(hash: Self.digest(token))
            guard
                pairID == nil || pairID == principal.pairID,
                role == nil || role == principal.role,
                deviceID == nil || deviceID == principal.deviceID else {
                throw RelayAccessFailure(code: .accessDenied, message: "This Relay credential cannot access this device or pairing.")
            }
            try db.requireEnabled(principal.accountID)
            return principal
        }
    }

    func admit(_ principal: RelayPrincipal, bytes: Int, now: Date = Date()) async throws -> RelayQuotaStatus {
        guard bytes >= 0 else { throw RelaySQLite.Failure(description: "Invalid traffic size") }
        return try await perform { db in
            let current = try db.principal(hash: principal.credentialHash)
            guard
                current.accountID == principal.accountID, current.pairID == principal.pairID,
                current.role == principal.role, current.deviceID == principal.deviceID else {
                throw RelayAccessFailure(code: .accessDenied, message: "Relay credential changed. Pair this device again.")
            }
            try db.requireEnabled(current.accountID)
            let status = try db.quota(account: current.accountID, now: now)
            guard Int64(bytes) <= status.remainingBytes else {
                throw RelayAccessFailure(
                    code: .quotaExceeded,
                    message: "Relay traffic quota is insufficient. Add quota or wait for the monthly reset.",
                    quota: status,
                    requiredBytes: Int64(bytes)
                )
            }
            if bytes > 0 {
                try db.query(
                    "UPDATE usage SET used_bytes=used_bytes+? WHERE account_id=? AND period=?",
                    [.integer(Int64(bytes)), .text(current.accountID), .text(status.period)]
                )
                try db.bump(current.accountID)
            }
            return try db.quota(account: current.accountID, now: now)
        }
    }

    public func status(token: String, requireAccount: Bool = false, now: Date = Date()) async throws -> RelayQuotaStatus {
        try await perform { db in
            let principal = try db.principal(hash: Self.digest(token))
            guard !requireAccount || principal.role == "account" else {
                throw RelayAccessFailure(code: .accessDenied, message: "Enter an account access key, not a pairing credential.")
            }
            return try db.quota(account: principal.accountID, now: now)
        }
    }

    public func createAccount(name: String, monthlyBytes: Int64) async throws -> RelayAccountKey {
        guard !name.isEmpty, name.utf8.count <= 128, monthlyBytes >= 0 else {
            throw RelaySQLite.Failure(description: "Invalid account name or quota")
        }
        let key = Self.newKey()
        let account = UUID().uuidString
        return try await perform { db in
            try db.query(
                "INSERT INTO accounts(id,name,monthly_bytes) VALUES(?,?,?)",
                [.text(account), .text(name), .integer(monthlyBytes)]
            )
            try db.query(
                "INSERT INTO credentials(hash,account_id,role) VALUES(?,?,'account')",
                [.text(Self.digest(key)), .text(account)]
            )
            return RelayAccountKey(accountID: account, key: key)
        }
    }

    public func accountStatus(account: String, now: Date = Date()) async throws -> RelayQuotaStatus {
        try await perform { db in try db.quota(account: db.accountID(account), now: now) }
    }

    public func addQuota(
        account: String,
        month: String,
        bytes: Int64,
        requestID: String,
        reason: String,
        now: Date = Date()
    ) async throws -> RelayQuotaStatus {
        guard
            bytes > 0, !requestID.isEmpty, requestID.utf8.count <= 128,
            !reason.isEmpty, reason.utf8.count <= 1_024 else {
            throw RelaySQLite.Failure(description: "Positive quota, request ID and reason are required")
        }
        let start = try RelayBillingPeriod(month: month).start
        return try await perform { db in
            let account = try db.accountID(account)
            if let row = try db.query("SELECT * FROM adjustments WHERE request_id=?", [.text(requestID)]).first {
                guard
                    row["account_id"] == account, row["period"] == month,
                    row["bytes"] == String(bytes), row["reason"] == reason else {
                    throw RelaySQLite.Failure(description: "Request ID already used with different parameters")
                }
                return try db.quota(account: account, now: start)
            }
            // Only existing adjustment retries may address an old period. This
            // also avoids freezing future base allowances before they take effect.
            guard month == RelayBillingPeriod(now: now).id else {
                throw RelaySQLite.Failure(description: "New top-ups must target the current billing month")
            }
            let status = try db.quota(account: account, now: start)
            guard bytes <= Int64.max - status.totalBytes else {
                throw RelaySQLite.Failure(description: "Quota exceeds integer limit")
            }
            try db.query(
                "INSERT INTO adjustments(request_id,account_id,period,bytes,reason,created_at) VALUES(?,?,?,?,?,?)",
                [
                    .text(requestID),
                    .text(account),
                    .text(month),
                    .integer(bytes),
                    .text(reason),
                    .integer(Int64(now.timeIntervalSince1970)),
                ]
            )
            try db.query(
                "UPDATE usage SET extra_bytes=extra_bytes+? WHERE account_id=? AND period=?",
                [.integer(bytes), .text(account), .text(month)]
            )
            try db.bump(account)
            return try db.quota(account: account, now: start)
        }
    }

    public func setAccount(account: String, enabled: Bool? = nil, monthlyBytes: Int64? = nil) async throws {
        guard monthlyBytes.map({ $0 >= 0 }) ?? true else { throw RelaySQLite.Failure(description: "Invalid monthly quota") }
        try await perform { db in
            let account = try db.accountID(account)
            if let enabled {
                try db.query("UPDATE accounts SET enabled=? WHERE id=?", [.integer(enabled ? 1 : 0), .text(account)])
            }
            if let monthlyBytes {
                // Freeze this month's original base before changing the next-month setting.
                _ = try db.quota(account: account, now: Date())
                try db.query("UPDATE accounts SET monthly_bytes=? WHERE id=?", [.integer(monthlyBytes), .text(account)])
            }
            try db.bump(account)
        }
    }

    public func rotateKey(account: String, revokePairs: Bool = false) async throws -> RelayAccountKey {
        let key = Self.newKey()
        return try await perform { db in
            let account = try db.accountID(account)
            try db.query(revokePairs ? "DELETE FROM credentials WHERE account_id=?" : "DELETE FROM credentials WHERE account_id=? AND role='account'", [.text(account)])
            try db.query(
                "INSERT INTO credentials(hash,account_id,role) VALUES(?,?,'account')",
                [.text(Self.digest(key)), .text(account)]
            )
            try db.bump(account)
            return RelayAccountKey(accountID: account, key: key)
        }
    }

    public func revokePair(_ pairID: String) async throws {
        try await perform { db in
            try db.query("DELETE FROM credentials WHERE pair_id=?", [.text(pairID)])
        }
    }
}

struct RelayBillingPeriod {
    let id: String
    let start: Date
    let end: Date

    init(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let interval = calendar.dateInterval(of: .month, for: now)!
        let parts = calendar.dateComponents([.year, .month], from: interval.start)
        self.id = String(format: "%04d-%02d", parts.year!, parts.month!)
        self.start = interval.start
        self.end = interval.end
    }

    init(month: String) throws {
        let parts = month.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 2, let year = Int(parts[0]), (1_970...9_999).contains(year),
            let number = Int(parts[1]), (1...12).contains(number) else {
            throw RelaySQLite.Failure(description: "Month must be YYYY-MM")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        guard let date = calendar.date(from: DateComponents(year: year, month: number, day: 1)) else {
            throw RelaySQLite.Failure(description: "Invalid month")
        }
        self.init(now: date)
        guard id == month else { throw RelaySQLite.Failure(description: "Month must be YYYY-MM") }
    }
}

extension RelaySQLite {
    func installSchema() throws {
        try transaction {
            let version = try query("PRAGMA user_version").first?["user_version"]
            guard version == "0" || version == "1" else { throw Failure(description: "Unsupported Relay database schema") }
            try query("CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,enabled INTEGER NOT NULL DEFAULT 1,monthly_bytes INTEGER NOT NULL CHECK(monthly_bytes>=0),revision INTEGER NOT NULL DEFAULT 0)")
            try query("CREATE TABLE IF NOT EXISTS credentials(hash TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),pair_id TEXT,role TEXT NOT NULL CHECK(role IN ('account','host','viewer')),device_id TEXT)")
            try query("CREATE TABLE IF NOT EXISTS access_pairs(id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),code_hash TEXT UNIQUE,expires_at INTEGER NOT NULL,registration TEXT NOT NULL,pair_json TEXT)")
            try query("CREATE TABLE IF NOT EXISTS usage(account_id TEXT NOT NULL REFERENCES accounts(id),period TEXT NOT NULL,base_bytes INTEGER NOT NULL CHECK(base_bytes>=0),extra_bytes INTEGER NOT NULL DEFAULT 0 CHECK(extra_bytes>=0),used_bytes INTEGER NOT NULL DEFAULT 0 CHECK(used_bytes>=0 AND used_bytes<=base_bytes+extra_bytes),PRIMARY KEY(account_id,period))")
            try query("CREATE TABLE IF NOT EXISTS adjustments(request_id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),period TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>0),reason TEXT NOT NULL,created_at INTEGER NOT NULL)")
            try query("PRAGMA user_version=1")
        }
    }

    func principal(hash: String) throws -> RelayPrincipal {
        guard
            let row = try query("SELECT * FROM credentials WHERE hash=?", [.text(hash)]).first,
            let account = row["account_id"], let role = row["role"] else {
            throw RelayAccessFailure(code: .authenticationRequired, message: "Relay credential expired or was revoked. Authenticate or pair again.")
        }
        if let pair = row["pair_id"] {
            guard
                let record = try query("SELECT * FROM access_pairs WHERE id=?", [.text(pair)]).first,
                record["account_id"] == account,
                record["pair_json"] != nil || (role == "host" && (Int64(record["expires_at"] ?? "") ?? 0) > Int64(Date().timeIntervalSince1970)) else {
                throw RelayAccessFailure(code: .accessDenied, message: "Pairing is invalid or expired. Pair this device again.")
            }
        }
        return RelayPrincipal(credentialHash: hash, accountID: account, pairID: row["pair_id"], role: role, deviceID: row["device_id"])
    }

    func accountID(_ identifier: String) throws -> String {
        guard let id = try query("SELECT id FROM accounts WHERE id=? OR name=?", [.text(identifier), .text(identifier)]).first?["id"] else {
            throw Failure(description: "Unknown Relay account")
        }
        return id
    }

    func requireEnabled(_ account: String) throws {
        guard try query("SELECT enabled FROM accounts WHERE id=?", [.text(account)]).first?["enabled"] == "1" else {
            throw RelayAccessFailure(code: .accountDisabled, message: "This Relay account is disabled. Contact the administrator.")
        }
    }

    func bump(_ account: String) throws {
        try query("UPDATE accounts SET revision=revision+1 WHERE id=?", [.text(account)])
    }

    func quota(account: String, now: Date) throws -> RelayQuotaStatus {
        let period = RelayBillingPeriod(now: now)
        guard
            let row = try query("SELECT * FROM accounts WHERE id=?", [.text(account)]).first,
            let name = row["name"], let monthly = row["monthly_bytes"].flatMap(Int64.init),
            let revision = row["revision"].flatMap(Int64.init) else { throw Failure(description: "Invalid Relay account") }
        try query("INSERT OR IGNORE INTO usage(account_id,period,base_bytes) VALUES(?,?,?)", [.text(account), .text(period.id), .integer(monthly)])
        guard
            let usage = try query("SELECT * FROM usage WHERE account_id=? AND period=?", [.text(account), .text(period.id)]).first,
            let base = usage["base_bytes"].flatMap(Int64.init), let extra = usage["extra_bytes"].flatMap(Int64.init),
            let used = usage["used_bytes"].flatMap(Int64.init) else { throw Failure(description: "Invalid Relay usage") }
        return RelayQuotaStatus(
            accountID: account,
            accountName: name,
            enabled: row["enabled"] == "1",
            period: period.id,
            resetsAt: period.end,
            baseBytes: base,
            extraBytes: extra,
            usedBytes: used,
            revision: revision
        )
    }
}
