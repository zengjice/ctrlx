#if os(macOS)
    import AppKit
    import CtrlxBrowserBridge
    import CtrlxNetworking
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Browser external applications") @MainActor
    struct BrowserExternalApplicationTests {
        final private class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
            func start(with delegate: any CXBrowserHostDelegate, profile: String, state: String) throws { }
            func isReady() -> Bool {
                true
            }

            func startupError() -> String? {
                nil
            }

            func openManualTab(route: [String: String], url: String, completion: @escaping (String?) -> Void) {
                completion(nil)
            }

            func navigateTab(_ identifier: String, url: String) { }
            func goBack(_ identifier: String) { }
            func goForward(_ identifier: String) { }
            func reloadTab(_ identifier: String) { }
            func showDevTools(_ identifier: String) { }
            func closeTab(_ identifier: String) { }
            func setHumanControl(_ token: String?, forTab identifier: String) -> Bool {
                true
            }

            func requestBrowserTab(_ identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                completion(nil, "Unused")
            }

            func beginShutdown() { }
            func finishShutdown() -> Bool {
                true
            }
        }

        final private class Calls {
            var urls: [URL] = []
        }

        private func fixture(fails: Bool = false) throws -> (AgentBrowserService, AgentBrowserTabState, Calls) {
            let calls = Calls()
            let service = withDependencies {
                $0[ExternalApplicationClient.self].open = { url in
                    calls.urls.append(url)
                    if fails {
                        throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No matching application"])
                    }
                    return "Feishu"
                }
            } operation: {
                AgentBrowserService(runtime: Runtime())
            }
            let workspace = AgentBrowserWorkspace()
            var tab: AgentBrowserTabState?
            workspace.onCreate = { value, _ in tab = value }
            service.register(workspace)
            service.browserTabCreated(
                UUID().uuidString,
                view: NSView(),
                route: ["workspace": workspace.id.uuidString, "pane": "%1"],
                owner: "test",
                parent: nil
            )
            return try (service, #require(tab), calls)
        }

        @Test("Human activation opens the exact opaque URL once without changing the page")
        func local() throws {
            let (service, tab, calls) = try fixture()
            tab.url = "https://example.com/device-auth"
            let address = "feishu://open?token=a%2Bb%26c&callback=https%3A%2F%2Fexample.com"
            service.browserTab(tab.identifier, openExternalURL: address, controlToken: nil)
            #expect(calls.urls.map(\.absoluteString) == [address])
            #expect(tab.url == "https://example.com/device-auth")
            #expect(tab.externalApplicationNotice?.message == "Opened Feishu on the Host Mac.")
            #expect(service.descriptor(tab).externalApplicationNotice == tab.externalApplicationNotice)
        }

        @Test("Failed launch is visible without navigating away")
        func failure() throws {
            let (service, tab, calls) = try fixture(fails: true)
            service.browserTab(tab.identifier, openExternalURL: "feishu://open", controlToken: nil)
            #expect(calls.urls.count == 1)
            #expect(tab.externalApplicationNotice?.isError == true)
            #expect(tab.externalApplicationNotice?.message == "No matching application")
            #expect(tab.url == "about:blank")
        }

        @Test("Viewer launches require the exact live control lease")
        func viewerLease() throws {
            let (service, tab, calls) = try fixture()
            let leaseID = UUID()
            service.remoteControls[tab.id] = BrowserControlLease(id: leaseID, viewerID: "viewer", surfaceID: UUID(), expires: .now.advanced(by: .seconds(20)))
            service.browserTab(tab.identifier, openExternalURL: "feishu://open", controlToken: nil)
            service.browserTab(tab.identifier, openExternalURL: "feishu://open", controlToken: UUID().uuidString)
            #expect(calls.urls.isEmpty)
            service.browserTab(tab.identifier, openExternalURL: "feishu://open", controlToken: leaseID.uuidString)
            #expect(calls.urls.count == 1)
            service.remoteControls[tab.id]?.expires = .now.advanced(by: .seconds(-1))
            service.browserTab(tab.identifier, openExternalURL: "feishu://expired", controlToken: leaseID.uuidString)
            service.releaseBrowserControl(tab.id)
            service.browserTab(tab.identifier, openExternalURL: "feishu://released", controlToken: leaseID.uuidString)
            #expect(calls.urls.count == 1)
        }

        @Test("Closed and unknown source tabs cannot launch an app")
        func closed() throws {
            let (service, tab, calls) = try fixture()
            service.browserTabClosed(tab.identifier)
            service.browserTab(tab.identifier, openExternalURL: "feishu://open", controlToken: nil)
            service.browserTab(UUID().uuidString, openExternalURL: "feishu://open", controlToken: nil)
            #expect(calls.urls.isEmpty)
        }

        @Test("Old tab snapshots decode without an external-application notice")
        func compatibility() throws {
            let (service, tab, _) = try fixture()
            let encoder = JSONEncoder()
            let data = try encoder.encode(service.descriptor(tab))
            let old = try JSONDecoder().decode(RemoteBrowserTab.self, from: data)
            #expect(old.externalApplicationNotice == nil)
            service.browserTab(tab.identifier, openExternalURL: "feishu://open", controlToken: nil)
            let new = try JSONDecoder().decode(RemoteBrowserTab.self, from: encoder.encode(service.descriptor(tab)))
            #expect(new.externalApplicationNotice == tab.externalApplicationNotice)
        }
    }
#endif
