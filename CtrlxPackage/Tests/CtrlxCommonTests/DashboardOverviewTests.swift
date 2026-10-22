import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct DashboardOverviewTests {
    private let now = Date(timeIntervalSince1970: 1_792_232_400)
    private let identity = DashboardAccountIdentity(providerID: "codex", accountID: "person", workspaceID: "personal", poolID: "codex")

    private func account(used: Double = 54, identity: DashboardAccountIdentity? = nil, observed: Date? = nil) -> DashboardAccount {
        .init(
            id: "default", pluginID: "codex", providerName: "Codex", label: "Personal", configurationLabel: "Default",
            identity: identity, authentication: .signedIn, availability: .available, quotaObservedAt: observed ?? now,
            windows: [.init(id: "weekly", title: "7 days", usedPercent: used, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))]
        )
    }

    private func host(
        _ id: String, account: DashboardAccount, hostID: UUID = UUID(),
        generated: Date? = nil, requested: Date? = nil, received: Date? = nil
    ) -> DashboardHost {
        .init(
            id: id, name: id, isConnected: true, isSupported: true,
            snapshot: .init(hostID: hostID, generatedAt: generated ?? now, timeZoneIdentifier: "UTC", accounts: [account]),
            requestedAt: requested ?? now, receivedAt: received ?? now.addingTimeInterval(1)
        )
    }

    @Test
    func sharedAccountIsNotSummedAndDifferentWorkspaceIsSeparate() {
        var team = identity
        team.workspaceID = "team"
        let hosts = [host("office", account: account(identity: identity)), host("home", account: account(identity: identity)), host("team", account: account(identity: team))]
        let groups = DashboardOverview.accounts(in: hosts)
        #expect(groups.count == 2)
        #expect(groups[0].sources.count == 2)
        #expect(groups[0].selection?.source.account.windows.first?.remainingPercent(at: now) == 46)
    }

    @Test
    func sameDisplayNameWithoutIdentityNeverMerges() {
        let groups = DashboardOverview.accounts(in: [host("office", account: account()), host("home", account: account())])
        #expect(groups.count == 2)
    }

    @Test
    func cachedReplyReceivedLaterCannotReplaceNewQuota() throws {
        let fresh = host("office", account: account(used: 80, identity: identity))
        let old = host(
            "home",
            account: account(used: 20, identity: identity, observed: now.addingTimeInterval(-600)),
            generated: now.addingTimeInterval(30),
            requested: now.addingTimeInterval(30),
            received: now.addingTimeInterval(31)
        )
        for hosts in [[fresh, old], [old, fresh]] {
            let group = try #require(DashboardOverview.accounts(in: hosts).first)
            #expect(group.selection?.source.host.id == "office")
            #expect(group.selection?.uncertain == false)
        }
    }

    @Test
    func hostClockSkewUsesSampleAgeAndOverlappingSamplesAreUncertain() throws {
        let skew = now.addingTimeInterval(86_400)
        let a = host("office", account: account(used: 60, identity: identity))
        let b = host("home", account: account(used: 80, identity: identity, observed: skew), generated: skew)
        let group = try #require(DashboardOverview.accounts(in: [a, b]).first)
        #expect(group.selection?.uncertain == true)
        #expect(group.selection?.source.host.id == "office")
    }

    @Test
    func resetDoesNotInventQuotaAndFailedLoginIsSourceSpecific() throws {
        let quota = DashboardQuotaWindow(id: "short", title: "5 hours", usedPercent: 100, resetsAt: now)
        #expect(quota.remainingPercent(at: now) == nil)
        var signedOut = account(identity: identity)
        signedOut.authentication = .signedOut
        signedOut.availability = .failed
        signedOut.windows = []
        let group = try #require(DashboardOverview.accounts(in: [host("office", account: signedOut), host("home", account: account(identity: identity))]).first)
        #expect(group.sources.count == 2)
        #expect(group.selection?.source.host.id == "home")
        #expect(group.sources[0].account.authentication == .signedOut)
    }

    @Test
    func localAndPairedHostAreCountedOnce() {
        let hostID = UUID()
        var local = host("local", account: account(identity: identity), hostID: hostID)
        local.isLocal = true
        let paired = host("paired", account: account(identity: identity), hostID: hostID)
        #expect(DashboardOverview.uniqueHosts([paired, local]).map(\.id) == ["local"])
        #expect(DashboardOverview.accounts(in: [local, paired]).first?.sources.count == 1)
    }

    @Test
    func dayBoundaryExcludesYesterdayAndOfflineCacheIsIncomplete() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-17T23:59:00Z"))
        var current = host("office", account: account(), generated: date, requested: date, received: date)
        current.snapshot?.usage = .init(generatedDay: "2026-10-17", todayTokens: 120, todaySessionCount: 2)
        #expect(DashboardOverview.usage(in: [current], at: date).tokens == 120)
        current.isConnected = false
        let cached = DashboardOverview.usage(in: [current], at: date)
        #expect(cached.tokens == 120)
        #expect(cached.currentHosts == 0)
        #expect(DashboardOverview.usage(in: [current], at: date.addingTimeInterval(120)).tokens == 0)
        current.snapshot?.timeZoneIdentifier = "Asia/Shanghai"
        #expect(current.currentUsage(at: date) == nil)
        current.snapshot?.usage?.generatedDay = "2026-10-18"
        #expect(current.currentUsage(at: date)?.todayTokens == 120)
    }

    @Test
    func wireRoundTripPreservesUnknownValues() throws {
        let original = try #require(host("office", account: account()).snapshot)
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.resources == nil)
        #expect(decoded.accounts.first?.identity == nil)
    }
}
