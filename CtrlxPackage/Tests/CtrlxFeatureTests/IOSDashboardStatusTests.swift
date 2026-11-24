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

    @Test("The toolbar uses a question mark when a paired Host is waiting for an answer")
    func attentionSymbol() {
        let questionKey = PaneKey(pairId: "home", paneId: "%1")
        let question = PaneState(paneId: "%1", sessionName: "work", agentSession: .init(
            paneId: "%1", state: .awaitingReplies(.init(questions: []), requestID: "question")
        ))
        let done = PaneState(paneId: "%1", sessionName: "work", agentSession: .init(
            paneId: "%1", state: .doneWorking(summary: nil)
        ))
        var panes = [questionKey: question, PaneKey(pairId: "office", paneId: "%1"): done]

        #expect(status(panes: panes).attentionSymbol == .questionmarkCircle)
        #expect(status(panes: panes).pendingCount == 2)
        #expect(status(paired: ["office"], panes: panes).attentionSymbol == .bellFill)
        panes[questionKey]?.cliSessionState = .idle
        #expect(status(panes: panes).attentionSymbol == .bellFill)
    }

    @Test("Attention rows follow the badge, with distinct targets across Hosts")
    func attentionRows() {
        let waiting = PaneState(paneId: "%1", sessionName: "work", windowName: "review", agentSession: .init(
            paneId: "%1", state: .awaitingPlanApproval(.init(title: "Plan", plan: ""), requestID: "request")
        ))
        let done = PaneState(paneId: "%1", sessionName: "work", windowName: "review", agentSession: .init(
            paneId: "%1", state: .doneWorking(summary: nil)
        ))
        let panes: [PaneKey: PaneState] = [
            .init(pairId: "office", paneId: "%1"): waiting,
            .init(pairId: "home", paneId: "%1"): done,
            .init(pairId: "home", paneId: "%2"): .init(paneId: "%2", sessionName: "shell", isActive: true, windowName: "tools", isWindowActive: true, cliSessionState: .waiting),
            .init(pairId: "home", paneId: "%3"): .init(paneId: "%3", sessionName: "shell", cliSessionState: .waiting),
            .init(pairId: "removed", paneId: "%1"): waiting,
        ]
        let items = IOSPendingAttention.items(hosts: ["office", "home"].map(pairedHost), paneStates: panes, catalogs: [:])
        #expect(items.count == status(panes: panes).pendingCount)
        #expect(items.map(\.id) == [
            .init(pairId: "office", paneId: "%1"),
            .init(pairId: "home", paneId: "%2"),
            .init(pairId: "home", paneId: "%1"),
        ])
        #expect(items.map(\.status) == [.approval, .waiting, .completed])
    }

    @Test("Attention labels distinguish duplicate window and Host names")
    func duplicateAttentionNames() {
        let hosts = zip(["office", "home"], ["alice", "bob"]).map { id, username in
            PairedHost(id: id, hostName: "Studio", username: username, partnerPublicKey: "", partnerPublicKeyId: "")
        }
        let panes = [
            PaneState(paneId: "%1", sessionName: "work", windowIndex: 3, windowName: "codex"),
            PaneState(paneId: "%2", sessionName: "work", windowIndex: 8, windowName: "codex"),
            PaneState(paneId: "%3", sessionName: "other", windowIndex: 5, windowName: "codex"),
            PaneState(paneId: "%4", sessionName: "other", windowIndex: 5, paneIndex: 1, windowName: "codex"),
        ]
        let states = Dictionary(uniqueKeysWithValues: hosts.flatMap { host in
            panes.map { pane in
                var pane = pane
                pane.agentSession = .init(paneId: pane.paneId, state: .doneWorking(summary: nil))
                return (PaneKey(pairId: host.id, paneId: pane.paneId), pane)
            }
        })
        let items = IOSPendingAttention.items(hosts: hosts, paneStates: states, catalogs: [:])
        #expect(items.filter { $0.id.pairId == "office" }.map(\.tabName) == [
            "codex · Pane 1", "codex · Pane 2", "codex · Window 3", "codex · Window 8",
        ])
        #expect(Set(items.map(\.hostName)) == ["Studio (alice)", "Studio (bob)"])
    }

    @Test("Attention labels number split panes from one using all panes in the window", arguments: [0, 1])
    func attentionPaneNumbers(baseIndex: Int) {
        let host = pairedHost("office")
        let firstSplitPane = PaneKey(pairId: host.id, paneId: "%2")
        var panes: [PaneKey: PaneState] = [
            .init(pairId: host.id, paneId: "%1"): .init(paneId: "%1", sessionName: "work", paneIndex: baseIndex, windowName: "solo", agentSession: .init(paneId: "%1", state: .doneWorking(summary: nil))),
            firstSplitPane: .init(paneId: "%2", sessionName: "work", windowIndex: 1, paneIndex: baseIndex, windowName: "split", agentSession: .init(paneId: "%2", state: .doneWorking(summary: nil))),
            .init(pairId: host.id, paneId: "%3"): .init(paneId: "%3", sessionName: "work", windowIndex: 1, paneIndex: baseIndex + 1, windowName: "split", agentSession: .init(paneId: "%3", state: .doneWorking(summary: nil))),
        ]
        #expect(IOSPendingAttention.items(hosts: [host], paneStates: panes, catalogs: [:]).map(\.tabName) == [
            "solo", "split · Pane 1", "split · Pane 2",
        ])
        panes[firstSplitPane]?.agentSession?.markHandled()
        #expect(IOSPendingAttention.items(hosts: [host], paneStates: panes, catalogs: [:]).map(\.tabName) == [
            "solo", "split · Pane 2",
        ])
    }

    @Test("Only one verified, connected target opens directly and resolves its exact pane")
    func singleAttentionTarget() throws {
        let hostID = UUID()
        let paneID = UUID()
        let pane = PaneState(
            paneId: "%7", sessionName: "work", tmuxWindowId: "@2", paneIndex: 1, windowName: "review",
            agentSession: .init(paneId: "%7", state: .doneWorking(summary: nil)),
            workspaceIdentity: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: paneID)
        )
        let catalog = try #require(ViewerWorkspaceCatalog(state: .init(
            pairId: "office", paneStates: ["%7": pane], workspaceIdentity: .init(hostID: hostID, serverID: "server")
        )))
        let hosts = [pairedHost("office")]
        let panes = [PaneKey(pairId: "office", paneId: "%7"): pane]
        let items = IOSPendingAttention.items(hosts: hosts, paneStates: panes, catalogs: ["office": catalog])
        let item = try #require(IOSPendingAttention.directTarget(in: items, connectedHostIDs: ["office"]))
        #expect(item.agentID == AgentID(hostID: hostID, paneID: paneID))
        #expect(item.tabName == "review")
        #expect(SessionNavigation.notification(agentID: item.agentID, hostID: item.id.pairId, catalog: catalog)?.paneSelection?.paneID == "%7")
        #expect(IOSPendingAttention.directTarget(in: [], connectedHostIDs: ["office"]) == nil)
        #expect(IOSPendingAttention.directTarget(in: items, connectedHostIDs: []) == nil)

        let pending = PaneState(paneId: "%8", sessionName: "other", cliSessionState: .waiting)
        let multiple = IOSPendingAttention.items(
            hosts: hosts, paneStates: panes.merging([.init(pairId: "office", paneId: "%8"): pending]) { current, _ in current },
            catalogs: ["office": catalog]
        )
        #expect(multiple.count == 2)
        #expect(IOSPendingAttention.directTarget(in: multiple, connectedHostIDs: ["office"]) == nil)
        let unverified = IOSPendingAttention.items(hosts: hosts, paneStates: panes, catalogs: [:])
        #expect(IOSPendingAttention.directTarget(in: unverified, connectedHostIDs: ["office"]) == nil)
    }

    private func pairedHost(_ id: String) -> PairedHost {
        .init(id: id, hostName: id.capitalized, username: "", partnerPublicKey: "", partnerPublicKeyId: "")
    }

    @Test("A large badge stays compact while accessibility keeps the full count")
    func largeCount() {
        let panes = Dictionary(uniqueKeysWithValues: (0..<120).map { index in
            let id = "%\(index)"
            return (PaneKey(pairId: "office", paneId: id), PaneState(paneId: id, agentSession: .init(paneId: id), cliSessionState: .waiting))
        })
        #expect(status().pendingText == nil)
        #expect(status(panes: panes).pendingText == "99+")
        #expect(status(panes: panes).attentionAccessibilityValue == "120 need attention")
    }

    @Test("App badge waits for complete Host snapshots and follows the toolbar count")
    @MainActor
    func badgeWaitsForSnapshots() {
        let store = SessionStore()
        let paired: Set = ["office", "home"]
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == nil)
        let done = PaneState(paneId: "%1", sessionName: "work", agentSession: .init(paneId: "%1", state: .doneWorking(summary: nil)))
        store.handleStateUpdate(.init(pairId: "office", paneStates: ["%1": done]))
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == nil)
        store.handleStateUpdate(.init(pairId: "home", paneStates: ["%1": done]))
        // A previous foreground period's complete snapshots are still stale on return.
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: [], store: store) == nil)
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: ["office"], store: store) == nil)
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == 2)
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == status(panes: store.paneStates).pendingCount)

        store.handleAgentStatus(.init(pairId: "office", sessionId: "%1", pluginId: "codex", state: .working, timestamp: now))
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == 1)
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:]))
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == 0)
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == status(panes: store.paneStates).pendingCount)

        store.clearSessions(for: "office")
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == nil)
        store.handleStateUpdate(.init(pairId: "office", paneStates: [:]))
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: paired, refreshedHostIDs: paired, store: store) == 0)
    }

    @Test("Unpairing excludes the removed Host's attention from the app badge")
    @MainActor
    func badgeFollowsPairing() {
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "removed", paneStates: [
            "%1": .init(paneId: "%1", sessionName: "shell", cliSessionState: .waiting),
        ]))
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: ["removed"], refreshedHostIDs: ["removed"], store: store) == 1)
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: ["home"], refreshedHostIDs: ["home"], store: store) == nil)
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:]))
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: ["home"], refreshedHostIDs: ["home"], store: store) == 0)
        #expect(IOSDashboardStatus.badgeCount(pairedHostIDs: [], refreshedHostIDs: [], store: store) == 0)
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
