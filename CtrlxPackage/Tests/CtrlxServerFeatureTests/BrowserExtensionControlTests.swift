import CryptoKit
import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
import ZIPFoundation
@testable import CtrlxServerFeature

@Suite("Browser extension control") @MainActor
struct BrowserExtensionControlTests {
    @Test
    func storeCreatesEmbeddedHumanTabInSamePaneAndReturnsItToViewer() async throws {
        let (service, _, source) = try await RemoteBrowserControlTests().fixture()
        let surface = UUID()
        var grant: UUID?
        func send(_ operation: RemoteBrowserExtensionOperation) async throws -> RemoteBrowserResponse {
            try await service.handleBrowser(.init(sessionName: source.sessionName, tabID: source.id, surfaceID: surface, controlID: grant, operation: .extensions(operation)), viewerID: "viewer")
        }
        grant = try #require(try await send(.acquire).controlID)
        #expect(try await send(.list).extensions?.canBrowseStore == true)
        let opened = try #require(try await send(.openStore).extensions?.openedStoreTab)
        #expect(opened.id != source.id)
        #expect(opened.sourcePaneID == source.sourcePaneID)
        #expect(opened.sessionName == source.sessionName)
        #expect(opened.url == BrowserExtensionStoreURL.home)
        #expect(!opened.isAgentOwned)
        #expect(opened.isExtensionWindow != true)
        let frame = try await send(.frame)
        #expect(frame.extensions?.openedStoreTab == opened)
        #expect(frame.frame?.isValid == true)
        _ = try await send(.release)
        await #expect(throws: (any Error).self) { try await send(.openStore) }
        await service.shutdown()
    }

    @Test
    func managerStoreCallbackKeepsViewerRouteAndClosesTabAfterTakeover() async throws {
        let (service, runtime, source) = try await RemoteBrowserControlTests().fixture()
        let grant = try #require(try await service.handleBrowser(.init(sessionName: source.sessionName, tabID: source.id, surfaceID: UUID(), operation: .extensions(.acquire)), viewerID: "viewer").controlID)
        let workspace = AgentBrowserWorkspace()
        workspace.acceptsPane = { _ in true }
        service.register(workspace)
        var selected: [UUID] = []
        workspace.onSelect = { selected.append($0.id) }
        let url = BrowserExtensionStoreURL.home + "detail/fixture/abcdefghijklmnopabcdefghijklmnop"
        let opened: String = try await withCheckedThrowingContinuation { continuation in
            service.browserTab(source.id.uuidString, openWebStoreURL: url, controlToken: grant.uuidString) { id, error in
                if let id {
                    continuation.resume(returning: id)
                } else {
                    continuation.resume(throwing: RemoteBrowserError.message(error ?? "Missing tab"))
                }
            }
        }
        #expect(service.extensionControl?.openedStoreTab?.id.uuidString == opened)
        #expect(service.extensionControl?.openedStoreTab?.url == url)
        #expect(selected.isEmpty)
        runtime.onManualCreated = { runtime.extensionGrant = nil }
        let tab = try #require(service.tabs[source.id.uuidString])
        await #expect(throws: (any Error).self) { try await service.openExtensionStore(for: tab, controlID: grant) }
        #expect(runtime.closed.count == 1)
        #expect(runtime.closed.first != opened)
        await service.shutdown()
    }

