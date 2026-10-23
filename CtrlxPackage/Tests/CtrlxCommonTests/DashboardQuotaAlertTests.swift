import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct DashboardQuotaAlertTests {
    private let start = Date(timeIntervalSince1970: 1_792_232_400)
    private let identity = DashboardAccountIdentity(providerID: "codex", accountID: "user", workspaceID: "team", poolID: "codex")

    private func host(_ used: Double, time: Double = 0, name: String = "office", reset: Double = 3_600) -> DashboardHost {
        let date = start.addingTimeInterval(time)
        let account = DashboardAccount(
            id: "default", pluginID: "codex", providerName: "Codex", label: "Personal", configurationLabel: "Default",
            identity: identity, authentication: .signedIn, availability: .available, quotaObservedAt: date,
            windows: [.init(id: "weekly", title: "7 days", usedPercent: used, resetsAt: start.addingTimeInterval(reset))]
        )
        return .init(
            id: name,
            name: name,
            isConnected: true,
            isSupported: true,
            snapshot: .init(hostID: UUID(), generatedAt: date, timeZoneIdentifier: "UTC", accounts: [account]),
            requestedAt: date,
            receivedAt: date
        )
    }

    @Test
    func firstLowReadingIsSilent() {
        var tracker = DashboardQuotaAlertTracker()
        #expect(tracker.update(hosts: [host(95)], at: start).isEmpty)
        #expect(tracker.update(hosts: [host(100, time: 60)], at: start.addingTimeInterval(60)).isEmpty)
    }

    @Test
    func crossingIsOncePerAccountWindowCycle() {
        var tracker = DashboardQuotaAlertTracker()
        #expect(tracker.update(hosts: [host(89)], at: start).isEmpty)
        let alerts = tracker.update(hosts: [host(90, time: 60)], at: start.addingTimeInterval(60))
        #expect(alerts.count == 1)
        #expect(alerts.first?.body.contains("10% remaining") == true)
        #expect(tracker.update(hosts: [host(80, time: 120)], at: start.addingTimeInterval(120)).isEmpty)
        #expect(tracker.update(hosts: [host(95, time: 180)], at: start.addingTimeInterval(180)).isEmpty)
        #expect(tracker.update(hosts: [host(5, time: 3_601, reset: 7_200)], at: start.addingTimeInterval(3_601)).isEmpty)
        #expect(tracker.update(hosts: [host(92, time: 3_661, reset: 7_200)], at: start.addingTimeInterval(3_661)).count == 1)
    }

    @Test
    func sharedAccountAcrossHostsProducesOneAlert() {
        var tracker = DashboardQuotaAlertTracker()
        _ = tracker.update(hosts: [host(80), host(80, name: "home")], at: start)
        let alerts = tracker.update(hosts: [host(95, time: 60), host(95, time: 60, name: "home")], at: start.addingTimeInterval(60))
        #expect(alerts.count == 1)
        #expect(alerts.first?.hosts == "home, office")
    }

    @Test
    func differentAccountsDoNotShareBaselines() {
        var tracker = DashboardQuotaAlertTracker()
        _ = tracker.update(hosts: [host(80)], at: start)
        var changed = host(95, time: 60)
        changed.snapshot?.accounts[0].identity?.accountID = "other"
        #expect(tracker.update(hosts: [changed], at: start.addingTimeInterval(60)).isEmpty)
    }

    @Test(arguments: ["offline", "failed", "stale", "future", "expired", "signedOut", "unknown", "unverified", "invalid"])
    func unusableReadingsCannotAlert(reason: String) {
        var tracker = DashboardQuotaAlertTracker()
        _ = tracker.update(hosts: [host(80)], at: start)
        var low = host(95, time: 60)
        switch reason {
        case "offline": low.isConnected = false
        case "failed": low.snapshot?.accounts[0].availability = .failed
        case "stale": low.snapshot?.accounts[0].quotaObservedAt = start.addingTimeInterval(-600)
        case "future": low.requestedAt = start.addingTimeInterval(600)
            low.receivedAt = low.requestedAt
        case "expired": low.snapshot?.accounts[0].windows[0].resetsAt = start
        case "signedOut": low.snapshot?.accounts[0].authentication = .signedOut
        case "unknown": low.snapshot?.accounts[0].authentication = .unknown
        case "unverified": low.snapshot?.accounts[0].identity = nil
        default: low.snapshot?.accounts[0].windows[0].usedPercent = .nan
        }
        #expect(tracker.update(hosts: [low], at: start.addingTimeInterval(60)).isEmpty)
        let summary = DashboardQuotaSummary(group: DashboardOverview.accounts(in: [low])[0], at: start.addingTimeInterval(60))
        #expect(!summary.isLow)
    }

    @Test
    func conflictingSourcesAreNotUrgent() {
        var tracker = DashboardQuotaAlertTracker()
        _ = tracker.update(hosts: [host(80)], at: start)
        let hosts = [host(95, time: 60), host(70, time: 60, name: "home")]
        #expect(tracker.update(hosts: hosts, at: start.addingTimeInterval(60)).isEmpty)
        let summary = DashboardQuotaSummary(group: DashboardOverview.accounts(in: hosts)[0], at: start.addingTimeInterval(60))
        #expect(!summary.isLow)
    }

    @Test
    func reconnectAndStalenessDoNotReplayACycleAlert() {
        var tracker = DashboardQuotaAlertTracker()
        _ = tracker.update(hosts: [host(80)], at: start)
        #expect(tracker.update(hosts: [host(95, time: 60)], at: start.addingTimeInterval(60)).count == 1)
        var offline = host(80, time: 120)
        offline.isConnected = false
        #expect(tracker.update(hosts: [offline], at: start.addingTimeInterval(120)).isEmpty)
        #expect(tracker.update(hosts: [host(80, time: 600)], at: start.addingTimeInterval(600)).isEmpty)
        #expect(tracker.update(hosts: [host(95, time: 660)], at: start.addingTimeInterval(660)).isEmpty)
    }

    @Test
    func newCycleAlreadyLowAndLateFirstObservationAreSilent() {
        var tracker = DashboardQuotaAlertTracker()
        _ = tracker.update(hosts: [host(80)], at: start)
        #expect(tracker.update(hosts: [host(95, time: 600)], at: start.addingTimeInterval(600)).isEmpty)
        #expect(tracker.update(hosts: [host(95, time: 3_601, reset: 7_200)], at: start.addingTimeInterval(3_601)).isEmpty)
    }

    @Test(arguments: [-86_400.0, 86_400.0])
    func summaryUsesProviderResetDeadlineDespiteHostClockSkew(skew: Double) {
        var sample = host(95)
        sample.snapshot?.generatedAt = start.addingTimeInterval(skew)
        sample.snapshot?.accounts[0].quotaObservedAt = start.addingTimeInterval(skew)
        sample.snapshot?.accounts[0].windows.append(.init(id: "short", title: "5 hours", usedPercent: 10))
        let summary = DashboardQuotaSummary(group: DashboardOverview.accounts(in: [sample])[0], at: start)
        #expect(summary.isLow)
        #expect(summary.remaining == 5)
        #expect(summary.window == "7 days")
    }

    @Test
    func recoveryRequiresALowBaselineAndIsEmittedOnce() {
        var tracker = DashboardQuotaAlertTracker()
        #expect(tracker.updateDetailed(hosts: [host(10)], at: start).recoveries.isEmpty)
        #expect(tracker.updateDetailed(hosts: [host(95, time: 60)], at: start.addingTimeInterval(60)).recoveries.isEmpty)

        let recovered = tracker.updateDetailed(hosts: [host(10, time: 120)], at: start.addingTimeInterval(120))
        #expect(recovered.recoveries.count == 1)
        #expect(recovered.recoveries.first?.windows.first?.contains("90% remaining") == true)
        #expect(tracker.updateDetailed(hosts: [host(20, time: 180)], at: start.addingTimeInterval(180)).recoveries.isEmpty)
    }

    @Test
    func unavailableRecoveryObservationDoesNotCreateANotice() {
        var tracker = DashboardQuotaAlertTracker()
        _ = tracker.updateDetailed(hosts: [host(95)], at: start)
        var offline = host(10, time: 60)
        offline.isConnected = false
        #expect(tracker.updateDetailed(hosts: [offline], at: start.addingTimeInterval(60)).recoveries.isEmpty)
    }
}
