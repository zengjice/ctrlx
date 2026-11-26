import Clocks
import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct NotificationNavigationWaitingTests {
    #if os(iOS)
        @Test("A Workflow completion tap supersedes an Agent tap waiting for the Host")
        func workflowCompletionCancelsPendingAgentTap() {
            let service = PushNotificationService()
            let agent = AgentID(hostID: UUID(), paneID: UUID())
            var agentTap: [AnyHashable: Any] = ["eventType": "cli.notify", "pairId": "pair", "paneId": "%7"]
            for (key, value) in agent.notificationUserInfo {
                agentTap[key] = value
            }
            service.handleNotificationTap(userInfo: agentTap)
            #expect(service.pendingDeepLink?.agentID == agent)
            service.handleNotificationTap(userInfo: ["eventType": NotificationDelivery.workflowCompletionEventType, "pairId": "pair"])
            #expect(service.pendingDeepLink == nil)
        }

        @Test(arguments: [NotificationDelivery.workflowCompletionEventType, NotificationDelivery.workflowAttentionEventType])
        func workflowTapSelectsRunAndCancelsOlderRoutes(type: String) {
            let service = PushNotificationService()
            service.pendingDashboard = true
            let target = AgentWorkflowNotificationTarget(hostID: UUID(), runID: UUID(), eventID: UUID())
            var userInfo: [AnyHashable: Any] = ["eventType": type, "pairId": "office"]
            for (key, value) in target.userInfo {
                userInfo[key] = value
            }
            service.handleNotificationTap(userInfo: userInfo)
            #expect(service.pendingWorkflow?.target == target)
            #expect(service.pendingWorkflow?.pairID == "office")
            #expect(!service.pendingDashboard && service.pendingDeepLink == nil)
            service.handleNotificationTap(userInfo: ["eventType": "cli.notify", "pairId": "home"])
            #expect(service.pendingWorkflow == nil)
            #expect(service.pendingDeepLink?.hostId == "home")
        }
    #endif

    private func catalog(_ id: AgentID, paneID: String = "%1") throws -> ViewerWorkspaceCatalog {
        try #require(ViewerWorkspaceCatalog(state: .init(pairId: "pair", paneStates: [paneID: .init(
            paneId: paneID, sessionName: "work", tmuxWindowId: "@1",
            workspaceIdentity: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: id.paneID)
        )], workspaceIdentity: .init(hostID: id.hostID, serverID: "server"))))
    }

    @Test("A cold start can take longer than 2.5 seconds; only a fresh target-Host snapshot resolves")
    func delayedSnapshot() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            try await withDependencies { $0.continuousClock = clock } operation: {
                let id = AgentID(hostID: UUID(), paneID: UUID())
                var snapshot = try NotificationNavigation.Snapshot(isConnected: false, id: UUID(), catalog: catalog(id))
                var requests = 0
                var completed = false
                let task = Task {
                    let result = try await NotificationNavigation.resolve(agentID: id, hostID: "pair", snapshot: { snapshot }) {
                        requests += 1
                        return true
                    }
                    completed = true
                    return result
                }
                defer { task.cancel() }
                await Task.yield()
                await clock.advance(by: .seconds(4))
                #expect(!completed && requests == 0)
                snapshot.isConnected = true
                await clock.advance(by: .seconds(1))
                #expect(!completed && requests == 1) // Cached catalog is not fresh, even though it matches.
                snapshot.catalog = try catalog(id, paneID: "%42")
                snapshot.id = UUID()
                await clock.advance(by: .milliseconds(200))
                let destination = try await task.value.get()
                #expect(destination.paneSelection?.paneID == "%42")
                #expect(requests == 1)
            }
        }
    }

    @Test("Missing identity is distinct from an absent target in a fresh catalog")
    func missingTargets() async throws {
        let id = AgentID(hostID: UUID(), paneID: UUID())
        var snapshot = try NotificationNavigation.Snapshot(isConnected: true, id: UUID(), catalog: catalog(id))
        let missing = try await NotificationNavigation.resolve(agentID: nil, hostID: "pair", snapshot: { snapshot }) {
            Issue.record("An identity-less notification must not request or guess a target")
            return false
        }
        #expect(missing == .failure(.missingIdentity))
        let replaced = AgentID(hostID: id.hostID, paneID: UUID())
        let unavailable = try await withDependencies { $0.continuousClock = TestClock() } operation: {
            try await NotificationNavigation.resolve(agentID: replaced, hostID: "pair", snapshot: { snapshot }) {
                snapshot.id = UUID()
                return true
            }
        }
        #expect(unavailable == .failure(.targetUnavailable))
    }

    @Test("Connection and directory timeouts are not reported as a closed Agent", arguments: [false, true])
    func unavailableSnapshot(connected: Bool) async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            try await withDependencies { $0.continuousClock = clock } operation: {
                let id = AgentID(hostID: UUID(), paneID: UUID())
                var snapshot = NotificationNavigation.Snapshot(isConnected: connected, id: nil, catalog: nil)
                let task = Task {
                    try await NotificationNavigation.resolve(agentID: id, hostID: "pair", snapshot: { snapshot }) {
                        snapshot.id = UUID() // A snapshot without a usable catalog is still not ready.
                        return true
                    }
                }
                defer { task.cancel() }
                await Task.yield()
                await clock.advance(by: .seconds(15))
                let result = try await task.value
                #expect(result == .failure(connected ? .directoryNotReady : .hostNotConnected))
            }
        }
    }

    @Test("Reconnect requests a new snapshot; cancellation prevents a late navigation")
    func reconnectAndCancel() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            try await withDependencies { $0.continuousClock = clock } operation: {
                let id = AgentID(hostID: UUID(), paneID: UUID())
                var snapshot = NotificationNavigation.Snapshot(isConnected: true, id: UUID(), catalog: nil)
                var requests = 0
                let task = Task {
                    try await NotificationNavigation.resolve(agentID: id, hostID: "pair", snapshot: { snapshot }) {
                        requests += 1
                        return true
                    }
                }
                defer { task.cancel() }
                await Task.yield()
                await clock.advance(by: .seconds(1))
                #expect(requests == 1)
                snapshot.isConnected = false
                await clock.advance(by: .seconds(1))
                snapshot.isConnected = true
                await clock.advance(by: .seconds(1))
                #expect(requests == 2)
                task.cancel()
                snapshot.catalog = try catalog(id)
                snapshot.id = UUID()
                do {
                    _ = try await task.value
                    Issue.record("Cancelled notification navigated")
                } catch {
                    #expect(error is CancellationError)
                }
            }
        }
    }
}
