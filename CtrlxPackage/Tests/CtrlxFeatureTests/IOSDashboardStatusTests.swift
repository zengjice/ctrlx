import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@Suite("iOS Dashboard status")
struct IOSDashboardStatusTests {
    private let now = Date(timeIntervalSince1970: 1_792_232_400)

    private func status(
        paired: Set<String> = ["office", "home"], connected: Set<String> = ["office", "home"],
        connecting: Bool = false, panes: [PaneKey: PaneState] = [:], hosts: [DashboardHost] = [], elapsed: Double = 0
    ) -> IOSDashboardStatus {
        .init(
            pairedHostIDs: paired, connectedHostIDs: connected, isConnecting: connecting,
            paneStates: panes, dashboardHosts: hosts, at: now.addingTimeInterval(elapsed)
        )
    }

    private func host(_ id: String, used: Double = 95, provider: String = "codex") -> DashboardHost {
        .init(
            id: id, name: id, isConnected: true, isSupported: true,
            snapshot: .init(hostID: UUID(), generatedAt: now, timeZoneIdentifier: "UTC", accounts: [
                .init(
                    id: "default", pluginID: provider, providerName: provider, label: "Account", configurationLabel: "Default",
                    identity: .init(providerID: provider, accountID: "user", workspaceID: "team", poolID: provider),
                    authentication: .signedIn, availability: .available, quotaObservedAt: now,
                    windows: [.init(id: "weekly", title: "7 days", usedPercent: used, resetsAt: now.addingTimeInterval(3_600))]
                ),
            ]),
            requestedAt: now, receivedAt: now
        )
    }

    @Test("Connection states use only currently paired Hosts")
    func connections() {
        #expect(status().connection == .connected)
        #expect(status(connected: ["office", "removed"]).connection == .partial)
        #expect(status(connected: ["office", "removed"]).connectedCount == 1)
        #expect(status(connected: ["removed"], connecting: true).connection == .connecting)
        #expect(status(connected: []).connection == .disconnected)
        #expect(status(paired: [], connecting: true).connection == .unpaired)
        #expect(status(paired: []).hostCount == 0)
        #expect(status(connected: ["office"]).connectionDescription == "1 of 2 Hosts connected")
    }

    @Test("Attention follows Mac semantics without merging matching names or pane IDs across Hosts")
    func attentionAcrossHosts() {
        let done = PaneState(paneId: "%1", sessionName: "work", agentSession: .init(paneId: "%1", state: .doneWorking(summary: nil)))
        let terminal = PaneState(paneId: "%2", sessionName: "shell", cliSessionState: .waiting)
        var panes: [PaneKey: PaneState] = [:]
        for host in ["office", "home", "removed"] {
            panes[.init(pairId: host, paneId: "%1")] = done
            panes[.init(pairId: host, paneId: "%2")] = terminal
            panes[.init(pairId: host, paneId: "%3")] = PaneState(paneId: "%3", sessionName: "shell", cliSessionState: .waiting)
        }
        #expect(status(panes: panes).pendingCount == 4)
        // Cached attention remains visible when a Host disconnects, as in the Mac menu.
        #expect(status(connected: [], panes: panes).pendingCount == 4)
        panes[.init(pairId: "home", paneId: "%1")]?.agentSession?.markHandled()
        #expect(status(panes: panes).pendingCount == 3)
        panes[.init(pairId: "office", paneId: "%1")]?.cliSessionState = .idle
        #expect(status(panes: panes).pendingCount == 2)
        #expect(status(paired: ["home"], panes: panes).pendingCount == 1)
    }

    @Test("A large badge stays compact while accessibility keeps the full count")
    func largeCount() {
        let panes = Dictionary(uniqueKeysWithValues: (0..<120).map { index in
            let id = "%\(index)"
            return (PaneKey(pairId: "office", paneId: id), PaneState(paneId: id, agentSession: .init(paneId: id), cliSessionState: .waiting))
        })
        #expect(status().pendingText == nil)
        #expect(status(panes: panes).pendingText == "99+")
        #expect(status(panes: panes).accessibilityValue.contains("120 need attention"))
    }

    @Test("Low accounts deduplicate across Hosts and support both built-in providers")
    func lowQuotas() {
        #expect(status(hosts: [host("office"), host("home")]).lowQuotaCount == 1)
        #expect(status(hosts: [host("office", used: 90), host("home", used: 90, provider: "claude-code")]).lowQuotaCount == 2)
        #expect(status(hosts: [host("office", used: 89)]).lowQuotaCount == 0)
        // The two warnings are independent; quota must not replace attention.
        let value = status(panes: [.init(pairId: "office", paneId: "%1"): PaneState(
            paneId: "%1", sessionName: "shell", cliSessionState: .waiting
        )], hosts: [host("office")])
        #expect(value.pendingCount == 1)
        #expect(value.lowQuotaCount == 1)
    }

    @Test("Disconnect and unpair suppress cached quota warnings immediately")
    func liveConnectionOverridesDashboardCache() {
        let low = host("office")
        #expect(status(connected: ["home"], hosts: [low]).lowQuotaCount == 0)
        #expect(status(paired: ["home"], hosts: [low]).lowQuotaCount == 0)
        var disconnected = low
        disconnected.isConnected = false
        #expect(status(hosts: [disconnected]).lowQuotaCount == 0)
        #expect(status(hosts: [low], elapsed: 121).lowQuotaCount == 0)
    }

    @Test("Invalid and expired quota readings never become alerts", arguments: ["failed", "expired", "unknown", "stale", "transportError"])
    func unavailableQuota(reason: String) {
        var low = host("office")
        switch reason {
        case "failed": low.snapshot?.accounts[0].availability = .failed
        case "expired": low.snapshot?.accounts[0].windows[0].resetsAt = now
        case "unknown": low.snapshot?.accounts[0].identity = nil
        case "stale": low.snapshot?.accounts[0].quotaObservedAt = now.addingTimeInterval(-301)
        default: low.error = "Refresh failed"
        }
        #expect(status(hosts: [low]).lowQuotaCount == 0)
        #expect(status(hosts: [host("office"), host("home", used: 50)]).lowQuotaCount == 0)
    }
}
