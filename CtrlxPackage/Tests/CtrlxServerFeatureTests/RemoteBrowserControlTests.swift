#if os(macOS)
import AppKit
import CtrlxBrowserBridge
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Remote browser control") @MainActor
struct RemoteBrowserControlTests {
    @MainActor final class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
        weak var delegate: (any CXBrowserHostDelegate)?
        var blocked = false
        var controls: [String: String] = [:]
        var requests: [[String: Any]] = []
        var closed: [String] = []
        func start(with delegate: any CXBrowserHostDelegate, profile: String, state: String) throws {}
        func openManualTab(route: [String: String], url: String, completion: @escaping (String?) -> Void) {
            delegate?.browserTabCreated(UUID().uuidString, view: NSView(), route: route, owner: "", parent: nil)
            completion(nil)
        }
        func navigateTab(_ identifier: String, url: String) {}
        func goBack(_ identifier: String) {}
        func goForward(_ identifier: String) {}
        func reloadTab(_ identifier: String) {}
        func showDevTools(_ identifier: String) {}
        func closeTab(_ identifier: String) { closed.append(identifier) }
        func beginShutdown() {}
        func finishShutdown() -> Bool { true }
        func setHumanControl(_ token: String?, forTab identifier: String) -> Bool {
            guard !blocked else { return false }
            controls[identifier] = token
            return true
        }
        func requestBrowserTab(_ identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
            guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else { completion(nil, "Bad request"); return }
            requests.append(object)
            let frame = RemoteBrowserFrame(jpeg: Data([1, 2, 3]), width: 1000, height: 700, generation: 4)
            completion(object["action"] as? String == "frame" ? try? JSONEncoder().encode(frame) : Data("{}".utf8), nil)
        }
    }

    func fixture(agent: Bool = true) async throws -> (AgentBrowserService, Runtime, RemoteBrowserTab) {
        let runtime = Runtime()
        let service = AgentBrowserService(runtime: runtime)
        runtime.delegate = service
        if agent {
            service.browserTabCreated(UUID().uuidString, view: NSView(),
                route: ["workspace": UUID().uuidString, "pane": "%1", "session": "test", "window": "@1"], owner: "owner", parent: nil)
        } else { _ = try await service.createSharedTab(sessionName: "test") }
        return (service, runtime, try #require(service.sharedBrowserTabs.first))
    }

    @Test func controllerIsolationAndDisconnect() async throws {
        let (service, runtime, tab) = try await fixture()
        let surface = UUID()
        func request(_ operation: RemoteBrowserOperation, control: UUID? = nil, surfaceID: UUID? = nil, session: String = "test") -> BrowseBrowser {
            .init(sessionName: session, tabID: tab.id, surfaceID: surfaceID ?? surface, controlID: control, generation: 4, operation: operation)
        }
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.text("denied")), viewerID: "a") }
        let control = try #require(try await service.handleBrowser(request(.takeControl), viewerID: "a").controlID)
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.takeControl), viewerID: "b") }
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.text("wrong surface"), control: control, surfaceID: UUID()), viewerID: "a") }
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.frame, session: "other"), viewerID: "a") }
        _ = try await service.handleBrowser(request(.text("中文"), control: control), viewerID: "a")
        #expect(runtime.requests.last?["text"] as? String == "中文")
        let child = UUID()
        service.browserTabCreated(child.uuidString, view: NSView(),
            route: ["workspace": UUID().uuidString, "pane": "%1", "session": "test"], owner: "owner", parent: tab.id.uuidString)
        #expect(service.tabs[child.uuidString]?.suppressInitialSelection == true,
                "A popup opened by remote input must not steal Host focus")
        _ = try await service.handleBrowser(request(.releaseControl, control: control), viewerID: "b")
        #expect(service.remoteControls[tab.id] != nil)
        service.disconnectBrowserViewer("a")
        #expect(service.remoteControls.isEmpty && runtime.controls.isEmpty)
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.text("stale"), control: control), viewerID: "a") }
        await service.shutdown()
    }

    @Test func agentBusyAndExpiredControl() async throws {
        let (service, runtime, tab) = try await fixture()
        let request = BrowseBrowser(sessionName: "test", tabID: tab.id, surfaceID: UUID(), operation: .takeControl)
        runtime.blocked = true
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request, viewerID: "a") }
        runtime.blocked = false
        _ = try await service.handleBrowser(request, viewerID: "a")
        service.remoteControls[tab.id]?.expires = .now.advanced(by: .seconds(-1))
        _ = try await service.handleBrowser(request, viewerID: "b")
        #expect(service.remoteControls[tab.id]?.viewerID == "b")
        await service.shutdown()
    }

    @Test func manualPageDoesNotNeedHostWorkspace() async throws {
        let (service, _, tab) = try await fixture(agent: false)
        #expect(!tab.isAgentOwned)
        let result = try await service.handleBrowser(.init(sessionName: "test", tabID: tab.id, surfaceID: UUID(), operation: .frame), viewerID: "a")
        #expect(result.frame?.isValid == true)
        await service.shutdown()
    }

    @Test func validationBeforeNativeBoundary() throws {
        #expect(throws: (any Error).self) { try AgentBrowserService.nativePayload(.text(String(repeating: "文", count: 6000))) }
        #expect(throws: (any Error).self) { try AgentBrowserService.nativePayload(.fit(width: 0, height: 10)) }
        #expect(throws: (any Error).self) { try AgentBrowserService.nativePayload(.pointer(.init(.down, x: .nan, y: 1))) }
    }

    @Test func renamedSessionUpdatesParkedPagesAndPopupRoutes() async throws {
        let (service, _, tab) = try await fixture()
        _ = try await service.createSharedTab(sessionName: "test")
        func pane(_ session: String) -> PaneInfo {
            PaneInfo(paneId: "%1", target: "\(session):1.0", sessionName: session, windowIndex: 1,
                     paneIndex: 0, command: "codex", currentPath: "/tmp", width: 80, height: 24, isActive: true)
        }
        service.updateBrowserRoutes([pane("test")])
        service.updateBrowserRoutes([pane("renamed")])
        #expect(service.sharedBrowserTabs.count == 2)
        #expect(service.sharedBrowserTabs.allSatisfy { $0.sessionName == "renamed" })
        let child = UUID()
        service.browserTabCreated(child.uuidString, view: NSView(),
            route: ["workspace": UUID().uuidString, "pane": "%1", "session": "test"], owner: "owner", parent: tab.id.uuidString)
        #expect(service.tabs[child.uuidString]?.sessionName == "renamed")
        #expect(service.tabs[child.uuidString]?.windowID == "renamed:1")
        await service.shutdown()
    }
}
#endif
