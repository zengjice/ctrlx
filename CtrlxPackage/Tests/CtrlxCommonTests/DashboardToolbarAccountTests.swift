import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct DashboardToolbarAccountTests {
    private let now = Date(timeIntervalSince1970: 1_792_232_400)

    private func host(name: String = "office", used: Double = 50, user: String = "user") -> DashboardHost {
        .init(
            id: name, name: name, isConnected: true, isSupported: true,
            snapshot: .init(hostID: UUID(), generatedAt: now, timeZoneIdentifier: "UTC", accounts: [
                .init(
                    id: "default", pluginID: "codex", providerName: "Codex", label: user, configurationLabel: "Default",
                    identity: .init(providerID: "codex", accountID: user, workspaceID: "personal", poolID: "codex"),
                    authentication: .signedIn, availability: .available, quotaObservedAt: now,
                    windows: [.init(id: "weekly", title: "7 days", usedPercent: used, resetsAt: now.addingTimeInterval(3_600))]
                ),
            ]),
            requestedAt: now, receivedAt: now
        )
    }

    @Test(arguments: [(0.0, DashboardToolbarAccount.Level.normal), (79.0, .normal), (80.0, .warning), (89.0, .warning), (90.0, .low), (100.0, .low)])
    func thresholds(used: Double, level: DashboardToolbarAccount.Level) {
        let item = DashboardToolbarAccount.accounts(in: [host(used: used)], at: now)[0]
        #expect(item.remaining == 100 - used)
        #expect(item.level == level)
    }

    @Test
    func allConstraintsAndExplicitExhaustionAreVisible() {
        var sample = host()
        sample.snapshot?.accounts[0].windows.append(.init(id: "short", title: "5 hours", usedPercent: 95))
        #expect(DashboardToolbarAccount.accounts(in: [sample], at: now)[0].remaining == 5)
        sample.snapshot?.accounts[0].limitReached = true
        let exhausted = DashboardToolbarAccount.accounts(in: [sample], at: now)[0]
        #expect(exhausted.remaining == 0)
        #expect(exhausted.status == "Limit reached")
    }

    @Test(arguments: ["offline", "failed", "error", "stale", "transportStale", "expired", "invalid", "signedOut", "unverified", "empty"])
    func unavailableIsGrayAndRetainsObservation(reason: String) {
        var sample = host()
        switch reason {
        case "offline": sample.isConnected = false
        case "failed": sample.snapshot?.accounts[0].availability = .failed
        case "error": sample.error = "Could not refresh"
        case "stale": sample.snapshot?.accounts[0].quotaObservedAt = now.addingTimeInterval(-301)
        case "transportStale": sample.receivedAt = now.addingTimeInterval(-121)
            sample.requestedAt = sample.receivedAt
        case "expired": sample.snapshot?.accounts[0].windows.append(.init(id: "short", title: "5 hours", usedPercent: 99, resetsAt: now))
        case "invalid": sample.snapshot?.accounts[0].windows[0].usedPercent = .nan
        case "signedOut": sample.snapshot?.accounts[0].authentication = .signedOut
        case "unverified": sample.snapshot?.accounts[0].identity = nil
        default: sample.snapshot?.accounts[0].windows = []
        }
        let item = DashboardToolbarAccount.accounts(in: [sample], at: now)[0]
        #expect(item.remaining == nil)
        #expect(item.level == .unknown)
        #expect(item.status != nil)
        #expect(item.account == sample.snapshot?.accounts[0] || reason == "invalid")
    }

    @Test
    func groupingAndOrderingAreIndependentOfQuotaAndHostSelection() {
        let a = host(user: "A")
        var b = host(name: "home", used: 95, user: "B")
        let sameA = host(name: "laptop", user: "A")
        let first = DashboardToolbarAccount.accounts(in: [b, a, sameA], at: now)
        #expect(first.count == 2)
        #expect(first[0].group.sources.count == 2)
        b.snapshot?.accounts[0].windows[0].usedPercent = 10
        b.snapshot?.accounts[0].label = "Renamed"
        let second = DashboardToolbarAccount.accounts(in: [sameA, a, b], at: now)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test(arguments: ["codex", "claude-code"])
    func unsupportedAccountsRemainInDashboardOnly(pluginID: String) {
        var api = host(name: "api", user: "API account")
        api.snapshot?.accounts[0].pluginID = pluginID
        api.snapshot?.accounts[0].identity = nil
        api.snapshot?.accounts[0].availability = .unsupported
        api.snapshot?.accounts[0].windows = []
        api.snapshot?.accounts[0].quotaObservedAt = nil
        let subscription = host(name: "subscription", user: "Subscription")

        let dashboard = DashboardOverview.accounts(in: [api, subscription])
        #expect(dashboard.count == 2)
        #expect(dashboard.contains { $0.selection?.source.account == api.snapshot?.accounts[0] })
        let toolbar = DashboardToolbarAccount.accounts(in: [api, subscription], at: now)
        #expect(toolbar.count == 1)
        #expect(toolbar.first?.account.label == "Subscription")
        #expect(DashboardToolbarAccount.accounts(in: [api], at: now).isEmpty)
    }

    @Test
    func ambiguousObservationsStayGray() {
        let item = DashboardToolbarAccount.accounts(in: [host(), host(name: "home", used: 90)], at: now)[0]
        #expect(item.remaining == nil)
        #expect(item.status?.contains("Sources disagree") == true)
    }

    @Test
    func resetCannotRefillWithoutANewReading() {
        let sample = host(used: 100)
        let expired = DashboardToolbarAccount.accounts(in: [sample], at: now.addingTimeInterval(3_601))[0]
        #expect(expired.remaining == nil)
        #expect(expired.account.windows[0].usedPercent == 100)
    }
}
