#if os(macOS)
    import AppKit
    import CtrlxBrowserBridge
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Remote browser control") @MainActor
    struct RemoteBrowserControlTests {
        @MainActor
        final class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
            weak var delegate: (any CXBrowserHostDelegate)?
            var blocked = false
            var controls: [String: String] = [:]
            var requests: [[String: Any]] = []
            var closed: [String] = []
            var extensionGrant: (tab: String, token: String)?
            var extensionRequests: [[String: Any]] = []
            var onExtensionRequest: (([String: Any]) throws -> Data)?
            var extensionFrameReply: ((Data?, String?) -> Void)?
            var deferExtensionFrame = false
            var onManualCreated: (() -> Void)?
            var permissionResponses: [(String, String, Bool, String?)] = []
            var audioRoutes: [(String, Bool)] = []
            var audioPCM = Data()
            var pendingAudioRead: ((Data?, String?) -> Void)?
            var holdAudioRead = false
            func setBrowserAudioForTab(_ identifier: String, controlToken: String, enabled: Bool) -> Bool {
                guard controls[identifier] == controlToken else { return false }
                audioRoutes.append((identifier, enabled))
                return true
            }

            func readBrowserAudio(forTab identifier: String, controlToken: String, completion: @escaping (Data?, String?) -> Void) {
                if holdAudioRead {
                    pendingAudioRead = completion
                } else {
                    completion(audioPCM, nil)
                }
            }

            func respond(toNetworkPermission id: String, forTab tab: String, allow: Bool, controlToken: String?, completion: @escaping (String?) -> Void) {
                permissionResponses.append((id, tab, allow, controlToken))
                delegate?.browserTab?(tab, networkPermissionChanged: nil)
                completion(nil)
            }

            func start(with delegate: any CXBrowserHostDelegate, profile: String, state: String) throws { }
            func isReady() -> Bool {
                true
            }

            func startupError() -> String? {
                nil
            }

            func openManualTab(route: [String: String], url: String, completion: @escaping (String?) -> Void) {
                let identifier = UUID().uuidString
                delegate?.browserTabCreated(identifier, view: NSView(), route: route, owner: "", parent: nil)
                delegate?.browserTabSelected(identifier)
                onManualCreated?()
                completion(nil)
            }

            func navigateTab(_ identifier: String, url: String) { }
            func goBack(_ identifier: String) { }
            func goForward(_ identifier: String) { }
            func reloadTab(_ identifier: String) { }
            func showDevTools(_ identifier: String) { }
            func closeTab(_ identifier: String) {
                closed.append(identifier)
            }

            func beginShutdown() { }
            func finishShutdown() -> Bool {
                true
            }

            func setHumanControl(_ token: String?, forTab identifier: String) -> Bool {
                guard !blocked else { return false }
                controls[identifier] = token
                return true
            }

            func requestBrowserTab(_ identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else { completion(nil, "Bad request")
                    return
                }
                requests.append(object)
                let frame = RemoteBrowserFrame(jpeg: Data([1, 2, 3]), width: 1_000, height: 700, generation: 4)
                completion(object["action"] as? String == "frame" ? try? JSONEncoder().encode(frame) : Data("{}".utf8), nil)
            }

            func setExtensionControl(_ token: String?, forTab identifier: String) -> Bool {
                if let token {
                    guard !blocked, extensionGrant == nil, controls[identifier] == nil else { return false }
                    extensionGrant = (identifier, token)
                } else if extensionGrant?.tab == identifier {
                    extensionGrant = nil
                }
                return true
            }

            func requestExtensionSurface(forTab identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                guard
                    let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
                    extensionGrant?.tab == identifier, extensionGrant?.token == object["lease"] as? String else {
                    completion(nil, "Native control revoked")
                    return
                }
                extensionRequests.append(object)
                if object["action"] as? String == "frame" {
                    if deferExtensionFrame {
                        extensionFrameReply = completion
                        return
                    }
                    completion(try? JSONEncoder().encode(RemoteBrowserFrame(jpeg: Data([1]), width: 1_200, height: 800, generation: 7)), nil)
                } else {
                    completion(Data("{}".utf8), nil)
                }
            }

            func requestBrowserExtensions(forTab identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                guard
                    let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
                    extensionGrant?.tab == identifier, extensionGrant?.token == object["lease"] as? String else {
                    completion(nil, "Native control revoked")
                    return
                }
                extensionRequests.append(object)
                do {
                    try completion(onExtensionRequest?(object) ?? Data(#"{"extensions":[],"chromiumVersion":"152.0.7977.134"}"#.utf8), nil)
                } catch { completion(nil, error.localizedDescription) }
            }
        }

        func fixture(agent: Bool = true) async throws -> (AgentBrowserService, Runtime, RemoteBrowserTab) {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            runtime.delegate = service
            service.resolveSourcePane = { session, id in PaneBrowserOpeningTests.pane(id, session: session) }
            if agent {
                service.browserTabCreated(
                    UUID().uuidString,
                    view: NSView(),
                    route: ["workspace": UUID().uuidString, "pane": "%1", "session": "test", "window": "@1"],
                    owner: "owner",
                    parent: nil
                )
            } else {
                _ = try await service.openPaneBrowser(sessionName: "test", paneID: "%1")
            }
            return try (service, runtime, #require(service.sharedBrowserTabs.first))
        }

        @Test
        func firstViewerTabStartsRuntimeOnDemand() async throws {
            let runtime = Runtime()
            var starts = 0
            let service = AgentBrowserService(startRuntime: { service in
                starts += 1
                runtime.delegate = service
                return runtime
            })
            service.configure { _ in throw RemoteBrowserError.message("No agent fixture") }
            service.resolveSourcePane = { session, id in PaneBrowserOpeningTests.pane(id, session: session) }
            #expect(service.supportsBrowserSharing)
            #expect(starts == 0)
            let request = BrowseBrowser(sessionName: "test", surfaceID: UUID(), operation: .openPane(url: nil), sourcePaneID: "%1")
            var opened: Set<UUID> = []
            for _ in 0..<2 {
                let response = try await service.handleBrowser(request, viewerID: "viewer")
                let tab = try #require(response.tab)
                #expect(tab.sessionName == "test")
                #expect(tab.sourcePaneID == "%1")
                #expect(!tab.isAgentOwned)
                #expect(opened.insert(tab.id).inserted)
            }
            #expect(starts == 1)
            #expect(service.sharedBrowserTabs.count == 2)
            await service.shutdown()
        }

        @Test
        func networkPermissionRequiresCurrentRequestAndController() async throws {
            let (service, runtime, descriptor) = try await fixture()
            let tab = try #require(service.tabs[descriptor.id.uuidString])
            let id = UUID(), surface = UUID()
            func publish(_ id: UUID) {
                service.browserTab(tab.identifier, networkPermissionChanged: ["id": id.uuidString, "origin": "https://example.com", "localNetwork": false, "loopbackNetwork": true])
            }
            func request(_ operation: RemoteBrowserOperation, control: UUID? = nil, surfaceID: UUID? = nil) -> BrowseBrowser {
                .init(sessionName: "test", tabID: tab.id, surfaceID: surfaceID ?? surface, controlID: control, operation: operation)
            }
            publish(id)
            #expect(service.descriptor(tab).networkPermission?.id == id)
            try await service.respondToNetworkPermission(id, tab: tab, allow: true)
            #expect(runtime.permissionResponses.count == 1)
            #expect(runtime.permissionResponses[0].3 == nil)
            #expect(tab.networkPermission == nil)
            await #expect(throws: (any Error).self) { try await service.respondToNetworkPermission(id, tab: tab, allow: true) }

            publish(id)
            let control = try #require(try await service.handleBrowser(request(.takeControl), viewerID: "a").controlID)
            await #expect(throws: (any Error).self) { try await service.respondToNetworkPermission(id, tab: tab, allow: true) }
            await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.networkPermission(id: id, allow: true), control: control), viewerID: "b") }
            await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.networkPermission(id: id, allow: true), control: control, surfaceID: UUID()), viewerID: "a") }
            await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.networkPermission(id: UUID(), allow: true), control: control), viewerID: "a") }
            let response = try await service.handleBrowser(request(.networkPermission(id: id, allow: false), control: control), viewerID: "a")
            #expect(response.tab?.networkPermission == nil)
            #expect(runtime.permissionResponses.count == 2)
            #expect(runtime.permissionResponses[1].2 == false && runtime.permissionResponses[1].3 == control.uuidString)

            publish(UUID())
            service.releaseBrowserControl(tab.id)
            await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.networkPermission(id: id, allow: true), control: control), viewerID: "a") }
            #expect(runtime.permissionResponses.count == 2)
            service.browserTab(tab.identifier, networkPermissionChanged: nil)
            #expect(tab.networkPermission == nil)
            await service.shutdown()
        }

        @Test
        func viewerStartupFailureIsReportedWithoutRetryingRuntime() async {
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in
                starts += 1
                throw RemoteBrowserError.message("Native runtime unavailable")
            })
            service.configure { _ in throw RemoteBrowserError.message("No agent fixture") }
            service.resolveSourcePane = { session, id in PaneBrowserOpeningTests.pane(id, session: session) }
            let request = BrowseBrowser(sessionName: "test", surfaceID: UUID(), operation: .openPane(url: nil), sourcePaneID: "%1")
            for _ in 0..<2 {
                do {
                    _ = try await service.handleBrowser(request, viewerID: "viewer")
                    Issue.record("Viewer creation ignored startup failure")
                } catch {
                    #expect(error.localizedDescription == "Native runtime unavailable")
                }
            }
            #expect(starts == 1)
            #expect(service.sharedBrowserTabs.isEmpty)
            await service.shutdown()
        }

        @Test
        func controllerIsolationAndDisconnect() async throws {
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
            let workspace = AgentBrowserWorkspace()
            var selectedChild: UUID?
            workspace.acceptsSession = { $0 == "test" }
            workspace.onSelect = { selectedChild = $0.id }
            service.register(workspace)
            let child = UUID()
            service.browserTabCreated(
                child.uuidString,
                view: NSView(),
                route: ["workspace": workspace.id.uuidString, "pane": "%1", "session": "test"],
                owner: "owner",
                parent: tab.id.uuidString
            )
            #expect(
                service.tabs[child.uuidString]?.suppressInitialSelection == false,
                "Native Agent popups have no initial selection callback to suppress"
            )
            #expect(selectedChild == nil)
            _ = try await service.handleBrowser(request(.releaseControl, control: control), viewerID: "b")
            #expect(service.remoteControls[tab.id] != nil)
            service.disconnectBrowserViewer("a")
            #expect(service.remoteControls.isEmpty && runtime.controls.isEmpty)
            service.browserTabSelected(child.uuidString)
            #expect(selectedChild == child, "An explicit show must work on the first attempt")
            service.unregister(workspace)
            await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.text("stale"), control: control), viewerID: "a") }
            await service.shutdown()
        }

        @Test
        func agentBusyAndExpiredControl() async throws {
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

        @Test
        func manualPageDoesNotNeedHostWorkspace() async throws {
            let (service, _, tab) = try await fixture(agent: false)
            #expect(!tab.isAgentOwned)
            let result = try await service.handleBrowser(.init(sessionName: "test", tabID: tab.id, surfaceID: UUID(), operation: .frame), viewerID: "a")
            #expect(result.frame?.isValid == true)
            await service.shutdown()
        }

        @Test
        func extensionWindowCannotAcquireLegacyPageControl() async throws {
            let (service, runtime, initial) = try await fixture(agent: false)
            let tab = try #require(service.tabs[initial.id.uuidString])
            tab.isExtensionWindow = true
            #expect(service.descriptor(tab).isExtensionWindow == true)
            let request = BrowseBrowser(sessionName: "test", tabID: tab.id, surfaceID: UUID(), operation: .takeControl)
            await #expect(throws: (any Error).self) { try await service.handleBrowser(request, viewerID: "legacy") }
            #expect(runtime.controls.isEmpty)
            #expect(service.remoteControls.isEmpty)
            let frame = try await service.handleBrowser(.init(sessionName: "test", tabID: tab.id, surfaceID: UUID(), operation: .frame), viewerID: "legacy")
            #expect(frame.frame?.isValid == true)
            await service.shutdown()
        }

        @Test
        func captureSizeIsValidatedAndForwardedWithoutChangingViewport() async throws {
            let (service, runtime, tab) = try await fixture()
            defer { service.disconnectBrowserViewer("a") }
            func request(_ dimension: Int?) -> BrowseBrowser {
                .init(sessionName: "test", tabID: tab.id, surfaceID: UUID(), frameMaxDimension: dimension, operation: .frame)
            }
            _ = try await service.handleBrowser(request(nil), viewerID: "a")
            #expect(runtime.requests.last?["maximumDimension"] == nil)
            for dimension in [256, 1_280, 2_560] {
                _ = try await service.handleBrowser(request(dimension), viewerID: "a")
                #expect(runtime.requests.last?["maximumDimension"] as? Int == dimension)
                #expect(runtime.requests.last?["action"] as? String == "frame")
            }
            let count = runtime.requests.count
            for dimension in [0, 255, 2_561, Int.max] {
                await #expect(throws: (any Error).self) { try await service.handleBrowser(request(dimension), viewerID: "a") }
            }
            #expect(runtime.requests.count == count)
            #expect(service.remoteCaptures.isEmpty)
            await service.shutdown()
        }

        @Test
        func annotationReadsWithoutTakingControlAndManualSourceIsNotAuthority() async throws {
            let (service, runtime, _) = try await fixture()
            let source = try #require(AgentImageTarget(pane: PaneState(
                paneId: "%7",
                sessionName: "test",
                tmuxWindowId: "@2",
                agentSession: AgentSession(paneId: "%7", pluginID: "codex"),
                claudeSessionID: "source"
            )))
            service.imageTargetForPane = { $0 == "%7" ? source : nil }
            let result = try await service.handleBrowser(.init(sessionName: "test", surfaceID: UUID(), operation: .create, sourcePaneID: "%7"), viewerID: "viewer")
            let tab = try #require(result.tab)
            #expect(tab.sourceAgent == source)
            #expect(!tab.isAgentOwned)
            let state = try #require(service.tabs[tab.id.uuidString])
            _ = try await service.annotationScreenshot(state)
            #expect(runtime.requests.last?["action"] as? String == "frame")
            #expect(runtime.requests.last?["maximumDimension"] as? Int == 2_560)
            #expect(runtime.controls.isEmpty)
            #expect(state.owner.isEmpty)
            let childID = UUID()
            try service.browserTabCreated(
                childID.uuidString,
                view: NSView(),
                route: ["workspace": state.workspaceID.uuidString, "manualRoute": #require(state.manualRouteID)],
                owner: "",
                parent: tab.id.uuidString
            )
            #expect(service.tabs[childID.uuidString]?.sourceAgent == source)
            await service.shutdown()
        }

        @Test
        func hostAnnotationScreenshotRemainsAvailableDuringViewerControl() async throws {
            let (service, runtime, tab) = try await fixture()
            let state = try #require(service.tabs[tab.id.uuidString])
            let lease = try #require(try await service.handleBrowser(
                .init(sessionName: "test", tabID: tab.id, surfaceID: UUID(), operation: .takeControl),
                viewerID: "viewer"
            ).controlID)
            #expect(state.isRemotelyControlled)

            let screenshot = try await service.annotationScreenshot(state)
            #expect(screenshot == Data([1, 2, 3]))
            #expect(runtime.requests.last?["action"] as? String == "frame")
            #expect(runtime.requests.last?["maximumDimension"] as? Int == 2_560)
            #expect(service.remoteControls[state.id]?.id == lease)
            await service.shutdown()
        }

        @Test
        func validationBeforeNativeBoundary() throws {
            #expect(throws: (any Error).self) { try AgentBrowserService.nativePayload(.text(String(repeating: "文", count: 6_000))) }
            #expect(throws: (any Error).self) { try AgentBrowserService.nativePayload(.fit(width: 0, height: 10)) }
            #expect(throws: (any Error).self) { try AgentBrowserService.nativePayload(.pointer(.init(.down, x: .nan, y: 1))) }
        }

        @Test
        func renamedSessionUpdatesParkedPagesAndPopupRoutes() async throws {
            let (service, _, tab) = try await fixture()
            _ = try await service.openPaneBrowser(sessionName: "test", paneID: "%1")
            func pane(_ session: String) -> PaneInfo {
                PaneInfo(
                    paneId: "%1",
                    target: "\(session):1.0",
                    sessionName: session,
                    windowIndex: 1,
                    paneIndex: 0,
                    command: "codex",
                    currentPath: "/tmp",
                    width: 80,
                    height: 24,
                    isActive: true
                )
            }
            service.updateBrowserRoutes([pane("test")])
            service.updateBrowserRoutes([pane("renamed")])
            #expect(service.sharedBrowserTabs.count == 2)
            #expect(service.sharedBrowserTabs.allSatisfy { $0.sessionName == "renamed" })
            let child = UUID()
            service.browserTabCreated(
                child.uuidString,
                view: NSView(),
                route: ["workspace": UUID().uuidString, "pane": "%1", "session": "test"],
                owner: "owner",
                parent: tab.id.uuidString
            )
            #expect(service.tabs[child.uuidString]?.sessionName == "renamed")
            #expect(service.tabs[child.uuidString]?.windowID == "renamed:1")
            await service.shutdown()
        }
    }
#endif
