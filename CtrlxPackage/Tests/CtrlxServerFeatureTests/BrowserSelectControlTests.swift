#if os(macOS)
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Host select-menu control") @MainActor
    struct BrowserSelectControlTests {
        @Test
        func routesMenuOnlyThroughCurrentViewerSurface() async throws {
            let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture(agent: false)
            defer { service.releaseBrowserControl(tab.id) }
            let surface = UUID()
            let control = try #require(try await service.handleBrowser(
                .init(sessionName: "test", tabID: tab.id, surfaceID: surface, operation: .takeControl), viewerID: "viewer"
            ).controlID)
            let menu = RemoteBrowserSelectMenu(id: UUID(), generation: 4, title: "Choose", options: [.init(index: 0, text: "A")])
            runtime.onBrowserRequest = { _ in try JSONEncoder().encode(RemoteBrowserResponse(selectMenu: menu)) }
            let opened = try await service.handleBrowser(.init(
                sessionName: "test", tabID: tab.id, surfaceID: surface, controlID: control,
                generation: 4, selectMenus: true, operation: .pointer(.init(.down, x: 10, y: 20, button: .left))
            ), viewerID: "viewer")
            #expect(opened.selectMenu == menu && opened.controlID == control)
            #expect(runtime.requests.last?["selectMenus"] as? Bool == true)
            runtime.onBrowserRequest = { _ in Data("{}".utf8) }
            let choice = BrowseBrowser(
                sessionName: "test",
                tabID: tab.id,
                surfaceID: surface,
                controlID: control,
                generation: 4,
                operation: .selectOption(menuID: menu.id, index: 0)
            )
            _ = try await service.handleBrowser(choice, viewerID: "viewer")
            #expect(runtime.requests.last?["menuID"] as? String == menu.id.uuidString)
            #expect(runtime.requests.last?["index"] as? Int == 0)
            let count = runtime.requests.count
            await #expect(throws: (any Error).self) { try await service.handleBrowser(choice, viewerID: "other") }
            await #expect(throws: (any Error).self) {
                try await service.handleBrowser(.init(
                    sessionName: "test",
                    tabID: tab.id,
                    surfaceID: UUID(),
                    controlID: control,
                    generation: 4,
                    operation: choice.operation
                ), viewerID: "viewer")
            }
            #expect(runtime.requests.count == count)
        }

        @Test
        func payloadRejectsInvalidIndexesAndEncodesCancel() throws {
            let id = UUID()
            let cancel = try AgentBrowserService.nativePayload(.selectOption(menuID: id, index: nil))
            #expect(cancel["action"] as? String == "select" && cancel["index"] == nil)
            for index in [-1, 512] {
                #expect(throws: (any Error).self) { try AgentBrowserService.nativePayload(.selectOption(menuID: id, index: index)) }
            }
        }
    }
#endif
