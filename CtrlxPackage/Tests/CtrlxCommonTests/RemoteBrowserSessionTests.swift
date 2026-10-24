import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Remote browser surface") @MainActor
struct RemoteBrowserSessionTests {
    @Test
    func networkPermissionOnlyUsesAdvertisedRequestWithLiveControl() async throws {
        let id = UUID(), permissionID = UUID(), controlID = UUID()
        var permission: BrowserNetworkPermission? = .init(id: permissionID, origin: "https://example.com", localNetwork: false, loopbackNetwork: true)
        var controlled = false
        var replies = 0
        func tab() -> RemoteBrowserTab {
            .init(id: id, sessionName: "s", title: "page", url: "https://example.com", isLoading: false, isAgentOwned: false, networkPermission: permission)
        }
        let session = RemoteBrowserSession(tab: tab()) { request in
            switch request.operation {
            case .takeControl: controlled = true
            case .releaseControl: controlled = false
            case let .networkPermission(id, allow):
                #expect(id == permissionID && allow)
                #expect(request.controlID == controlID)
                replies += 1
                permission = nil
            default: break
            }
            return .init(tab: tab(), frame: .init(jpeg: Data([1]), width: 300, height: 400, generation: 1), controlID: controlled ? controlID : nil)
        }
        await #expect(throws: (any Error).self) { try await session.respondToNetworkPermission(permissionID, allow: true) }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.controlID != nil }
        await #expect(throws: (any Error).self) { try await session.respondToNetworkPermission(UUID(), allow: true) }
        try await session.respondToNetworkPermission(permissionID, allow: true)
        #expect(session.tab.networkPermission == nil && replies == 1)
        await #expect(throws: (any Error).self) { try await session.respondToNetworkPermission(permissionID, allow: true) }
        session.stop()
        await #expect(throws: (any Error).self) { try await session.respondToNetworkPermission(permissionID, allow: true) }
        #expect(replies == 1)
    }

