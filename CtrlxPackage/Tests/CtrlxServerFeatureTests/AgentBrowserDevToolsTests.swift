#if os(macOS)
    import AppKit
    import CtrlxBrowserBridge
    import Testing
    import ZIPFoundation
    @testable import CtrlxServerFeature

    @Suite("Agent Browser human developer tools")
    @MainActor
    struct AgentBrowserDevToolsTests {
        @MainActor
        final private class Runtime: NSObject, @preconcurrency CXBrowserRuntime {
            var inspected: [String] = []
            var closed: [String] = []
            var extensionSources: [String] = []
            var managedSources: [String] = []
            var revealedWindows: [String] = []
            var extensionRequests: [String] = []
            var extensionResult = Data(#"{"extensions":[]}"#.utf8)
            var onExtensionRequest: (([String: Any]) throws -> Data)?
            var onOpenExtension: ((String) -> String)?
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
            func showDevTools(_ identifier: String) {
                inspected.append(identifier)
            }

            func openExtensionWindow(forTab identifier: String, completion: @escaping (String?, String?) -> Void) {
                extensionSources.append(identifier)
                guard let onOpenExtension else { completion(nil, "No extension window configured")
                    return
                }
                completion(onOpenExtension(identifier), nil)
            }

            func showExtensionManager(forTab identifier: String, completion: @escaping (String?) -> Void) {
                managedSources.append(identifier)
                completion(nil)
            }

            func showBrowserWindow(_ identifier: String) {
                revealedWindows.append(identifier)
            }

            func requestBrowserExtensions(forTab identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                extensionRequests.append(identifier)
                do {
                    let parameters = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
                    try completion(onExtensionRequest?(parameters) ?? extensionResult, nil)
                } catch { completion(nil, error.localizedDescription) }
            }

            func setHumanControl(_ token: String?, forTab identifier: String) -> Bool {
                true
            }

            func requestBrowserTab(_ identifier: String, request: Data, completion: @escaping (Data?, String?) -> Void) {
                completion(nil, "Not configured")
            }

            func closeTab(_ identifier: String) {
                closed.append(identifier)
            }

            func beginShutdown() { }
            func finishShutdown() -> Bool {
                true
            }
        }

        private func addTab(_ service: AgentBrowserService, owner: String) throws -> AgentBrowserTabState {
            let workspace = AgentBrowserWorkspace()
            var tab: AgentBrowserTabState?
            workspace.onCreate = { value, _ in tab = value }
            service.register(workspace)
            service.browserTabCreated(
                UUID().uuidString,
                view: NSView(),
                route: ["workspace": workspace.id.uuidString, "pane": "%1"],
                owner: owner,
                parent: nil
            )
            return try #require(tab)
        }

        private func extensionZIP(version: String) throws -> Data {
            let bytes = try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Transaction Fixture", "version": version])
            let archive = try Archive(accessMode: .create)
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(bytes.count)) { offset, count in
                bytes.subdata(in: Int(offset)..<(Int(offset) + count))
            }
            return try #require(archive.data)
        }

        @Test("A failed native update restores the original package and enabled state", arguments: [true, false])
        func extensionUpdateRecovery(enabled: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            let first = try await store.prepare(data: extensionZIP(version: "1"), source: .zip)
            let previousPath = try await store.beginInstall(first.id, installed: [])
            let previous = try BrowserExtensionRuntimeItem(
                id: #require(first.preview.extensionID),
                name: first.preview.name,
                version: "1",
                state: enabled ? "ENABLED" : "DISABLED",
                path: previousPath.path
            )
            let update = try await store.prepare(data: extensionZIP(version: "2"), source: .zip, replacing: previous)
            let runtime = Runtime()
            var installed = [previous]
            var installs: [String] = []
            runtime.onExtensionRequest = { request in
                switch request["operation"] as? String {
                case "install":
                    let path = try #require(request["path"] as? String)
                    installs.append(path)
                    if path != previousPath.path {
                        installed = []
                        throw BrowserExtensionPackageError("Fixture update rejected")
                    }
                    installed = [BrowserExtensionRuntimeItem(
                        id: previous.id,
                        name: previous.name,
                        version: previous.version,
                        state: "ENABLED",
                        path: previous.path
                    )]
                case "setEnabled":
                    #expect(request["enabled"] as? Bool == false)
                    installed = [previous]
                default: break
                }
                return try JSONEncoder().encode(["extensions": installed])
            }
            let service = AgentBrowserService(runtime: runtime, extensionStore: store)
            let tab = try addTab(service, owner: "update")
            await #expect(throws: (any Error).self) { try await service.installExtension(update, for: tab) }
            #expect(installed == [previous])
            #expect(installs.count == 2 && installs.last == previousPath.path)
            #expect(installs.allSatisfy { FileManager.default.fileExists(atPath: $0) })
            #expect(await store.isManaged(previous))
        }

        @Test("An unknown native install never races a guessed rollback")
        func extensionUpdateUnknownOutcome() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            let first = try await store.prepare(data: extensionZIP(version: "1"), source: .zip)
            let path = try await store.beginInstall(first.id, installed: [])
            let previous = try BrowserExtensionRuntimeItem(
                id: #require(first.preview.extensionID),
                name: first.preview.name,
                version: "1",
                state: "ENABLED",
                path: path.path
            )
            let update = try await store.prepare(data: extensionZIP(version: "2"), source: .zip, replacing: previous)
            let runtime = Runtime()
            var busy = false
            var installCount = 0
            runtime.onExtensionRequest = { request in
                if busy {
                    throw BrowserExtensionPackageError("Native operation is still running")
                }
                if request["operation"] as? String == "install" {
                    busy = true
                    installCount += 1
                    throw BrowserExtensionPackageError("Install outcome unknown")
                }
                return try JSONEncoder().encode(["extensions": [previous]])
            }
            let service = AgentBrowserService(runtime: runtime, extensionStore: store)
            let tab = try addTab(service, owner: "timeout")
            await #expect(throws: (any Error).self) { try await service.installExtension(update, for: tab) }
            #expect(installCount == 1)
            #expect(FileManager.default.fileExists(atPath: path.path))
            await #expect(throws: (any Error).self) { try await store.cancel(update.id) }
        }

        @Test("Cleanup failure keeps the confirmed new version instead of rolling back")
        func extensionUpdateCleanupFailure() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            let first = try await store.prepare(data: extensionZIP(version: "1"), source: .zip)
            let path = try await store.beginInstall(first.id, installed: [])
            let previous = try BrowserExtensionRuntimeItem(
                id: #require(first.preview.extensionID),
                name: first.preview.name,
                version: "1",
                state: "ENABLED",
                path: path.path
            )
            let update = try await store.prepare(data: extensionZIP(version: "2"), source: .zip, replacing: previous)
            let runtime = Runtime()
            var installed = [previous]
            var installCount = 0
            runtime.onExtensionRequest = { request in
                if request["operation"] as? String == "install" {
                    installCount += 1
                    let newPath = try #require(request["path"] as? String)
                    installed = [BrowserExtensionRuntimeItem(id: previous.id, name: previous.name, version: "2", state: "ENABLED", path: newPath)]
                    // Corrupt only this test's old receipt after the native install.
                    try FileManager.default.removeItem(at: root.appendingPathComponent("CtrlXExtensions/receipts/\(first.id.uuidString).json"))
                }
                return try JSONEncoder().encode(["extensions": installed])
            }
            let service = AgentBrowserService(runtime: runtime, extensionStore: store)
            let tab = try addTab(service, owner: "cleanup")
            do {
                try await service.installExtension(update, for: tab)
                Issue.record("Missing old receipt should report a cleanup failure")
            } catch {
                #expect(error.localizedDescription.contains("extension is installed"))
            }
            #expect(installCount == 1 && installed.first?.version == "2")
            #expect(try await store.isManaged(#require(installed.first)))
            #expect(FileManager.default.fileExists(atPath: path.path))
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

        @Test("Extension windows retain the clicked page's association and native presentation")
        func extensionWindowSource() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let first = try addTab(service, owner: "first")
            let second = try addTab(service, owner: "second")
            service.browserTabSelected(second.identifier)
            let child = UUID().uuidString
            runtime.onOpenExtension = { source in
                #expect(source == first.identifier)
                service.browserTabCreated(child, view: NSView(), route: [
                    "workspace": first.workspaceID.uuidString, "pane": first.paneID,
                    "presentation": "extensionWindow", "primary": "false",
                ], owner: first.owner, parent: first.identifier)
                return child
            }
            let window = try await service.openExtensionWindow(first)
            #expect(window.parentID == first.id)
            #expect(window.owner == first.owner)
            #expect(window.workspaceID == first.workspaceID)
            #expect(window.isExtensionWindow && !window.isPrimary)
            #expect(runtime.revealedWindows == [child])
            try await service.showExtensionManager(first)
            service.showBrowserWindow(first)
            service.showBrowserWindow(window)
            #expect(runtime.extensionSources == [first.identifier])
            #expect(runtime.managedSources == [first.identifier])
            #expect(runtime.revealedWindows == [child, child])
        }

        @Test("Extension operations reject stale, foreign and remotely controlled pages")
        func extensionAuthority() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let tab = try addTab(service, owner: "first")
            let other = try addTab(AgentBrowserService(), owner: "other")
            let legacyViewer = try addTab(service, owner: "legacy")
            legacyViewer.manualTarget = ManualBrowserTarget(hostID: "other-host", sessionName: "legacy")
            let impostor = AgentBrowserTabState(
                id: tab.id,
                identifier: tab.identifier,
                view: NSView(),
                workspaceID: tab.workspaceID,
                paneID: tab.paneID,
                owner: tab.owner,
                service: service
            )
            tab.isRemotelyControlled = true
            for invalid in [tab, other, impostor, legacyViewer] {
                await #expect(throws: (any Error).self) { try await service.openExtensionWindow(invalid) }
                await #expect(throws: (any Error).self) { try await service.showExtensionManager(invalid) }
                await #expect(throws: (any Error).self) { try await service.browserExtensions(for: invalid) }
                invalid.isExtensionWindow = true
                service.showBrowserWindow(invalid)
            }
            tab.isRemotelyControlled = false
            service.browserTabClosed(tab.identifier)
            await #expect(throws: (any Error).self) { try await service.openExtensionWindow(tab) }
            await #expect(throws: (any Error).self) { try await service.showExtensionManager(tab) }
            #expect(runtime.extensionSources.isEmpty)
            #expect(runtime.managedSources.isEmpty)
            #expect(runtime.revealedWindows.isEmpty)
            #expect(runtime.extensionRequests.isEmpty)
        }

        @Test("Extension inventory queries retain the source page")
        func extensionInventory() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let first = try addTab(service, owner: "first")
            let second = try addTab(service, owner: "second")
            service.browserTabSelected(second.identifier)
            #expect(try await service.browserExtensions(for: first).isEmpty)
            #expect(runtime.extensionRequests == [first.identifier])
            await service.shutdown()
            await #expect(throws: (any Error).self) { try await service.browserExtensions(for: first) }
            #expect(runtime.extensionRequests == [first.identifier])
        }

        @Test("A terminated extension is not reported as successfully disabled")
        func extensionStateConfirmation() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let tab = try addTab(service, owner: "first")
            let item = BrowserExtensionRuntimeItem(id: String(repeating: "a", count: 32), name: "Fixture", version: "1", state: "ENABLED", path: nil)
            runtime.extensionResult = Data(#"{"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Fixture","version":"1","state":"TERMINATED"}]}"#.utf8)
            await #expect(throws: (any Error).self) { try await service.setExtensionEnabled(item, enabled: false, for: tab) }
            runtime.extensionResult = Data(#"{"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Fixture","version":"1","state":"DISABLED"}]}"#.utf8)
            try await service.setExtensionEnabled(item, enabled: false, for: tab)
        }

        @Test("Extension runtime errors are surfaced without an invented page")
        func extensionFailure() async throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let tab = try addTab(service, owner: "first")
            await #expect(throws: (any Error).self) { try await service.openExtensionWindow(tab) }
            #expect(service.tabs.count == 1)
            await service.shutdown()
            await #expect(throws: (any Error).self) { try await service.showExtensionManager(tab) }
            #expect(runtime.managedSources.isEmpty)
        }

        @Test("A closed or stale tab cannot inspect a different page")
        func closedOrForged() throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let tab = try addTab(service, owner: "first")
            let impostor = AgentBrowserTabState(
                id: tab.id,
                identifier: tab.identifier,
                view: NSView(),
                workspaceID: tab.workspaceID,
                paneID: tab.paneID,
                owner: tab.owner,
                service: service
            )
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

        @Test("Unregister parks Host pages; re-registering reuses the same page")
        func unregisterRemovesUITabs() throws {
            let runtime = Runtime()
            let service = AgentBrowserService(runtime: runtime)
            let workspace = AgentBrowserWorkspace()
            workspace.acceptsSession = { _ in true }
            var visible: [String: AgentBrowserTabState] = [:]
            var removed: [String] = []
            workspace.onCreate = { tab, _ in visible[tab.identifier] = tab }
            workspace.onDetach = { tab in
                visible.removeValue(forKey: tab.identifier)
                service.close(tab)
            }
            workspace.onClose = { tab in
                #expect(tab.isClosed)
                visible.removeValue(forKey: tab.identifier)
                removed.append(tab.identifier)
                // Real UI cleanup also asks the service to close its old state.
                service.close(tab)
            }
            service.register(workspace)
            let id = UUID().uuidString
            service.browserTabCreated(
                id,
                view: NSView(),
                route: ["workspace": workspace.id.uuidString, "pane": "%1"],
                owner: "first",
                parent: nil
            )
            let old = try #require(visible[id])
            let other = try addTab(service, owner: "other-workspace")

            service.unregister(workspace)
            #expect(visible.isEmpty)
            #expect(!old.isClosed)
            #expect(removed.isEmpty)
            #expect(runtime.closed.isEmpty)
            #expect(old.view.window != nil)
            #expect(!other.isClosed)

            service.register(workspace)
            #expect(visible[id] === old)
            let replacement = UUID().uuidString
            service.browserTabCreated(
                replacement,
                view: NSView(),
                route: ["workspace": workspace.id.uuidString, "pane": "%1"],
                owner: "first",
                parent: nil
            )
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
            #expect(removed == [id])
            #expect(runtime.closed.isEmpty)
        }
    }
#endif
