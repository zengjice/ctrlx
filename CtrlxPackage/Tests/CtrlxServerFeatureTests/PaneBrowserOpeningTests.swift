#if os(macOS)
    import AppKit
    import ConcurrencyExtras
    import CtrlxBrowserBridge
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Pane-bound Host browser") @MainActor
    struct PaneBrowserOpeningTests {
        @MainActor
        final class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
            weak var delegate: (any CXBrowserHostDelegate)?
            var requests: [[String: String]] = []
            var navigations: [(String, String)] = []
            var closed: [String] = []
            var failure: String?
            var ready = true
            var initializationFailure: String?
            var shutdowns = 0
            var holdCreation = false
            var pending: (() -> Void)?

            func start(with delegate: any CXBrowserHostDelegate, profile: String, state: String) throws { }
            func isReady() -> Bool {
                ready
            }

            func startupError() -> String? {
                initializationFailure
            }

            func openManualTab(route: [String: String], url: String, completion: @escaping (String?) -> Void) {
                requests.append(route)
                let finish = {
                    if let failure = self.failure {
                        completion(failure)
                        return
                    }
                    let id = UUID().uuidString
                    self.delegate?.browserTabCreated(id, view: NSView(), route: route, owner: "", parent: nil)
                    self.delegate?.browserTabChanged(id, title: "Page", url: url, loading: false)
                    completion(nil)
                }
                if holdCreation {
                    pending = finish
                } else {
                    finish()
                }
            }

            func navigateTab(_ identifier: String, url: String) {
                navigations.append((identifier, url))
                delegate?.browserTabChanged(identifier, title: "Page", url: url, loading: false)
            }

            func goBack(_ identifier: String) { }
            func goForward(_ identifier: String) { }
            func reloadTab(_ identifier: String) { }
            func showDevTools(_ identifier: String) { }
            func setHumanControl(_ token: String?, forTab identifier: String) -> Bool {
                true
            }

            func requestBrowserTab(_ identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                completion(nil, "Not configured")
            }

            func closeTab(_ identifier: String) {
                closed.append(identifier)
                delegate?.browserTabClosed(identifier)
            }

            func beginShutdown() {
                shutdowns += 1
            }

            func finishShutdown() -> Bool {
                true
            }
        }

        static func pane(_ id: String = "%1", session: String = "work", index: Int = 1) -> PaneInfo {
            PaneInfo(
                paneId: id,
                target: "\(session):\(index).0",
                sessionName: session,
                windowIndex: index,
                paneIndex: 0,
                command: "zsh",
                currentPath: "/tmp",
                width: 80,
                height: 24,
                isActive: true
            )
        }

        func fixture() -> (AgentBrowserService, Runtime) {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            runtime.delegate = service
            service.resolveSourcePane = { session, id in
                guard session == "work", ["%1", "%2"].contains(id) else { throw RemoteBrowserError.message("Missing source") }
                return Self.pane(id)
            }
            return (service, runtime)
        }

        @Test
        func linkPreferencesSurviveRetiredEngineSetting() {
            let preferences = PreferencesService.inMemory()
            preferences.setString("webkit", "newBrowserEngine")
            withDependencies {
                $0[PreferencesService.self] = preferences
                $0[LoginItemService.self] = .previewValue
            } operation: {
                let settings = AppSettings()
                settings.browserLinkBehavior = .alwaysInDefaultBrowser
                settings.setBrowserBehavior(.alwaysInApp, for: "localhost:3000")
                let reloaded = AppSettings()
                #expect(reloaded.browserLinkBehavior == .alwaysInDefaultBrowser)
                #expect(reloaded.browserBehavior(for: URL(string: "http://localhost:3000/page")!) == .alwaysInApp)
            }
        }

        @Test("One-click destinations override domain/global rules without saving them", arguments: BrowserLinkBehavior.allCases)
        func linkClickOverridesAreTransient(global: BrowserLinkBehavior) throws {
            let preferences = PreferencesService.inMemory()
            try withDependencies {
                $0[PreferencesService.self] = preferences
                $0[LoginItemService.self] = .previewValue
            } operation: {
                let settings = AppSettings()
                settings.browserLinkBehavior = global
                let url = try #require(URL(string: "https://example.com/path"))
                #expect(settings.effectiveBrowserBehavior(for: url) == global)
                for domain in BrowserLinkBehavior.allCases {
                    settings.setBrowserBehavior(domain, for: "example.com")
                    for override in [nil, .alwaysInApp, .alwaysInDefaultBrowser] as [BrowserLinkBehavior?] {
                        #expect(settings.effectiveBrowserBehavior(for: url, override: override) == (override ?? domain))
                    }
                    let reloaded = AppSettings()
                    #expect(reloaded.browserLinkBehavior == global)
                    #expect(reloaded.browserBehavior(for: url) == domain)
                }
            }
        }

        @Test
        func plainTerminalReusesItsOwnPageWithoutResettingIt() async throws {
            let (service, runtime) = fixture()
            let url = try #require(URL(string: "http://localhost:3000/page"))
            let first = try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: url)
            let same = try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: url)
            let reveal = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            let other = try await service.openPaneBrowser(sessionName: "work", paneID: "%2", url: url)
            #expect(first === same && same === reveal && other !== first)
            #expect(runtime.requests.count == 2 && runtime.navigations.count == 2)
            #expect(first.owner.isEmpty && first.sourceAgent == nil)
            #expect(service.descriptor(first).sourcePaneID == "%1")
            #expect(first.windowID == "work:1")
            #expect(runtime.requests.allSatisfy { $0["pane"] != nil && $0["host"] == nil && $0["remote"] == "true" })
            await service.shutdown()
        }

        @Test
        func localAndViewerRequestsShareTheHostRegistry() async throws {
            let (service, runtime) = fixture()
            let local = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            let request = BrowseBrowser(
                sessionName: "work",
                surfaceID: UUID(),
                operation: .openPane(url: "https://example.com"),
                sourcePaneID: "%1"
            )
            let remote = try await service.handleBrowser(request, viewerID: "phone")
            #expect(remote.tab?.id == local.id)
            #expect(remote.tab?.sourcePaneID == "%1")
            #expect(runtime.requests.count == 1 && runtime.navigations.count == 1)
            await service.shutdown()
        }

        @Test
        func explicitExtraDoesNotReplaceHumanDefault() async throws {
            let (service, runtime) = fixture()
            let primary = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            let extra = try await service.openPaneBrowser(sessionName: "work", paneID: "%1", new: true)
            #expect(extra.id != primary.id && !extra.isPrimary)
            #expect(try await service.openPaneBrowser(sessionName: "work", paneID: "%1") === primary)
            let remote = try await service.handleBrowser(.init(sessionName: "work", surfaceID: UUID(), operation: .create, sourcePaneID: "%1"), viewerID: "phone")
            #expect(remote.tab?.id != primary.id && remote.tab?.id != extra.id)
            #expect(runtime.requests.count == 3)
            service.close(primary)
            let replacement = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            #expect(replacement.id != extra.id && replacement.id != remote.tab?.id)
            await service.shutdown()
        }

        @Test(arguments: [
            ("http://localhost:3000", "http://localhost:3000/"),
            ("HTTP://LOCALHOST:3000", "http://localhost:3000/"),
            ("https://EXAMPLE.com:443", "https://example.com/"),
        ])
        func cefNormalizedAddressDoesNotReloadOrConflictWithLease(_ address: String, _ cefAddress: String) async throws {
            let (service, runtime) = fixture()
            let tab = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            service.browserTabChanged(tab.identifier, title: "Page", url: cefAddress, loading: false)
            let url = try #require(URL(string: address))
            #expect(try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: url) === tab)
            #expect(runtime.navigations.isEmpty)
            service.remoteControls[tab.id] = .init(id: UUID(), viewerID: "other", surfaceID: UUID(), expires: .now.advanced(by: .seconds(20)))
            let result = try await service.handleBrowser(.init(
                sessionName: "work",
                surfaceID: UUID(),
                operation: .openPane(url: address),
                sourcePaneID: "%1"
            ), viewerID: "phone")
            #expect(result.tab?.id == tab.id)
            #expect(runtime.navigations.isEmpty && runtime.requests.count == 1)
            #expect(service.remoteControls[tab.id]?.viewerID == "other")
            await service.shutdown()
        }

        @Test
        func credentialURLsFailBeforeCreatingOrNavigating() async throws {
            let (service, runtime) = fixture()
            let address = "https://user:pass@example.com/path"
            let url = try #require(URL(string: address))
            do {
                _ = try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: url)
                Issue.record("Credential URL should be rejected")
            } catch {
                #expect(error.localizedDescription.contains("usernames or passwords"))
            }
            #expect(runtime.requests.isEmpty && runtime.navigations.isEmpty)
            let tab = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            do {
                _ = try await service.handleBrowser(.init(
                    sessionName: "work",
                    surfaceID: UUID(),
                    operation: .openPane(url: address),
                    sourcePaneID: "%1"
                ), viewerID: "phone")
                Issue.record("Remote credential URL should be rejected")
            } catch {
                #expect(error.localizedDescription.contains("usernames or passwords"))
            }
            #expect(runtime.requests.count == 1 && runtime.navigations.isEmpty && tab.url == "about:blank")
            await service.shutdown()
        }

        @Test(arguments: ["terminal", "git", "files"])
        func delayedOpenRespectsContentSelection(_ content: String) async throws {
            let (service, runtime) = fixture()
            let tabs = SessionFileTabsState()
            var fileWindows: Set<String> = []
            let selection = {
                BrowserOpenSelection(
                    localWindowID: "work:1",
                    remoteSession: nil,
                    remoteWindowID: nil,
                    tabs: tabs,
                    fileBrowserActiveWindowIDs: fileWindows
                )
            }
            let initial = selection()
            runtime.holdCreation = true
            let opening = Task {
                let tab = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
                if selection() == initial {
                    tabs.selectedBrowserTabId = tab.id
                }
            }
            for _ in 0..<100 where runtime.pending == nil {
                await Task.yield()
            }
            try #require(runtime.pending != nil)
            if content == "git" {
                tabs.selectLeftGit()
            }
            if content == "files" {
                fileWindows.insert("work:1")
            }
            runtime.pending?()
            runtime.pending = nil
            try await opening.value
            #expect((tabs.selectedBrowserTabId != nil) == (content == "terminal"))
            #expect(runtime.requests.count == 1)
            await service.shutdown()
        }

        @Test
        func selectionSnapshotTracksTabsAndHostIdentityButNotMetadata() {
            let tabs = SessionFileTabsState()
            let host = RemoteSessionSelection(hostId: "host-a", hostName: "Mac", sessionName: "work")
            let otherHost = RemoteSessionSelection(hostId: "host-b", hostName: "Mac", sessionName: "work")
            func selection(_ remote: RemoteSessionSelection? = nil) -> BrowserOpenSelection {
                BrowserOpenSelection(
                    localWindowID: nil,
                    remoteSession: remote ?? host,
                    remoteWindowID: "work:1",
                    tabs: tabs,
                    fileBrowserActiveWindowIDs: []
                )
            }
            let initial = selection()
            tabs.openBrowserTabs.append(BrowserTab(url: URL(staticString: "https://example.com")))
            #expect(selection() == initial)
            #expect(selection(otherHost) != initial)
            tabs.selectedRight = .git
            #expect(selection() != initial)
            tabs.selectedRight = nil
            tabs.selectedFileTabId = UUID()
            #expect(selection() != initial)
            tabs.selectedFileTabId = nil
            tabs.selectedBrowserTabId = UUID()
            #expect(selection() != initial)
        }

        @Test
        func simultaneousOpensCreateOnlyOnePage() async throws {
            let (service, runtime) = fixture()
            runtime.holdCreation = true
            let first = Task { try await service.openPaneBrowser(sessionName: "work", paneID: "%1") }
            let second = Task { try await service.openPaneBrowser(sessionName: "work", paneID: "%1") }
            for _ in 0..<100 where runtime.pending == nil {
                await Task.yield()
            }
            try #require(runtime.pending != nil)
            runtime.pending?()
            runtime.pending = nil
            let a = try await first.value, b = try await second.value
            #expect(a === b && runtime.requests.count == 1)
            await service.shutdown()
        }

        @Test
        func agentPagesAndPopupChildrenAreNotManualReuseCandidates() async throws {
            let (service, runtime) = fixture()
            let agentID = UUID().uuidString
            service.browserTabCreated(agentID, view: NSView(), route: [
                "workspace": UUID().uuidString,
                "pane": "%1",
                "session": "work",
                "window": "work:1",
            ], owner: "agent", parent: nil)
            let manual = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            let route = try #require(runtime.requests.first)
            let childID = UUID().uuidString
            service.browserTabCreated(childID, view: NSView(), route: route, owner: "", parent: manual.identifier)
            let child = try #require(service.tabs[childID])
            #expect(child.paneID == "%1" && child.owner.isEmpty && child.parentID == manual.id)
            let reused = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            #expect(reused === manual && reused.identifier != agentID)
            service.close(manual)
            let replacement = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            #expect(replacement.id != manual.id && replacement.id != child.id)
            #expect(runtime.navigations.isEmpty)
            await service.shutdown()
        }

        @Test
        func activeLeaseBlocksNavigationButNotViewing() async throws {
            let (service, runtime) = fixture()
            let tab = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            service.remoteControls[tab.id] = .init(id: UUID(), viewerID: "other", surfaceID: UUID(), expires: .now.advanced(by: .seconds(20)))
            #expect(try await service.openPaneBrowser(sessionName: "work", paneID: "%1") === tab)
            let url = try #require(URL(string: "https://example.com/new"))
            await #expect(throws: (any Error).self) { try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: url) }
            #expect(runtime.navigations.isEmpty && runtime.requests.count == 1)
            service.remoteControls[tab.id]?.expires = .now.advanced(by: .seconds(-1))
            _ = try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: url)
            #expect(runtime.navigations.count == 1)
            await service.shutdown()
        }

        @Test
        func missingOrInvalidSourceAndURLCannotCreatePages() async throws {
            let (service, runtime) = fixture()
            for operation in [RemoteBrowserOperation.create, .openPane(url: nil)] {
                await #expect(throws: (any Error).self) {
                    try await service.handleBrowser(.init(sessionName: "work", surfaceID: UUID(), operation: operation), viewerID: "phone")
                }
            }
            for address in ["file:///tmp/a", "javascript:alert(1)", "ftp://example.com", "https:///", "about:blank"] {
                await #expect(throws: (any Error).self) {
                    try await service.handleBrowser(.init(
                        sessionName: "work",
                        surfaceID: UUID(),
                        operation: .openPane(url: address),
                        sourcePaneID: "%1"
                    ), viewerID: "phone")
                }
            }
            await #expect(throws: (any Error).self) { try await service.openPaneBrowser(sessionName: "other", paneID: "%1") }
            await #expect(throws: (any Error).self) { try await service.openPaneBrowser(sessionName: "work", paneID: "%99") }
            #expect(runtime.requests.isEmpty)
            await service.shutdown()
        }

        @Test
        func creationFailureCanRetryWithoutFallback() async throws {
            let (service, runtime) = fixture()
            runtime.failure = "Creation failed"
            await #expect(throws: (any Error).self) { try await service.openPaneBrowser(sessionName: "work", paneID: "%1") }
            runtime.failure = nil
            _ = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            #expect(runtime.requests.count == 2)
            await service.shutdown()
            await #expect(throws: (any Error).self) { try await service.openPaneBrowser(sessionName: "work", paneID: "%1") }
        }

        @Test
        func closedSourceDuringPreparationNeverNavigatesAnotherPane() async throws {
            let (service, runtime) = fixture()
            let sourceAvailable = LockIsolated(true)
            service.resolveSourcePane = { _, id in
                guard sourceAvailable.value else { throw RemoteBrowserError.message("Source closed") }
                return Self.pane(id)
            }
            runtime.holdCreation = true
            let opening = Task {
                try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: URL(string: "https://example.com"))
            }
            for _ in 0..<100 where runtime.pending == nil {
                await Task.yield()
            }
            try #require(runtime.pending != nil)
            sourceAvailable.setValue(false)
            runtime.pending?()
            runtime.pending = nil
            await #expect(throws: (any Error).self) { try await opening.value }
            #expect(runtime.navigations.isEmpty)
            await #expect(throws: (any Error).self) { try await service.openPaneBrowser(sessionName: "work", paneID: "%1") }
            await service.shutdown()
        }

        @Test
        func paneMovesAndRenamesKeepAssociationAndChildren() async throws {
            let (service, runtime) = fixture()
            let parent = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            let route = try #require(runtime.requests.first)
            service.updateBrowserRoutes([Self.pane()])
            service.updateBrowserRoutes([Self.pane(session: "renamed", index: 3)])
            let childID = UUID().uuidString
            service.browserTabCreated(childID, view: NSView(), route: route, owner: "", parent: parent.identifier)
            #expect(parent.sessionName == "renamed" && parent.windowID == "renamed:3")
            #expect(service.tabs[childID]?.paneID == "%1")
            #expect(service.tabs[childID]?.sessionName == "renamed")
            #expect(service.tabs[childID]?.windowID == "renamed:3")
            service.resolveSourcePane = { _, id in Self.pane(id, session: "renamed", index: 3) }
            #expect(try await service.openPaneBrowser(sessionName: "renamed", paneID: "%1") === parent)
            #expect(runtime.requests.count == 1)
            await service.shutdown()
        }

        @Test
        func movingPaneTransfersDisplayWithoutClosingOrDuplicatingPage() async throws {
            let (service, runtime) = fixture()
            let old = AgentBrowserWorkspace(), new = AgentBrowserWorkspace()
            old.acceptsSession = { $0 == "work" }
            new.acceptsPane = { $0.sessionName == "destination" }
            var detached: UUID?, adopted: UUID?
            old.onDetach = { tab in detached = tab.id
                service.close(tab)
            }
            new.onCreate = { tab, _ in adopted = tab.id }
            service.register(old)
            service.register(new)
            let first = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            service.resolveSourcePane = { _, id in Self.pane(id, session: "destination", index: 3) }
            let moved = try await service.openPaneBrowser(sessionName: "destination", paneID: "%1")
            #expect(moved === first && moved.workspaceID == new.id)
            #expect(detached == first.id && adopted == first.id)
            #expect(runtime.closed.isEmpty && runtime.requests.count == 1)
            service.unregister(old)
            service.unregister(new)
            await service.shutdown()
        }

        @Test
        func closingHostWindowParksPageForReuseAndReopening() async throws {
            let (service, runtime) = fixture()
            let first = AgentBrowserWorkspace()
            first.acceptsSession = { $0 == "work" }
            service.register(first)
            let tab = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            service.unregister(first)
            #expect(runtime.closed.isEmpty)
            #expect(try await service.openPaneBrowser(sessionName: "work", paneID: "%1") === tab)
            let reopened = AgentBrowserWorkspace()
            reopened.acceptsSession = { $0 == "work" }
            service.register(reopened)
            #expect(tab.workspaceID == reopened.id && runtime.requests.count == 1)
            service.unregister(reopened)
            await service.shutdown()
        }

        @Test
        func cancellingPreparationDoesNotNavigateOrCreateAnUnboundFallback() async throws {
            let (service, runtime) = fixture()
            runtime.holdCreation = true
            let opening = Task {
                try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: URL(string: "https://example.com"))
            }
            for _ in 0..<100 where runtime.pending == nil {
                await Task.yield()
            }
            try #require(runtime.pending != nil)
            opening.cancel()
            runtime.pending?()
            runtime.pending = nil
            await #expect(throws: CancellationError.self) { try await opening.value }
            let reused = try await service.openPaneBrowser(sessionName: "work", paneID: "%1")
            #expect(runtime.requests.count == 1 && runtime.navigations.isEmpty)
            #expect(reused.paneID == "%1" && reused.url == "about:blank")
            await service.shutdown()
        }
    }
#endif