    @Test
    func clipboardCopyUsesLocalClipboardAndRejectsLateReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clipboard = ClipboardClient.fileBacked(path: root.appendingPathComponent("clipboard").path)
        try await withDependencies { $0[ClipboardClient.self] = clipboard } operation: {
            let host = Host(agent: false)
            var pending: CheckedContinuation<RemoteBrowserResponse, any Error>?
            let session = RemoteBrowserSession(tab: host.tab) { request in
                if request.operation == .copy {
                    if host.delayClipboard {
                        return try await withCheckedThrowingContinuation { pending = $0 }
                    }
                    return .init(controlID: host.control, clipboard: .init(text: "selected 中文"))
                }
                return try await host.send(request)
            }
            let watch = Task { await session.watch() }
            defer { session.stop()
                watch.cancel()
            }
            try await wait { session.controlID != nil }
            session.copy()
            try await wait { clipboard.getString() == "selected 中文" }
            host.delayClipboard = true
            session.copy()
            try await wait { pending != nil }
            session.releaseControl()
            clipboard.setString("new local copy")
            pending?.resume(returning: .init(controlID: host.control, clipboard: .init(text: "stale")))
            try await Task.sleep(for: .milliseconds(20))
            #expect(clipboard.getString() == "new local copy")
        }
    }

    @Test
    func reusedPageRefreshesViewerMetadataWithoutWaitingForAnotherSnapshot() {
        let client = ViewerRelayClient()
        let id = UUID()
        let old = RemoteBrowserTab(
            id: id,
            sessionName: "old",
            title: "Old",
            url: "about:blank",
            isLoading: false,
            isAgentOwned: false,
            sourcePaneID: "%1"
        )
        let opened = RemoteBrowserTab(
            id: id,
            sessionName: "moved",
            title: "New",
            url: "https://example.com",
            isLoading: true,
            isAgentOwned: false,
            sourcePaneID: "%1"
        )
        client.rememberOpenedBrowser(old)
        client.rememberOpenedBrowser(opened)
        #expect(client.browserTabs == [opened])
    }

    @MainActor
    final class Host {
        var control = UUID()
        var delayClipboard = false
        var operations: [RemoteBrowserOperation] = []
        var generations: [UInt64?] = []
        var controlIDs: [UUID?] = []
        var frameDimensions: [Int?] = []
        var owned = false
        var inFlight = 0
        var maximumFrames = 0
        var heldInput: CheckedContinuation<RemoteBrowserResponse, any Error>?
        var heldInputFinished = false
        var frameGeneration: UInt64 = 1
        var inputFailure: (RemoteBrowserOperation, any Error)?
        var failedPageInput = false
        var supportsStalePointerCleanup = false
        let tab: RemoteBrowserTab
        init(agent: Bool, extensionWindow: Bool = false) {
            self.tab = RemoteBrowserTab(
                id: UUID(),
                sessionName: "s",
                title: "page",
                url: "about:blank",
                isLoading: false,
                isAgentOwned: agent,
                isExtensionWindow: extensionWindow ? true : nil
            )
        }

        func send(_ request: BrowseBrowser) async throws -> RemoteBrowserResponse {
            operations.append(request.operation)
            generations.append(request.generation)
            controlIDs.append(request.controlID)
            switch request.operation {
            case .takeControl: control = UUID()
                owned = true
                return .init(tab: tab, controlID: control)
            case .releaseControl:
                if request.controlID == control {
                    owned = false
                }
                return .init(tab: tab)
            case .frame:
                frameDimensions.append(request.frameMaxDimension)
                inFlight += 1
                maximumFrames = max(maximumFrames, inFlight)
                defer { inFlight -= 1 }
                try await Task.sleep(for: .milliseconds(2))
                return .init(
                    tab: tab,
                    frame: .init(jpeg: Data([1]), width: 1_200, height: 700, generation: frameGeneration),
                    controlID: owned && request.controlID == control ? control : nil
                )
            case .text("hold"):
                defer { heldInputFinished = true }
                return try await withCheckedThrowingContinuation { heldInput = $0 }
            default:
                if let failure = inputFailure, failure.0 == request.operation {
                    inputFailure = nil
                    frameGeneration += 1
                    if case ViewerRelayClientError.commandFailed("Page changed. Read a new frame before interacting.") = failure.1 {
                        failedPageInput = true
                    }
                    throw failure.1
                }
                return .init(tab: tab, controlID: owned ? control : nil)
            }
        }
    }

    func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for browser state")
    }

    @Test
    func coordinatesRespectLetterboxing() {
        let page = CGSize(width: 1_000, height: 500), view = CGSize(width: 400, height: 800)
        #expect(RemoteBrowserGeometry.imageRect(viewSize: view, pageSize: page) == CGRect(x: 0, y: 300, width: 400, height: 200))
        #expect(RemoteBrowserGeometry.pagePoint(CGPoint(x: 200, y: 400), viewSize: view, pageSize: page) == CGPoint(x: 500, y: 250))
        #expect(RemoteBrowserGeometry.pagePoint(CGPoint(x: 200, y: 100), viewSize: view, pageSize: page) == nil)
        #expect(RemoteBrowserGeometry.pagePoint(CGPoint(x: 450, y: 100), viewSize: view, pageSize: page, clamped: true) == CGPoint(x: 999, y: 0))
    }

    @Test
    func resolutionUsesLetterboxedPhysicalPixelsAndBuckets() {
        let page = CGSize(width: 1_000, height: 500)
        #expect(RemoteBrowserGeometry.frameMaxDimension(viewSize: CGSize(width: 400, height: 800), pageSize: page, displayScale: 3) == 1_280)
        #expect(RemoteBrowserGeometry.frameMaxDimension(viewSize: CGSize(width: 1_440, height: 900), pageSize: page, displayScale: 2) == 2_560)
        #expect(RemoteBrowserGeometry.frameMaxDimension(viewSize: CGSize(width: 401, height: 800), pageSize: page, displayScale: 3) == 1_280)
        #expect(RemoteBrowserGeometry.frameMaxDimension(viewSize: CGSize(width: 10, height: 10), pageSize: page, displayScale: 1) == 256)
        #expect(RemoteBrowserGeometry.frameMaxDimension(viewSize: .zero, pageSize: page, displayScale: 2) == nil)
        #expect(RemoteBrowserGeometry.frameMaxDimension(viewSize: CGSize(width: CGFloat.nan, height: 100), pageSize: page, displayScale: 2) == nil)
        #expect(RemoteBrowserGeometry.frameMaxDimension(viewSize: CGSize(width: 400, height: 800), pageSize: page, displayScale: .infinity) == nil)
    }

    @Test
    func changingResolutionDoesNotRestartWatchOrReleaseControl() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer { session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil }
        #expect(host.frameDimensions.first == .some(nil))
        let control = session.controlID
        session.frameMaxDimension = 1_280
        try await wait { host.frameDimensions.contains(1_280) }
        session.frameMaxDimension = 2_560
        try await wait { host.frameDimensions.contains(2_560) }
        session.submit(.text("after resize"))
        try await wait { host.operations.contains(.text("after resize")) }
        #expect(session.controlID == control)
        #expect(host.maximumFrames == 1)
        #expect(!host.operations.contains(.releaseControl))
        #expect(!host.operations.contains {
            if case .fit = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test
    func manualPageAutoControlAndAgentReadOnly() async throws {
        for agent in [true, false] {
            let host = Host(agent: agent)
            let session = RemoteBrowserSession(tab: host.tab, send: host.send)
            let task = Task { await session.watch() }
            try await wait { session.frame != nil && (agent || session.controlID != nil) }
            #expect((session.controlID != nil) == !agent)
            #expect(host.maximumFrames == 1)
            #expect(!host.operations.contains {
                if case .fit = $0 {
                    true
                } else {
                    false
                }
            })
            session.stop()
            task.cancel()
            await task.value
            try await wait { !host.owned }
            #expect(session.frame == nil)
        }
    }

    @Test
    func extensionWindowDoesNotAutomaticallyAcquirePageControl() async throws {
        let host = Host(agent: false, extensionWindow: true)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer { session.stop()
            task.cancel()
        }
        try await wait { host.operations.filter { $0 == .frame }.count >= 2 }
        #expect(session.frame != nil)
        #expect(session.controlID == nil)
        #expect(!host.operations.contains(.takeControl))
    }

    @Test
    func boundedOrderedInputAndNoReplayAfterStop() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        try await wait { session.controlID != nil }
        session.submit(.text("hold"))
        try await wait { host.heldInput != nil }
        for i in 1...100 {
            session.submit(.pointer(.init(.move, x: Double(i), y: 10, button: .left, buttons: 1)))
        }
        session.submit(.text("queued"))
        #expect(session.error == nil)
        session.stop()
        host.heldInput?.resume(returning: .init())
        host.heldInput = nil
        task.cancel()
        await task.value
        #expect(!host.operations.contains(.text("queued")))
        #expect(!host.operations.contains {
            if case .pointer = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test
    func inputUsesDisplayedFrameGeneration() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer { session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil }
        session.submit(.text("from old rendered image"), generation: 0)
        try await wait { host.operations.contains(.text("from old rendered image")) }
        let index = try #require(host.operations.firstIndex(of: .text("from old rendered image")))
        #expect(host.generations[index] == 0, "Do not upgrade input to a newer frame before it is displayed")
    }

    @Test
    func stalePageInputKeepsLeaseAndAcceptsNextFrame() async throws {
        let host = Host(agent: false)
        host.supportsStalePointerCleanup = true
        let session = RemoteBrowserSession(
            tab: host.tab,
            supportsStalePointerCleanup: { host.supportsStalePointerCleanup },
            send: host.send
        )
        let task = Task { await session.watch() }
        defer { session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil && session.frame?.generation == 1 }
        let control = try #require(session.controlID)
        host.inputFailure = (
            .pointer(.init(.up, x: 20, y: 30)),
            ViewerRelayClientError.commandFailed("Page changed. Read a new frame before interacting.")
        )

        session.submit(.pointer(.init(.up, x: 20, y: 30)))
        try await wait { host.failedPageInput && session.frame?.generation == 2 }

        #expect(session.controlID == control)
        #expect(session.error == nil)
        #expect(!host.operations.contains(.releaseControl))

        session.submit(.text("after navigation"))
        try await wait { host.operations.contains(.text("after navigation")) }
        let index = try #require(host.operations.firstIndex(of: .text("after navigation")))
        #expect(host.generations[index] == 2)
        #expect(session.controlID == control)
    }

    @Test
    func stalePageInputReadsCleanupCapabilityAfterReconnect() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(
            tab: host.tab,
            supportsStalePointerCleanup: { host.supportsStalePointerCleanup },
            send: host.send
        )
        let task = Task { await session.watch() }
        defer { session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil }
        let control = try #require(session.controlID)
        host.supportsStalePointerCleanup = true
        host.inputFailure = (
            .pointer(.init(.up, x: 20, y: 30)),
            ViewerRelayClientError.commandFailed("Page changed. Read a new frame before interacting.")
        )

        session.submit(.pointer(.init(.up, x: 20, y: 30)))
        try await wait { host.failedPageInput }

        #expect(session.controlID == control)
        #expect(!host.operations.contains(.releaseControl))
    }

    @Test
    func stalePageInputReleasesControlOnLegacyHost() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer { session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil }
        host.inputFailure = (
            .pointer(.init(.up, x: 20, y: 30)),
            ViewerRelayClientError.commandFailed("Page changed. Read a new frame before interacting.")
        )

        session.submit(.pointer(.init(.up, x: 20, y: 30)))
        try await wait {
            host.failedPageInput && session.controlID == nil && host.operations.contains(.releaseControl)
        }

        #expect(session.error != nil)
        #expect(!host.owned)
    }

    @Test
    func fatalInputFailureStillReleasesControl() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer { session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil }
        host.inputFailure = (.text("fail"), URLError(.timedOut))

        session.submit(.text("fail"))
        try await wait { session.controlID == nil && host.operations.contains(.releaseControl) }

        #expect(session.error != nil)
    }

    @Test(arguments: [false, true])
    func leaseLossDropsOldInputAcrossRetake(lateFailure: Bool) async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer {
            host.heldInput?.resume(throwing: CancellationError())
            host.heldInput = nil
            session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil }
        let oldControl = try #require(session.controlID)
        session.submit(.text("hold"))
        try await wait { host.heldInput != nil }
        session.submit(.text("stale text"))
        session.submit(.key(.init("Enter", keyCode: 13)))
        session.submit(.pointer(.init(.move, x: 20, y: 30)))

        host.owned = false
        try await wait { session.controlID == nil }
        await session.takeControl()
        let newControl = try #require(session.controlID)
        #expect(newControl != oldControl)
        session.submit(.text("fresh"))
        try await wait { host.operations.contains(.text("fresh")) }

        // The old transport callback can complete even after its Task is cancelled.
        if lateFailure {
            host.heldInput?.resume(throwing: URLError(.timedOut))
        } else {
            host.heldInput?.resume(returning: .init(controlID: oldControl))
        }
        host.heldInput = nil
        try await wait { host.heldInputFinished }
        session.submit(.text("after late response"))
        try await wait { host.operations.contains(.text("after late response")) }
        #expect(!host.operations.contains(.text("stale text")))
        #expect(!host.operations.contains(.key(.init("Enter", keyCode: 13))))
        #expect(!host.operations.contains {
            if case .pointer = $0 {
                true
            } else {
                false
            }
        })
        #expect(session.controlID == newControl)
        #expect(session.error == nil)
        for text in ["fresh", "after late response"] {
            let index = try #require(host.operations.firstIndex(of: .text(text)))
            #expect(host.controlIDs[index] == newControl)
        }
    }

    @Test
    func leaseLossDropsOldInputWithoutRetake() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer {
            host.heldInput?.resume(throwing: CancellationError())
            host.heldInput = nil
            session.stop()
            task.cancel()
        }
        try await wait { session.controlID != nil }
        session.submit(.text("hold"))
        try await wait { host.heldInput != nil }
        session.submit(.text("stale"))
        host.owned = false
        try await wait { session.controlID == nil }
        host.heldInput?.resume(returning: .init())
        host.heldInput = nil
        try await wait { host.heldInputFinished }
        #expect(!host.operations.contains(.text("stale")))
        #expect(session.controlID == nil)
        #expect(session.frame != nil, "Losing control must not stop read-only viewing")
    }
}