    @Test
    func storeNavigationKeepsLegacyViewerPollingAndAbleToReacquire() async throws {
        // Decode only fields understood before store handoff support.
        struct LegacyResponse: Decodable {
            struct Extensions: Decodable { let surface: RemoteBrowserExtensionSurface? }
            let tab: RemoteBrowserTab?
            let frame: RemoteBrowserFrame?
            let controlID: UUID?
            let extensions: Extensions?
        }
        let (service, _, source) = try await RemoteBrowserControlTests().fixture()
        var framesAfterStore = 0
        let session = RemoteBrowserSession(tab: source, managesExtensions: true) { request in
            let response = try await service.handleBrowser(request, viewerID: "legacy")
            if response.extensions?.openedStoreTab != nil {
                framesAfterStore += 1
            }
            let legacy = try JSONDecoder().decode(LegacyResponse.self, from: JSONEncoder().encode(response))
            return .init(tab: legacy.tab, frame: legacy.frame, controlID: legacy.controlID, extensions: .init(surface: legacy.extensions?.surface))
        }
        let watch = Task { await session.watch() }
        defer { watch.cancel()
            session.stop()
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        await session.takeControl()
        let grant = try #require(session.controlID)
        let url = BrowserExtensionStoreURL.home
        let opened: String? = await withCheckedContinuation { continuation in
            service.browserTab(source.id.uuidString, openWebStoreURL: url, controlToken: grant.uuidString) { id, _ in
                continuation.resume(returning: id)
            }
        }
        #expect(opened != nil)
        for _ in 0..<100 {
            if framesAfterStore >= 2 || session.controlID == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(framesAfterStore >= 2)
        #expect(session.frame?.isValid == true)
        #expect(session.controlID == grant)
        session.releaseControl()
        for _ in 0..<100 {
            if service.extensionControl == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await session.takeControl()
        #expect(session.controlID != nil)
        #expect(session.controlID != grant)
        watch.cancel()
        await watch.value
        await service.shutdown()
    }

    @Test
    func localStoreCallbackClearsRevokedLeaseBeforeViewerPoll() async throws {
        let (service, runtime, source) = try await RemoteBrowserControlTests().fixture()
        let grant = try #require(try await service.handleBrowser(.init(sessionName: source.sessionName, tabID: source.id, surfaceID: UUID(), operation: .extensions(.acquire)), viewerID: "viewer").controlID)
        let workspace = AgentBrowserWorkspace()
        workspace.acceptsPane = { _ in true }
        service.register(workspace)
        var selected: [UUID] = []
        workspace.onSelect = { selected.append($0.id) }
        // Native Host input revokes immediately, before the next Viewer ping.
        runtime.extensionGrant = nil
        #expect(service.extensionControl?.lease.id == grant)
        let opened: String = try await withCheckedThrowingContinuation { continuation in
            service.browserTab(source.id.uuidString, openWebStoreURL: BrowserExtensionStoreURL.home, controlToken: nil) { id, error in
                if let id {
                    continuation.resume(returning: id)
                } else {
                    continuation.resume(throwing: RemoteBrowserError.message(error ?? "Missing tab"))
                }
            }
        }
        #expect(service.extensionControl == nil)
        #expect(selected.map(\.uuidString) == [opened])
        let tab = try #require(service.tabs[source.id.uuidString])
        await #expect(throws: (any Error).self) { try await service.openExtensionStore(for: tab, controlID: grant) }
        await service.shutdown()
    }

    @Test
    func localStoreSelectsNewTabOnce() async throws {
        let (service, _, source) = try await RemoteBrowserControlTests().fixture()
        let workspace = AgentBrowserWorkspace()
        workspace.acceptsPane = { _ in true }
        service.register(workspace)
        var selected: [UUID] = []
        workspace.onSelect = { selected.append($0.id) }
        let tab = try #require(service.tabs[source.id.uuidString])
        let opened = try await service.openExtensionStore(for: tab)
        #expect(selected == [opened.id])
        await service.shutdown()
    }

    @Test
    func storeRejectsStaleNativeGrantAndForeignURL() async throws {
        let (service, runtime, source) = try await RemoteBrowserControlTests().fixture()
        let grant = try #require(try await service.handleBrowser(.init(sessionName: source.sessionName, tabID: source.id, surfaceID: UUID(), operation: .extensions(.acquire)), viewerID: "viewer").controlID)
        let tab = try #require(service.tabs[source.id.uuidString])
        await #expect(throws: (any Error).self) { try await service.openExtensionStore(for: tab, url: "https://example.com", controlID: grant) }
        runtime.extensionGrant = nil
        await #expect(throws: (any Error).self) { try await service.openExtensionStore(for: tab, controlID: grant) }
        #expect(service.sharedBrowserTabs.count == 1)
        await service.shutdown()
    }

    @Test(arguments: [true, false, nil] as [Bool?])
    func settingsRequireAdvertisedOptionsAndKeepNativeGrant(hasOptions: Bool?) async throws {
        let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
        let surface = UUID()
        var grant: UUID?
        var item = BrowserExtensionRuntimeItem(id: String(repeating: "a", count: 32), name: "Options", version: "1", state: "ENABLED", path: nil, hasOptions: hasOptions)
        runtime.onExtensionRequest = { _ in try JSONEncoder().encode(["extensions": [item]]) }
        func send(_ operation: RemoteBrowserExtensionOperation) async throws -> RemoteBrowserResponse {
            try await service.handleBrowser(.init(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surface, controlID: grant, operation: .extensions(operation)), viewerID: "one")
        }
        grant = try #require(try await send(.acquire).controlID)
        #expect(try await send(.list).extensions?.entries?.first?.hasOptions == hasOptions)
        if hasOptions == true {
            let response = try await send(.openOptions(item.id))
            #expect(response.extensions?.surface == .options)
            #expect(runtime.extensionRequests.last?["operation"] as? String == "openOptions")
            #expect(runtime.extensionRequests.last?["lease"] as? String == grant?.uuidString)
            #expect(try await send(.frame).extensions?.surface == .options)
        } else {
            await #expect(throws: (any Error).self) { try await send(.openOptions(item.id)) }
            #expect(!runtime.extensionRequests.contains { $0["operation"] as? String == "openOptions" })
        }
        item = .init(id: item.id, name: item.name, version: "1", state: "DISABLED", path: nil, hasOptions: true)
        await #expect(throws: (any Error).self) { try await send(.openOptions(item.id)) }
        await #expect(throws: (any Error).self) { try await send(.openOptions("missing")) }
        service.disconnectBrowserViewer("one")
        await #expect(throws: (any Error).self) { try await send(.openOptions(item.id)) }
        await service.shutdown()
    }

    @Test
    func grantIsSeparateFromPageAndBoundToViewerSurfaceAndSource() async throws {
        let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
        let surface = UUID()
        func request(_ operation: RemoteBrowserOperation, control: UUID? = nil, surfaceID: UUID? = nil) -> BrowseBrowser {
            .init(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surfaceID ?? surface, controlID: control, generation: 7, operation: operation)
        }
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.extensions(.list)), viewerID: "one") }
        let pageGrant = try #require(try await service.handleBrowser(request(.takeControl), viewerID: "one").controlID)
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.extensions(.acquire), control: pageGrant), viewerID: "one") }
        _ = try await service.handleBrowser(request(.releaseControl, control: pageGrant), viewerID: "one")
        let grant = try #require(try await service.handleBrowser(request(.extensions(.acquire)), viewerID: "one").controlID)
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.takeControl), viewerID: "one") }
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.extensions(.acquire)), viewerID: "two") }
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.extensions(.list), control: grant, surfaceID: UUID()), viewerID: "one") }
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.extensions(.text("wrong viewer")), control: grant), viewerID: "two") }
        _ = try await service.handleBrowser(request(.extensions(.release), control: grant), viewerID: "two")
        #expect(service.extensionControl?.lease.id == grant)
        let result = try await service.handleBrowser(request(.extensions(.list), control: grant), viewerID: "one")
        #expect(result.extensions?.entries == [])
        #expect(runtime.extensionRequests.last?["lease"] as? String == grant.uuidString)
        #expect(service.remoteControls.isEmpty)
        service.disconnectBrowserViewer("two")
        #expect(service.extensionControl != nil)
        service.disconnectBrowserViewer("one")
        #expect(service.extensionControl == nil)
        #expect(runtime.extensionGrant == nil)
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.extensions(.text("late")), control: grant), viewerID: "one") }
        await service.shutdown()
    }

    @Test
    func nativeHostTakebackAndExpiryInvalidateSwiftState() async throws {
        let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
        let surface = UUID()
        func request(_ op: RemoteBrowserExtensionOperation, control: UUID? = nil) -> BrowseBrowser {
            .init(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surface, controlID: control, operation: .extensions(op))
        }
        let grant = try #require(try await service.handleBrowser(request(.acquire), viewerID: "one").controlID)
        runtime.extensionGrant = nil // A physical Host click revoked the native grant.
        await #expect(throws: (any Error).self) { try await service.handleBrowser(request(.list, control: grant), viewerID: "one") }
        #expect(service.extensionControl == nil)
        #expect(service.sharedBrowserTabs.allSatisfy { !$0.isControlled })
        _ = try await service.handleBrowser(request(.acquire), viewerID: "one")
        service.extensionControl?.lease.expires = .now.advanced(by: .seconds(-1))
        service.expireBrowserControls()
        #expect(service.extensionControl == nil)
        #expect(runtime.extensionGrant == nil)
        await service.shutdown()
    }

    @Test
    func disconnectWhileCapturingRejectsLateFrame() async throws {
        let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
        let surface = UUID()
        let acquire = BrowseBrowser(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surface, operation: .extensions(.acquire))
        let grant = try #require(try await service.handleBrowser(acquire, viewerID: "one").controlID)
        runtime.deferExtensionFrame = true
        let capture = Task {
            try await service.handleBrowser(.init(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surface, controlID: grant, operation: .extensions(.frame)), viewerID: "one")
        }
        for _ in 0..<100 where runtime.extensionFrameReply == nil {
            await Task.yield()
        }
        let reply = try #require(runtime.extensionFrameReply)
        service.disconnectBrowserViewer("one")
        try reply(JSONEncoder().encode(RemoteBrowserFrame(jpeg: Data([1]), width: 1_200, height: 800, generation: 7)), nil)
        await #expect(throws: (any Error).self) { try await capture.value }
        await service.shutdown()
    }

    @Test
    func uploadPreviewCannotBeUsedByNextGrant() async throws {
        let (service, _, tab) = try await RemoteBrowserControlTests().fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserExtensionStore(profile: root)
        service.extensionStore = store
        let surface = UUID()
        var grant: UUID?
        func send(_ operation: RemoteBrowserExtensionOperation) async throws -> RemoteBrowserResponse {
            try await service.handleBrowser(.init(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surface, controlID: grant, operation: .extensions(operation)), viewerID: "one")
        }
        grant = try #require(try await send(.acquire).controlID)
        let preview = try await uploadFixture(send: send)
        #expect(preview.permissions == ["storage"])
        #expect(preview.extensionID.count == 32)
        service.disconnectBrowserViewer("one")
        await service.extensionCleanupTask?.value
        await #expect(throws: (any Error).self) { try await store.prepared(preview.id) }
        grant = try #require(try await send(.acquire).controlID)
        await #expect(throws: (any Error).self) { try await send(.install(preview.id)) }
        await service.shutdown()
    }

    enum InstallFailure: CaseIterable {
        case beforeSubmission
        case rejected
        case unknown
    }

    @Test("Failed installs release the preview without deleting submitted packages", arguments: InstallFailure.allCases)
    func failedInstallAllowsRefreshAndNextPreview(failure: InstallFailure) async throws {
        let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserExtensionStore(profile: root)
        service.extensionStore = store
        let surface = UUID()
        var grant: UUID?
        func send(_ operation: RemoteBrowserExtensionOperation) async throws -> RemoteBrowserResponse {
            try await service.handleBrowser(.init(sessionName: tab.sessionName, tabID: tab.id, surfaceID: surface, controlID: grant, operation: .extensions(operation)), viewerID: "one")
        }
        grant = try #require(try await send(.acquire).controlID)
        let preview = try await uploadFixture(send: send)
        let package = root.appendingPathComponent("CtrlXExtensions/packages/\(preview.id.uuidString)")
        let manifest = package.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        var busy = false
        var recovered = false
        var installs = 0
        var installed: [BrowserExtensionRuntimeItem] = []
        let failureMessage = "Fixture install failure: \(failure)"
        runtime.onExtensionRequest = { request in
            if busy {
                throw BrowserExtensionPackageError("Native operation is still running")
            }
            if failure == .beforeSubmission, !recovered {
                throw BrowserExtensionPackageError(failureMessage)
            }
            if request["operation"] as? String == "install" {
                installs += 1
                #expect(request["path"] as? String == package.path)
                busy = failure == .unknown
                throw BrowserExtensionPackageError(failureMessage)
            }
            return try JSONEncoder().encode(["extensions": installed])
        }
        do {
            _ = try await send(.install(preview.id))
            Issue.record("The runtime should reject the install")
        } catch {
            #expect(error.localizedDescription == failureMessage)
        }
        #expect(service.extensionControl?.lease.id == grant)
        #expect(service.extensionControl?.prepared.isEmpty == true)
        #expect(!service.extensionOperationInProgress)
        if failure == .beforeSubmission {
            #expect(!FileManager.default.fileExists(atPath: package.path))
            await #expect(throws: (any Error).self) { try await store.prepared(preview.id) }
        } else {
            #expect(FileManager.default.fileExists(atPath: manifest.path))
            #expect(try await store.prepared(preview.id).id == preview.id)
            await #expect(throws: (any Error).self) { try await store.cancel(preview.id) }
        }
        await #expect(throws: (any Error).self) { try await send(.install(preview.id)) }
        #expect(installs == (failure == .beforeSubmission ? 0 : 1))
        if failure == .unknown {
            await #expect(throws: (any Error).self) { try await send(.list) }
            // Chromium can complete after the timeout; refresh must show its actual result.
            installed = [.init(id: preview.extensionID, name: preview.name, version: preview.version, state: "ENABLED", path: package.path)]
        }
        busy = false
        recovered = true
        let refreshed = try await send(.list)
        #expect(refreshed.extensions?.entries?.map(\.id) == installed.map(\.id))
        #expect(refreshed.controlID == grant)
        let next = try await uploadFixture(send: send)
        #expect(next.id != preview.id)
        _ = try await send(.discard(next.id))
        await #expect(throws: (any Error).self) { try await store.prepared(next.id) }
        #expect(FileManager.default.fileExists(atPath: manifest.path) == (failure != .beforeSubmission))
        await service.shutdown()
    }

    private func uploadFixture(send: (RemoteBrowserExtensionOperation) async throws -> RemoteBrowserResponse) async throws -> RemoteBrowserExtensionPreview {
        let upload = UUID()
        let archive = try Archive(accessMode: .create)
        let manifest = Data(#"{"manifest_version":3,"name":"Private fixture","version":"1.0","permissions":["storage"]}"#.utf8)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(manifest.count)) { offset, count in
            manifest.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        let data = try #require(archive.data)
        _ = try await send(.beginUpload(id: upload, name: "fixture.zip", size: data.count, replacingID: nil))
        _ = try await send(.appendUpload(id: upload, offset: 0, data: data))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let preview = try #require(try await send(.finishUpload(id: upload, sha256: sha)).extensions?.prepared)
        #expect(preview.sha256 == sha)
        return preview
    }

    @Test
    func closingSourceReleasesExtensionControl() async throws {
        let (service, runtime, tab) = try await RemoteBrowserControlTests().fixture()
        _ = try await service.handleBrowser(.init(sessionName: tab.sessionName, tabID: tab.id, surfaceID: UUID(), operation: .extensions(.acquire)), viewerID: "one")
        service.browserTabClosed(tab.id.uuidString)
        #expect(service.extensionControl == nil)
        #expect(runtime.extensionGrant == nil)
        await service.shutdown()
    }
}
