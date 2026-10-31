import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Remote browser popup selection") @MainActor
struct RemoteBrowserPopupSelectionTests {
    @Test(arguments: [false, true])
    func controlledHumanAndAgentPagesFollowTheirNewChild(_ agent: Bool) async throws {
        let host = RemoteBrowserSessionTests.Host(agent: agent)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.frame != nil }
        if agent {
            await session.takeControl()
        }
        try await wait { session.controlID != nil }
        let child = page(parent: host.tab.id, agent: agent)
        #expect(session.newlyOpenedChild(from: [host.tab], in: [host.tab, child]) == child)
        #expect(session.newlyOpenedChild(from: [host.tab, child], in: [host.tab, child]) == nil)
    }

    @Test
    func catalogsUpdatesAndUnrelatedPagesKeepSelection() async throws {
        let host = RemoteBrowserSessionTests.Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.controlID != nil }
        let child = page(parent: host.tab.id)
        #expect(session.newlyOpenedChild(from: [], in: [host.tab, child]) == nil)
        #expect(session.newlyOpenedChild(from: [host.tab], in: [host.tab]) == nil)
        for other in [
            page(), page(parent: UUID()), page(parent: host.tab.id, session: "another"),
            page(parent: host.tab.id, extensionWindow: true),
        ] {
            #expect(session.newlyOpenedChild(from: [host.tab], in: [host.tab, other]) == nil)
        }
        let updated = page(id: child.id, parent: host.tab.id, title: "Loaded page")
        #expect(session.newlyOpenedChild(from: [host.tab, child], in: [host.tab, updated]) == nil)
    }

    @Test
    func readOnlyReleasedAndStoppedSurfacesCannotFollowChildren() async throws {
        let host = RemoteBrowserSessionTests.Host(agent: true)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let child = page(parent: host.tab.id, agent: true)
        func nextChild() -> RemoteBrowserTab? {
            session.newlyOpenedChild(from: [host.tab], in: [host.tab, child])
        }
        #expect(nextChild() == nil)
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.frame != nil }
        #expect(nextChild() == nil)
        await session.takeControl()
        #expect(nextChild() == child)
        session.releaseControl()
        #expect(nextChild() == nil)
        await session.takeControl()
        #expect(nextChild() == child)
        session.stop()
        #expect(nextChild() == nil)
    }

    private func page(id: UUID = UUID(), parent: UUID? = nil, agent: Bool = false, session: String = "s", title: String = "child", extensionWindow: Bool = false) -> RemoteBrowserTab {
        .init(id: id, sessionName: session, parentID: parent, title: title, url: "https://example.com", isLoading: false, isAgentOwned: agent, isExtensionWindow: extensionWindow ? true : nil)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for the browser fixture")
        throw CancellationError()
    }
}
