import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite("Host-owned pane Files tabs")
struct HostFileTabServiceTests {
    func fixture() -> HostFileTabService {
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
                isActive: true
            )
        }
        return service
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
        let service = fixture()
        let tab = try await service.open(sessionName: "before", paneID: "%1")
        let resolve = try #require(service.resolvePane)
        let pane = try await resolve("after", "%1")
        service.updateRoutes([pane])
        #expect(service.tabs.first?.id == tab.id)
        #expect(service.tabs.first?.sessionName == "after")
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
}
