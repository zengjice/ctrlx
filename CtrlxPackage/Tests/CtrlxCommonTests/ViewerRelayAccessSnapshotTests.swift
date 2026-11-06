import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Viewer Relay account grouping")
struct ViewerRelayAccessSnapshotTests {
    @Test("Hosts sharing an account show one allowance and retain Host order")
    func sharedAccount() throws {
        let state = snapshot(["a": response(), "b": response(used: 70, revision: 2), "c": response(account: "other")])
        #expect(state.accounts.count == 2)
        let account = try #require(state.accounts.first)
        #expect(account.hosts.map(\.id) == ["a", "b"])
        #expect(account.quota.usedBytes == 70)
        #expect(account.quota.totalBytes == 100)
        #expect(state.unresolvedHosts.isEmpty)
    }

    @Test("Account IDs, Relay addresses and monthly revisions determine the grouping")
    func identityAndFreshness() {
        let current = response(used: 60, revision: 10)
        let stale = response(used: 5, revision: 9)
        let state = snapshot(["a": current, "b": stale, "c": response(account: "other")])
        #expect(state.accounts.count == 2) // Display names intentionally match.
        #expect(state.accounts.first?.quota.usedBytes == 60)
        let otherRelay = snapshot(["a": current], server: "wss://other.example.com")
        #expect(state.accounts.first?.id != otherRelay.accounts.first?.id)
        let nextMonth = snapshot(["a": current, "b": response(used: 0, period: "2026-12", revision: 10)])
        #expect(nextMonth.accounts.first?.quota.period == "2026-12")
    }

    @Test("Revoked and failed pairings stay visible without borrowing a sibling's identity")
    func perHostFailure() {
        let revoked = RelayAccessStatus(metered: true, failure: .init(code: .authenticationRequired, message: "revoked"))
        let state = snapshot([
            "a": response(),
            "b": .init(status: revoked, error: nil),
            "c": .init(status: nil, error: "offline"),
        ])
        #expect(state.accounts.count == 1)
        #expect(state.accounts.first?.hosts.map(\.id) == ["a"])
        #expect(state.unresolvedHosts.map(\.id) == ["b", "c"])
        #expect(state.responses["b"]?.status?.failure?.message == "revoked")
        #expect(state.responses["c"]?.error == "offline")
    }

    @Test("Unmetered and old Relays do not leave empty quota cards")
    func unmetered() {
        let state = snapshot(["a": .init(status: .init(metered: false), error: nil)], hosts: [host("a")])
        #expect(state.accounts.isEmpty)
        #expect(state.unresolvedHosts.isEmpty)
    }

    @Test("Retry is limited to the requested account and validates each Host's own response")
    func reconnectScope() throws {
        let state = snapshot(["a": response(), "b": response(account: "other"), "c": response(used: 100)])
        let account = try #require(state.accounts.first?.id)
        #expect(state.reconnectableHostIDs(in: account, candidates: state.hosts, restriction: { _ in nil }) == ["a"])
        let revoked = RelayAccessFailure(code: .authenticationRequired, message: "revoked")
        #expect(state.reconnectableHostIDs(in: account, candidates: state.hosts, restriction: { _ in revoked }).isEmpty)
        let needsMore = RelayAccessFailure(code: .quotaExceeded, message: "quota", quota: quota(), requiredBytes: 100)
        #expect(state.reconnectableHostIDs(in: account, candidates: state.hosts, restriction: { _ in needsMore }).isEmpty)
        let moved = snapshot(["a": response(account: "new"), "b": response(account: "other")])
        #expect(moved.reconnectableHostIDs(in: account, candidates: [host("a")], restriction: { _ in nil }).isEmpty)
    }

    @Test("Each pairing is authenticated separately and a failed query does not discard other accounts")
    func fetching() async {
        let client = RelayAccessClient(status: { server, pair, role in
            #expect(server == "wss://relay.example.com")
            #expect(role == "viewer")
            switch pair {
            case "a": return .init(metered: true, quota: quota())
            case "b": throw URLError(.cannotConnectToHost)
            case "c": return .init(metered: true, quota: quota(account: "other"))
            default: throw URLError(.badURL)
            }
        }, removePair: { _, _, _ in
            Issue.record("Unexpected pairing removal")
        }, validateKey: { _, _ in
            Issue.record("Viewer must not request an account key")
            throw URLError(.badURL)
        })
        let hosts = [host("a"), host("b"), host("c")]
        let result = await ViewerRelayAccessSnapshot.fetch(server: "wss://relay.example.com", hosts: hosts, client: client)
        #expect(result.count == 3)
        #expect(result["a"]?.quota?.accountID == "shared")
        #expect(result["b"]?.error != nil)
        #expect(result["c"]?.quota?.accountID == "other")
    }

    private func snapshot(_ responses: [String: ViewerRelayAccessSnapshot.Response], server: String = "wss://relay.example.com", hosts: [PairedHost]? = nil) -> ViewerRelayAccessSnapshot {
        ViewerRelayAccessSnapshot(server: server, hosts: hosts ?? [host("a"), host("b"), host("c")], responses: responses)
    }

    private func host(_ id: String) -> PairedHost {
        PairedHost(id: id, hostName: id.uppercased(), username: "test", partnerPublicKey: "", partnerPublicKeyId: "")
    }

    private func response(account: String = "shared", used: Int64 = 10, period: String = "2026-11", revision: Int64 = 1) -> ViewerRelayAccessSnapshot.Response {
        .init(status: .init(metered: true, quota: quota(account: account, used: used, period: period, revision: revision)), error: nil)
    }

    private func quota(account: String = "shared", used: Int64 = 10, period: String = "2026-11", revision: Int64 = 1) -> RelayQuotaStatus {
        .init(accountID: account, accountName: "personal", enabled: true, period: period, resetsAt: Date(timeIntervalSince1970: 1_796_054_400), baseBytes: 100, extraBytes: 0, usedBytes: used, revision: revision)
    }
}
