import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxExternalServerLib

@Suite("Relay access ledger")
struct RelayAccessLedgerTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-relay-quota-\(UUID().uuidString)")
    }

    @Test("Separate database handles serialize top-ups with traffic and monthly settings preserve the current snapshot")
    func administratorAndRelay() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relay = try await RelayAccessService.open(directory: directory)
        let admin = try await RelayAccessService.open(directory: directory)
        let key = try await admin.createAccount(name: "alice", monthlyBytes: 100)
        let caller = try await relay.authenticate(key.key)
        _ = try await relay.admit(caller, bytes: 90)
        let current = try await relay.status(token: key.key)
        _ = try await admin.addQuota(account: "alice", month: current.period, bytes: 100, requestID: "support", reason: "test")
        _ = try await relay.admit(caller, bytes: 100)
        try await admin.setAccount(account: "alice", monthlyBytes: 500)
        #expect(try await relay.status(token: key.key).baseBytes == 100)
        #expect(try await relay.status(token: key.key).remainingBytes == 10)
        #expect(try await relay.status(token: key.key, now: current.resetsAt).baseBytes == 500)
        try await admin.shutdown()
        try await relay.shutdown()
    }

    @Test("The local admin entry point creates accounts and retries a top-up without duplicating it")
    func adminCommands() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = ["DATA_DIRECTORY": directory.path]
        let output = try await RelayAdmin.run(arguments: ["account", "create", "--name", "alice", "--monthly-quota", "1KiB"], environment: env)
        let key = try JSONDecoder().decode(RelayAccountKey.self, from: Data(output.utf8))
        let command = [
            "quota",
            "add",
            "--account",
            "alice",
            "--month",
            RelayBillingPeriod(now: Date()).id,
            "--amount",
            "2KiB",
            "--request-id",
            "once",
            "--reason",
            "test",
        ]
        for _ in 0..<2 {
            _ = try await RelayAdmin.run(arguments: command, environment: env)
        }
        let store = try await RelayAccessService.open(directory: directory)
        #expect(try await store.status(token: key.key).remainingBytes == 3_072)
        #expect(throws: (any Error).self) { try RelayAdmin.parseBytes("9223372036854775807GiB") }
        #expect(throws: (any Error).self) { try RelayAdmin.parseBytes("-1") }
        try await store.shutdown()
    }

    @Test("Concurrent sockets share one durable allowance")
    func sharedAllowance() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await RelayAccessService.open(directory: directory)
        let key = try await store.createAccount(name: "shared", monthlyBytes: 1_000)
        let principal = try await store.authenticate(key.key, role: "account")
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    do { _ = try await store.admit(principal, bytes: 100)
                        return true
                    } catch let failure as RelayAccessFailure { return failure.code != .quotaExceeded }
                    catch { return true }
                }
            }
            var accepted = 0
            for await result in group {
                if result {
                    accepted += 1
                }
            }
            return accepted
        }
        #expect(accepted == 10)
        #expect(try await store.status(token: key.key).usedBytes == 1_000)
        try await store.shutdown()

        let reopened = try await RelayAccessService.open(directory: directory)
        #expect(try await reopened.status(token: key.key).remainingBytes == 0)
        try await reopened.shutdown()
    }

    @Test("Top-up is transactional and duplicate requests do not add twice")
    func topUp() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await RelayAccessService.open(directory: directory)
        let key = try await store.createAccount(name: "alice", monthlyBytes: 100)
        let principal = try await store.authenticate(key.key)
        _ = try await store.admit(principal, bytes: 80)
        let period = RelayBillingPeriod(now: Date()).id
        for _ in 0..<2 {
            let status = try await store.addQuota(account: "alice", month: period, bytes: 50, requestID: "one", reason: "support")
            #expect(status.remainingBytes == 70)
        }
        await #expect(throws: (any Error).self) {
            try await store.addQuota(account: "alice", month: period, bytes: 60, requestID: "one", reason: "support")
        }
        #expect(try await store.status(token: key.key).usedBytes == 80)
        try await store.shutdown()
    }

    @Test("Account settings and top-ups apply to separate monthly snapshots")
    func monthlySnapshots() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await RelayAccessService.open(directory: directory)
        let key = try await store.createAccount(name: "alice", monthlyBytes: 100)
        let first = try RelayBillingPeriod(month: "2026-11")
        let next = try RelayBillingPeriod(month: "2026-12")
        let principal = try await store.authenticate(key.key)
        _ = try await store.admit(principal, bytes: 90, now: first.start)
        _ = try await store.addQuota(account: key.accountID, month: first.id, bytes: 20, requestID: "nov", reason: "support", now: first.start)
        await #expect(throws: (any Error).self) {
            try await store.addQuota(account: key.accountID, month: next.id, bytes: 20, requestID: "future", reason: "support", now: first.start)
        }
        #expect(try await store.status(token: key.key, now: first.end.addingTimeInterval(-0.1)).remainingBytes == 30)
        #expect(try await store.status(token: key.key, now: next.start).remainingBytes == 100)
        _ = try await store.admit(principal, bytes: 100, now: next.start)
        await #expect(throws: RelayAccessFailure.self) { try await store.admit(principal, bytes: 1, now: next.start) }
        // A late retry for last month's adjustment must not refill this month.
        _ = try await store.addQuota(account: key.accountID, month: first.id, bytes: 20, requestID: "nov", reason: "support", now: next.start)
        #expect(try await store.status(token: key.key, now: next.start).remainingBytes == 0)
        #expect(first.end == next.start)
        #expect(first.start.timeIntervalSince1970 == 1_793_462_400)
        try await store.shutdown()
    }

    @Test("Oversized message preserves the remaining bytes; disabled and revoked credentials stop existing callers")
    func revocation() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await RelayAccessService.open(directory: directory)
        let key = try await store.createAccount(name: "alice", monthlyBytes: 100)
        let principal = try await store.authenticate(key.key)
        await #expect(throws: RelayAccessFailure.self) { try await store.admit(principal, bytes: 101) }
        #expect(try await store.status(token: key.key).remainingBytes == 100)
        try await store.setAccount(account: "alice", enabled: false)
        await #expect(throws: RelayAccessFailure.self) { try await store.admit(principal, bytes: 1) }
        #expect(try await store.status(token: key.key).enabled == false)
        try await store.setAccount(account: "alice", enabled: true)
        let replacement = try await store.rotateKey(account: "alice")
        await #expect(throws: RelayAccessFailure.self) { try await store.admit(principal, bytes: 1) }
        #expect(try await store.status(token: replacement.key).remainingBytes == 100)
        try await store.shutdown()
    }

    @Test("Corrupt storage fails closed and integer overflow does not mutate quota")
    func invalidStorageAndOverflow() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await RelayAccessService.open(directory: directory)
        let key = try await store.createAccount(name: "alice", monthlyBytes: Int64.max)
        await #expect(throws: (any Error).self) {
            try await store.addQuota(
                account: "alice",
                month: RelayBillingPeriod(now: Date()).id,
                bytes: 1,
                requestID: "overflow",
                reason: "invalid"
            )
        }
        #expect(try await store.status(token: key.key).totalBytes == Int64.max)
        try await store.shutdown()
        let corruptDirectory = directory.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: corruptDirectory.appendingPathComponent("relay-access.sqlite"))
        await #expect(throws: (any Error).self) { try await RelayAccessService.open(directory: corruptDirectory) }
    }
}
