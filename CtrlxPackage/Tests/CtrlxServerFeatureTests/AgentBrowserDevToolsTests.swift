#if os(macOS)
import AppKit
import CtrlxBrowserBridge
import Testing
@testable import CtrlxServerFeature

@Suite("Agent Browser human developer tools")
@MainActor
struct AgentBrowserDevToolsTests {
    @MainActor
    private final class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
        var inspected: [String] = []
        var closed: [String] = []
        func start(with delegate: any CXBrowserHostDelegate, profile: String, state: String) throws {}
        func navigateTab(_ identifier: String, url: String) {}
        func goBack(_ identifier: String) {}
        func goForward(_ identifier: String) {}
        func reloadTab(_ identifier: String) {}
        func showDevTools(_ identifier: String) { inspected.append(identifier) }
        func closeTab(_ identifier: String) { closed.append(identifier) }
        func beginShutdown() {}
        func finishShutdown() -> Bool { true }
    }

    private func addTab(_ service: AgentBrowserService, owner: String) throws -> AgentBrowserTabState {
        let workspace = AgentBrowserWorkspace()
        var tab: AgentBrowserTabState?
        workspace.onCreate = { value, _ in tab = value }
        service.register(workspace)
        service.browserTabCreated(UUID().uuidString, view: NSView(),
            route: ["workspace": workspace.id.uuidString, "pane": "%1"], owner: owner, parent: nil)
        return try #require(tab)
    }

    @Test("The clicked tab wins over the most recently selected tab")
    func exactTarget() throws {
        let runtime = Runtime()
        let service = AgentBrowserService(runtime: runtime)
        let first = try addTab(service, owner: "first")
        let second = try addTab(service, owner: "second")
        service.browserTabSelected(second.identifier)
        service.showDevTools(first)
        service.showDevTools(first)
        #expect(runtime.inspected == [first.identifier, first.identifier])
        #expect(first.owner == "first")
        #expect(!first.isClosed && !second.isClosed)
    }

    @Test("A closed or stale tab cannot inspect a different page")
    func closedOrForged() throws {
        let runtime = Runtime()
        let service = AgentBrowserService(runtime: runtime)
        let tab = try addTab(service, owner: "first")
        let impostor = AgentBrowserTabState(id: tab.id, identifier: tab.identifier, view: NSView(),
            workspaceID: tab.workspaceID, paneID: tab.paneID, owner: tab.owner, service: service)
        service.showDevTools(impostor)
        service.browserTabClosed(tab.identifier)
        service.showDevTools(tab)
        #expect(runtime.inspected.isEmpty)
    }

    @Test("A tab owned by another host service is refused")
    func differentHost() throws {
        let runtime = Runtime()
        let service = AgentBrowserService(runtime: runtime)
        let other = AgentBrowserService()
        let tab = try addTab(other, owner: "other")
        service.showDevTools(tab)
        #expect(runtime.inspected.isEmpty)
    }

    @Test("Shutdown cannot reopen developer tools")
    func shutdown() async throws {
        let runtime = Runtime()
        let service = AgentBrowserService(runtime: runtime)
        let tab = try addTab(service, owner: "first")
        await service.shutdown()
        service.showDevTools(tab)
        #expect(runtime.inspected.isEmpty)
    }

    @Test("Unregister removes UI tabs before delayed native close callbacks")
    func unregisterRemovesUITabs() throws {
        let runtime = Runtime()
        let service = AgentBrowserService(runtime: runtime)
        let workspace = AgentBrowserWorkspace()
        var visible: [String: AgentBrowserTabState] = [:]
        var removed: [String] = []
        workspace.onCreate = { tab, _ in visible[tab.identifier] = tab }
        workspace.onClose = { tab in
            #expect(tab.isClosed)
            visible.removeValue(forKey: tab.identifier)
            removed.append(tab.identifier)
            // Real UI cleanup also asks the service to close its old state.
            service.close(tab)
        }
        service.register(workspace)
        let id = UUID().uuidString
        service.browserTabCreated(id, view: NSView(),
            route: ["workspace": workspace.id.uuidString, "pane": "%1"], owner: "first", parent: nil)
        let old = try #require(visible[id])
        let other = try addTab(service, owner: "other-workspace")

        service.unregister(workspace)
        #expect(visible.isEmpty)
        #expect(old.isClosed)
        #expect(removed == [id])
        #expect(runtime.closed == [id])
        #expect(!other.isClosed)

        // Reappearance can reuse the same SwiftUI state; old callbacks must
        // neither restore a closed page nor remove the newly created one.
        service.register(workspace)
        let replacement = UUID().uuidString
        service.browserTabCreated(replacement, view: NSView(),
            route: ["workspace": workspace.id.uuidString, "pane": "%1"], owner: "first", parent: nil)
        service.browserTabClosed(id)
        service.browserTabChanged(id, title: "Late", url: "about:blank", loading: false)
        #expect(visible.count == 1)
        #expect(visible[replacement]?.isClosed == false)
        #expect(removed == [id])
        service.showDevTools(old)
        service.showDevTools(other)
        #expect(runtime.inspected == [other.identifier])
        service.unregister(workspace)
        service.unregister(workspace)
        service.browserTabClosed(replacement)
        #expect(visible.isEmpty)
        #expect(removed == [id, replacement])
        #expect(runtime.closed == [id, replacement])
    }
}
#endif
