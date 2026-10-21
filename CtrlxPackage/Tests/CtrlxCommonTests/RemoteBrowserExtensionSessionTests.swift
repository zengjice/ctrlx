import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Remote extension surface") @MainActor
struct RemoteBrowserExtensionSessionTests {
    @MainActor
    final class Host {
        let anchor = RemoteBrowserTab(id: UUID(), sessionName: "source", title: "Source", url: "https://example.com", isLoading: false, isAgentOwned: false)
        lazy var page = RemoteBrowserTab(id: UUID(), sessionName: anchor.sessionName, title: "Chrome", url: anchor.url, isLoading: false, isAgentOwned: false, isExtensionWindow: true)
        var requests: [BrowseBrowser] = []
        var control = UUID()
        var owned = false
        var showingPage = false
        var showingOptions = false
        var holdFrame = false
        var heldFrame: CheckedContinuation<RemoteBrowserResponse, any Error>?

        func send(_ request: BrowseBrowser) async throws -> RemoteBrowserResponse {
            requests.append(request)
            guard case let .extensions(operation) = request.operation else {
                Issue.record("Extension surface escaped into ordinary page commands")
                throw ViewerRelayClientError.commandFailed("Wrong command scope")
            }
            switch operation {
            case .acquire:
                control = UUID()
                owned = true
                return .init(tab: anchor, controlID: control)
            case .release:
                if request.controlID == control {
                    owned = false
                }
                return .init(tab: anchor)
            case .frame:
                if holdFrame {
                    holdFrame = false
                    return try await withCheckedThrowingContinuation { heldFrame = $0 }
                }
                guard owned else { return .init(tab: anchor) }
                return .init(
                    tab: showingPage ? page : anchor,
                    frame: .init(jpeg: Data([1]), width: 1_200, height: 800, generation: 9),
                    controlID: control,
                    extensions: .init(surface: showingOptions ? .options : showingPage ? .page : .manager)
                )
            case .openOptions:
                showingOptions = true
                return .init(tab: anchor, controlID: control, extensions: .init(surface: .options))
            case .openWindow,
                 .showSurface(.page):
                showingPage = true
                return .init(tab: page, controlID: control, extensions: .init(surface: .page))
            case .showSurface(.manager):
                return .init(tab: anchor, controlID: control, extensions: .init(surface: .manager))
            default: return .init(tab: anchor, controlID: owned ? control : nil, extensions: .init(entries: []))
            }
        }
    }

    @Test
    func requiresExplicitGrantAndKeepsSourceWhenNativePageChanges() async throws {
        let host = Host()
        let session = RemoteBrowserSession(tab: host.anchor, managesExtensions: true, send: host.send)
        let watch = Task { await session.watch() }
        defer { watch.cancel()
            session.stop()
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(host.requests.isEmpty)
        #expect(session.controlID == nil)
        await session.takeControl()
        try await RemoteBrowserSessionTests().wait { session.frame != nil }
        #expect(session.controlID == host.control)
        _ = try await session.performExtension(.openWindow)
        try await RemoteBrowserSessionTests().wait { session.tab.id == host.page.id && session.frame != nil }
        session.submit(.text("中文"), generation: 9)
        try await RemoteBrowserSessionTests().wait { host.requests.contains { $0.operation == .extensions(.text("中文")) } }
        _ = try await session.performExtension(.list)
        session.releaseControl()
        try await RemoteBrowserSessionTests().wait { !host.owned }
        #expect(host.requests.allSatisfy { $0.tabID == host.anchor.id })
        #expect(Set(host.requests.map(\.surfaceID)).count == 1)
        #expect(session.frame == nil)
    }

    @Test
    func openingSettingsDiscardsPreviousWindowFrames() async throws {
        let host = Host()
        let session = RemoteBrowserSession(tab: host.anchor, managesExtensions: true, send: host.send)
        let watch = Task { await session.watch() }
        defer { watch.cancel()
            session.stop()
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        await session.takeControl()
        try await RemoteBrowserSessionTests().wait { session.frame != nil }
        host.holdFrame = true
        try await RemoteBrowserSessionTests().wait { host.heldFrame != nil }
        let held = try #require(host.heldFrame)
        _ = try await session.performExtension(.openOptions("fixture"))
        #expect(session.frame == nil)
        #expect(session.extensionSurface == .options)
        // Prevent a fresh capture from hiding an incorrectly accepted old frame.
        host.heldFrame = nil
        host.holdFrame = true
        held.resume(returning: .init(tab: host.anchor, frame: .init(jpeg: Data([2]), width: 500, height: 500, generation: 8), controlID: host.control, extensions: .init(surface: .manager)))
        try await RemoteBrowserSessionTests().wait { host.heldFrame != nil }
        #expect(session.frame == nil)
        #expect(session.extensionSurface == .options)
        host.heldFrame?.resume(returning: .init(tab: host.anchor, frame: .init(jpeg: Data([3]), width: 800, height: 600, generation: 10), controlID: host.control, extensions: .init(surface: .options)))
        host.heldFrame = nil
        try await RemoteBrowserSessionTests().wait { session.frame != nil }
        #expect(session.extensionSurface == .options)
    }

    @Test
    func hostTakebackClearsFrameAndAllowsNewExplicitGrant() async throws {
        let host = Host()
        let session = RemoteBrowserSession(tab: host.anchor, managesExtensions: true, send: host.send)
        let watch = Task { await session.watch() }
        defer { watch.cancel()
            session.stop()
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        await session.takeControl()
        try await RemoteBrowserSessionTests().wait { session.frame != nil }
        let first = session.controlID
        host.owned = false
        try await RemoteBrowserSessionTests().wait { session.controlID == nil }
        #expect(session.frame == nil)
        #expect(session.error != nil)
        await session.takeControl()
        try await RemoteBrowserSessionTests().wait { session.frame != nil }
        #expect(session.controlID != first)
        #expect(session.error == nil)
    }

    @Test
    func lateRevokedFrameCannotReleaseNewGrant() async throws {
        let host = Host()
        let session = RemoteBrowserSession(tab: host.anchor, managesExtensions: true, send: host.send)
        let watch = Task { await session.watch() }
        defer { watch.cancel()
            session.stop()
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        await session.takeControl()
        try await RemoteBrowserSessionTests().wait { session.frame != nil }
        host.holdFrame = true
        try await RemoteBrowserSessionTests().wait { host.heldFrame != nil }
        let held = try #require(host.heldFrame)
        session.releaseControl()
        try await RemoteBrowserSessionTests().wait { !host.owned }
        await session.takeControl()
        let next = try #require(session.controlID)
        held.resume(returning: .init(tab: host.anchor))
        host.heldFrame = nil
        try await RemoteBrowserSessionTests().wait { session.frame != nil }
        #expect(session.controlID == next)
        #expect(host.owned)
        #expect(session.error == nil)
    }
}
