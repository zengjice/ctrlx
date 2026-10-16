import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite("Host-owned pane Files tabs")
struct HostFileTabServiceTests {
    func fixture(identity: WorkspacePaneIdentity? = nil) -> HostFileTabService {
        let service = HostFileTabService()
        service.resolvePane = { session, pane in
            PaneInfo(
                paneId: pane,
                target: "\(session):1.0",
                sessionName: session,
                windowIndex: 1,
                tmuxWindowId: "@1",
                paneIndex: 0,
                command: "zsh",
                currentPath: "/tmp",
                width: 80,
                height: 24,
                isActive: true,
                workspaceIdentity: identity
            )
        }
        return service
    }

    @Test("A recycled pane cannot inherit an open Files request or an existing tab", arguments: [false, true], [false, true])
    func recycledPane(restart: Bool, publishBeforeOpen: Bool) async throws {
        let old = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let fresh = WorkspacePaneIdentity(serverID: restart ? "200:2" : old.serverID, sessionID: old.sessionID, windowID: old.windowID, paneID: restart ? old.paneID : UUID())
        let service = fixture(identity: old)
        let original = try await service.open(sessionName: "work", paneID: "%1", expectedWorkspacePane: old)
        let replacement = try #require(fixture(identity: fresh).resolvePane)
        service.resolvePane = replacement
        await #expect(throws: FileBrowserError.self) {
            try await service.open(sessionName: "work", paneID: "%1", expectedWorkspacePane: old)
        }
        if publishBeforeOpen {
            try service.updateRoutes([await replacement("work", "%1")])
            #expect(service.tabs.isEmpty)
        }
        let current = try await service.open(sessionName: "work", paneID: "%1", expectedWorkspacePane: fresh)
        #expect(current.id != original.id)
        #expect(service.tabs == [current])
    }

    @Test("An old source query cannot publish a tab after newer routes have arrived")
    func retiredSourceQuery() async throws {
        let identity = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let service = fixture(identity: identity)
        let resolve = try #require(service.resolvePane)
        let oldPane = try await resolve("work", "%1")
        service.updateRoutes([oldPane])
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        var started = false
        service.resolvePane = { _, _ in
            started = true
            for await _ in gate {
                break
            }
            return oldPane
        }
        let request = Task { try await service.open(sessionName: "work", paneID: "%1", expectedWorkspacePane: identity) }
        defer { request.cancel() }
        for _ in 0..<100 where !started {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started)
        service.updateRoutes([])
        release.finish()
        await #expect(throws: FileBrowserError.self) { try await request.value }
        #expect(service.tabs.isEmpty)
    }

    @Test
    func allHumanEntryPointsReuseByPaneNotWindowOrDirectory() async throws {
        let service = fixture()
        let first = try await service.open(sessionName: "work", paneID: "%1")
        let repeated = try await service.handle(.open(sessionName: "work", new: false), paneID: "%1")
        #expect(repeated == .tab(first))
        let otherPane = try await service.open(sessionName: "work", paneID: "%2")
        #expect(first.id != otherPane.id)
        let extra = try await service.open(sessionName: "work", paneID: "%1", new: true)
        #expect(!extra.isPrimary && extra.id != first.id)
        #expect(try await service.open(sessionName: "work", paneID: "%1").id == first.id)
        #expect(service.tabs.allSatisfy { $0.group == .human })
        service.close(first.id)
        #expect(try await service.open(sessionName: "work", paneID: "%1").id != first.id)
    }

    @Test
    func simultaneousOpenAndLimit() async throws {
        let service = fixture()
        async let first = service.open(sessionName: "work", paneID: "%1")
        async let second = service.open(sessionName: "work", paneID: "%1")
        let (a, b) = try await (first, second)
        #expect(a.id == b.id && service.tabs.count == 1)
        for _ in 0..<29 {
            _ = try await service.open(sessionName: "work", paneID: "%1", new: true)
        }
        #expect(try await service.open(sessionName: "work", paneID: "%1").id == a.id)
        await #expect(throws: (any Error).self) { try await service.open(sessionName: "work", paneID: "%2") }
    }

    @Test
    func routeMovesAndPaneDisappearance() async throws {
        let identity = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let service = fixture(identity: identity)
        let tab = try await service.open(sessionName: "before", paneID: "%1")
        let moved = WorkspacePaneIdentity(serverID: identity.serverID, sessionID: UUID(), windowID: UUID(), paneID: identity.paneID)
        let resolve = try #require(fixture(identity: moved).resolvePane)
        service.resolvePane = resolve
        let pane = try await resolve("after", "%1")
        service.updateRoutes([pane])
        #expect(service.tabs.first?.id == tab.id)
        #expect(service.tabs.first?.sessionName == "after")
        #expect(try await service.open(sessionName: "after", paneID: "%1", expectedWorkspacePane: identity).id == tab.id)
        service.updateRoutes([])
        #expect(service.tabs.isEmpty)
        #expect(try await service.open(sessionName: "after", paneID: "%1").id != tab.id)
    }

    @Test
    func aCachedDefaultDoesNotBypassFreshPaneValidation() async throws {
        let service = fixture()
        let original = try await service.open(sessionName: "work", paneID: "%1")
        service.resolvePane = { _, _ in throw FileBrowserError.message("Source pane is no longer in this session.") }
        await #expect(throws: (any Error).self) { try await service.open(sessionName: "work", paneID: "%1") }
        await #expect(throws: (any Error).self) { try await service.open(sessionName: "work", paneID: "%1", new: true) }
        #expect(service.tabs == [original])
    }

    @Test("Recovery explicitly binds saved Files UUIDs to the reconstructed source")
    func restoredSource() async throws {
        var session = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
        session.name = "work"
        session.windows[0].runtimeID = "@1"
        session.windows[0].panes[0].runtimeID = "%1"
        let identity = WorkspacePaneIdentity(serverID: "200:2", sessionID: session.id, windowID: session.windows[0].id, paneID: session.windows[0].panes[0].id)
        let saved = WorkspaceRecoveryFileTab(id: UUID(), sessionID: identity.sessionID, windowID: identity.windowID, paneID: identity.paneID, group: .human, isPrimary: true, initialDirectory: "/saved")
        let service = fixture(identity: identity)
        service.restore([saved], sessions: [session], serverID: identity.serverID)
        let resolve = try #require(service.resolvePane)
        try service.updateRoutes([await resolve("work", "%1")])
        #expect(try await service.open(sessionName: "work", paneID: "%1", expectedWorkspacePane: identity).id == saved.id)
        #expect(service.tabs.first?.initialDirectory == "/saved")
        let replacement = WorkspacePaneIdentity(serverID: "300:3", sessionID: identity.sessionID, windowID: identity.windowID, paneID: identity.paneID)
        let replaced = try #require(fixture(identity: replacement).resolvePane)
        try service.updateRoutes([await replaced("work", "%1")])
        #expect(service.tabs.isEmpty)
    }
}
