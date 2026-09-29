#if os(macOS)
    import AppKit
    import CtrlxBrowserBridge
    import CtrlxCommon
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("New Browser engine")
    struct NewBrowserEngineTests {
        @Test("Chromium is the default; WebKit and Chromium choices persist independently of link rules")
        func preference() {
            let preferences = PreferencesService.inMemory()
            withDependencies {
                $0[PreferencesService.self] = preferences
                $0[LoginItemService.self] = .previewValue
            } operation: {
                let settings = AppSettings()
                #expect(settings.newBrowserEngine == .chromium)
                settings.browserLinkBehavior = .alwaysInDefaultBrowser
                for engine in NewBrowserEngine.allCases.reversed() {
                    settings.newBrowserEngine = engine
                    let reloaded = AppSettings()
                    #expect(reloaded.newBrowserEngine == engine)
                    #expect(reloaded.browserLinkBehavior == .alwaysInDefaultBrowser)
                }
                preferences.setString("unknown", AppSettings.Keys.newBrowserEngine.rawValue)
                #expect(AppSettings().newBrowserEngine == .chromium)
            }
        }

        @MainActor
        private final class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
            var requests: [([String: String], String)] = []
            var closed: [String] = []
            var failure: String?
            func start(with delegate: any CXBrowserHostDelegate, profile: String, state: String) throws {}
            func openManualTab(route: [String: String], url: String, completion: @escaping (String?) -> Void) {
                requests.append((route, url))
                completion(failure)
            }
            func navigateTab(_ identifier: String, url: String) {}
            func goBack(_ identifier: String) {}
            func goForward(_ identifier: String) {}
            func reloadTab(_ identifier: String) {}
            func showDevTools(_ identifier: String) {}
            func closeTab(_ identifier: String) { closed.append(identifier) }
            func beginShutdown() {}
            func finishShutdown() -> Bool { true }
        }

        @Test("Manual local and viewer tabs carry explicit destinations, never pane or agent credentials")
        func explicitRouting() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let workspace = AgentBrowserWorkspace()
            service.register(workspace)
            let targets = [ManualBrowserTarget(sessionName: "same"),
                           ManualBrowserTarget(hostID: "office", sessionName: "same"),
                           ManualBrowserTarget(hostID: "home", sessionName: "same")]
            for target in targets { try await service.openManualTab(in: workspace, target: target) }
            #expect(runtime.requests.count == 3)
            for (request, target) in zip(runtime.requests, targets) {
                #expect(ManualBrowserTarget(route: request.0) == target)
                #expect(request.0["workspace"] == workspace.id.uuidString)
                #expect(request.0["pane"] == nil)
                #expect(request.0["owner"] == nil)
                #expect(request.1 == "about:blank")
            }
        }

        @Test("Manual creation errors surface and closed workspaces cannot open tabs")
        func failedCreation() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let workspace = AgentBrowserWorkspace()
            service.register(workspace)
            let target = ManualBrowserTarget(sessionName: "test")
            runtime.failure = "Test failure"
            await #expect(throws: (any Error).self) { try await service.openManualTab(in: workspace, target: target) }
            service.unregister(workspace)
            await #expect(throws: (any Error).self) { try await service.openManualTab(in: workspace, target: target) }
            #expect(runtime.requests.count == 1)
        }

        @Test("Missing Chromium cannot silently fall back to WebKit")
        func unavailableRuntime() async {
            let service = AgentBrowserService()
            let workspace = AgentBrowserWorkspace()
            service.register(workspace)
            await #expect(throws: (any Error).self) {
                try await service.openManualTab(in: workspace, target: ManualBrowserTarget(sessionName: "test"))
            }
        }

        @Test("Manual children retain their parent's destination without becoming agent tabs")
        func childRoutingAndClosure() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let workspace = AgentBrowserWorkspace()
            let target = ManualBrowserTarget(hostID: "office", sessionName: "test")
            var created: [(AgentBrowserTabState, UUID?)] = []
            workspace.onCreate = { created.append(($0, $1)) }
            service.register(workspace)
            try await service.openManualTab(in: workspace, target: target)
            let parent = UUID()
            let child = UUID()
            let route = try #require(runtime.requests.first?.0)
            service.browserTabCreated(parent.uuidString, view: NSView(), route: route, owner: "", parent: nil)
            service.browserTabCreated(child.uuidString, view: NSView(), route: route, owner: "", parent: parent.uuidString)
            #expect(created.count == 2)
            #expect(created.allSatisfy { $0.0.manualTarget == target && $0.0.owner.isEmpty })
            #expect(created.last?.1 == parent)
            service.unregister(workspace)
            #expect(Set(runtime.closed) == Set([parent.uuidString, child.uuidString]))
            #expect(created.allSatisfy { $0.0.isClosed })
            let late = UUID().uuidString
            service.browserTabCreated(late, view: NSView(), route: route, owner: "", parent: nil)
            #expect(runtime.closed.contains(late))
            #expect(created.count == 2)
        }

        @Test("Renamed sessions keep existing and future child tabs; reusing the old name does not retarget them")
        func sessionRename() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let workspace = AgentBrowserWorkspace()
            service.register(workspace)
            let old = ManualBrowserTarget(hostID: "office", sessionName: "old")
            let new = ManualBrowserTarget(hostID: "office", sessionName: "new")
            var created: [AgentBrowserTabState] = []
            workspace.onCreate = { state, _ in created.append(state) }
            try await service.openManualTab(in: workspace, target: old)
            let route = try #require(runtime.requests.first?.0)
            let parent = UUID().uuidString
            service.browserTabCreated(parent, view: NSView(), route: route, owner: "", parent: nil)
            service.renameManualTabs(in: workspace, from: old, to: new)
            #expect(created.first?.manualTarget == new)
            // CEF inherits the original dictionary, not a fresh lookup by name.
            service.browserTabCreated(UUID().uuidString, view: NSView(), route: route, owner: "", parent: parent)
            try await service.openManualTab(in: workspace, target: old)
            service.browserTabCreated(UUID().uuidString, view: NSView(),
                route: try #require(runtime.requests.last?.0), owner: "", parent: nil)
            #expect(created.map(\.manualTarget) == [new, new, old])
            #expect(runtime.requests.first?.0["manualRoute"] != runtime.requests.last?.0["manualRoute"])
        }

        @Test("Manual and agent routing cannot be confused")
        func invalidManualRoute() {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let workspace = AgentBrowserWorkspace()
            var creations = 0
            workspace.onCreate = { _, _ in creations += 1 }
            service.register(workspace)
            service.browserTabCreated(UUID().uuidString, view: NSView(),
                route: ["workspace": workspace.id.uuidString, "pane": "%1"], owner: "", parent: nil)
            service.browserTabCreated(UUID().uuidString, view: NSView(),
                route: ManualBrowserTarget(sessionName: "test").route(workspaceID: workspace.id), owner: "codex-owner", parent: nil)
            #expect(creations == 0)
            #expect(runtime.closed.count == 2)
        }
    }
#endif
