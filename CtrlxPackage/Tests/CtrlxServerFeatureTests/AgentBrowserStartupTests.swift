#if os(macOS)
    import AppKit
    import CtrlxBrowserBridge
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Agent Browser startup")
    struct AgentBrowserStartupTests {
        private typealias Runtime = PaneBrowserOpeningTests.Runtime
        private enum StartupFailure: Error { case failed }

        @Test("Mock keychain cannot select production state and requires an explicit E2E root")
        func mockKeychainRequiresIsolatedState() throws {
            #expect(throws: (any Error).self) {
                try AgentBrowserService.stateDirectory(arguments: ["CtrlX", "--e2e-browser-mock-keychain"])
            }
            #expect(throws: (any Error).self) {
                try AgentBrowserService.stateDirectory(arguments: ["CtrlX", "--e2e-test", "--e2e-browser-mock-keychain"])
            }
            let state = try AgentBrowserService.stateDirectory(arguments: [
                "CtrlX", "--e2e-test", "--e2e-browser-mock-keychain", "--ctrlx-state-root", "/tmp/ctrlx-browser-mock-test",
            ])
            #expect(state.path == "/tmp/ctrlx-browser-mock-test/agent-browser")
        }

        @Test("Configuring and quitting a simulator-only host never starts Chromium")
        func unusedRuntimeStaysStopped() async {
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in
                starts += 1
                throw StartupFailure.failed
            })
            service.configure { _ in throw StartupFailure.failed }
            #expect(starts == 0)
            await service.shutdown()
            #expect(starts == 0)
            await #expect(throws: (any Error).self) { try await service.ensureStarted() }
            #expect(starts == 0)
        }

        @Test("Concurrent first requests wait for one runtime to become ready")
        func firstRequestsShareStartup() async throws {
            let runtime = Runtime()
            runtime.ready = false
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in starts += 1; return runtime })
            service.configure { _ in throw StartupFailure.failed }
            let first = Task { try await service.ensureStarted() }
            let second = Task { try await service.ensureStarted() }
            while starts == 0 { await Task.yield() }
            #expect(starts == 1)
            #expect(runtime.requests.isEmpty)
            runtime.ready = true
            try await first.value
            try await second.value
            #expect(starts == 1)
            await service.shutdown()
            #expect(runtime.shutdowns == 1)
        }

        @Test("A failed initializer is reported without reinitializing CEF")
        func startupFailureIsNotRetried() async {
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in
                starts += 1
                throw StartupFailure.failed
            })
            service.configure { _ in throw StartupFailure.failed }
            for _ in 0..<2 {
                await #expect(throws: StartupFailure.self) { try await service.ensureStarted() }
            }
            #expect(starts == 1)
            await service.shutdown()
        }

        @Test("Deferred native startup failure is reported and never reinitializes CEF")
        func deferredStartupFailureIsNotRetried() async {
            let runtime = Runtime()
            runtime.ready = false
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in starts += 1; return runtime })
            service.configure { _ in throw StartupFailure.failed }
            let request = Task { try await service.ensureStarted() }
            while starts == 0 { await Task.yield() }
            runtime.initializationFailure = "Native initialization failed"
            for attempt in 0..<2 {
                do {
                    if attempt == 0 { try await request.value }
                    else { try await service.ensureStarted() }
                    Issue.record("Deferred startup failure was ignored")
                } catch {
                    #expect(String(describing: error).contains("Native initialization failed"))
                }
            }
            #expect(starts == 1)
            #expect(runtime.requests.isEmpty)
            await service.shutdown()
            #expect(runtime.shutdowns == 1)
        }

        @Test("Quit while startup is pending rejects the request without creating a page")
        func quitDuringStartup() async {
            let runtime = Runtime()
            runtime.ready = false
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in starts += 1; return runtime })
            service.configure { _ in throw StartupFailure.failed }
            let request = Task { try await service.ensureStarted() }
            while starts == 0 { await Task.yield() }
            await service.shutdown()
            await #expect(throws: (any Error).self) { try await request.value }
            #expect(runtime.shutdowns == 1)
            #expect(runtime.requests.isEmpty)
        }

        @Test("A CLI targeting another host's state cannot start Chromium")
        func differentStateDoesNotStartRuntime() async {
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in starts += 1; throw StartupFailure.failed })
            service.configure { _ in throw StartupFailure.failed }
            await #expect(throws: (any Error).self) {
                try await service.prepareForAgentRequests(state: "/tmp/ctrlx-other-host-\(UUID().uuidString)/agent-browser")
            }
            #expect(starts == 0)
        }

        @Test("The first pane-bound human tab starts Chromium and keeps its destination")
        func firstHumanTabStartsRuntime() async throws {
            let runtime = Runtime()
            var starts = 0
            let service = AgentBrowserService(startRuntime: { service in
                starts += 1
                runtime.delegate = service
                return runtime
            })
            service.configure { _ in throw StartupFailure.failed }
            service.resolveSourcePane = { _, id in PaneBrowserOpeningTests.pane(id) }
            let destination = try #require(URL(string: "https://example.com/page"))
            #expect(starts == 0)
            let tab = try await service.openPaneBrowser(sessionName: "work", paneID: "%1", url: destination)
            #expect(starts == 1 && runtime.requests.count == 1)
            #expect(tab.paneID == "%1" && tab.url == destination.absoluteString)
            await service.shutdown()
        }

        @Test("Cancelling a pane open during startup cannot create a late tab")
        func cancelledOpenDuringStartup() async {
            let runtime = Runtime()
            runtime.ready = false
            var starts = 0
            let service = AgentBrowserService(startRuntime: { _ in starts += 1; return runtime })
            service.configure { _ in throw StartupFailure.failed }
            service.resolveSourcePane = { _, id in PaneBrowserOpeningTests.pane(id) }
            let request = Task { try await service.openPaneBrowser(sessionName: "work", paneID: "%1") }
            while starts == 0 { await Task.yield() }
            request.cancel()
            runtime.ready = true
            await #expect(throws: (any Error).self) { try await request.value }
            #expect(runtime.requests.isEmpty)
            await service.shutdown()
        }
    }
#endif
