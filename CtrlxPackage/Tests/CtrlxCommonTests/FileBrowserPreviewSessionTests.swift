#if os(macOS)
    import AppKit
    import AVFoundation
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct FileBrowserPreviewSessionTests {
        @Test("Only two hidden previews survive, with least-recently-used eviction")
        func boundedHiddenPreviews() {
            _ = NSApplication.shared
            let cache = FileBrowserPreviewCache(limit: 2)
            let sessions = (0..<3).map { _ in FileBrowserPreviewSession(cache: cache) }
            defer { sessions.forEach { $0.close() } }
            let parents = sessions.map { session in mount(session) }
            let owners = sessions.map { $0.owner }
            sessions[0].position.scroll = .init(x: 12, y: 340)
            for i in 0..<2 {
                hide(sessions[i], parent: parents[i], owner: owners[i])
            }
            #expect(sessions[0].hasContent && sessions[1].hasContent)
            let reused = UUID()
            sessions[0].mount(in: parents[0], owner: reused, environment: environment) { AnyView(Text("Must reuse")) }
            hide(sessions[0], parent: parents[0], owner: reused)
            hide(sessions[2], parent: parents[2], owner: owners[2])
            #expect(sessions[0].hasContent)
            #expect(!sessions[1].hasContent)
            #expect(sessions[2].hasContent)
            #expect(sessions[0].position.scroll == .init(x: 12, y: 340))
            cache.releaseHidden()
            #expect(sessions.allSatisfy { !$0.hasContent })
            #expect(sessions[0].position.scroll.y == 340)
        }

        @Test("A retiring mount cannot suspend a preview moved to another window")
        func mountOwnership() throws {
            _ = NSApplication.shared
            let cache = FileBrowserPreviewCache(limit: 0)
            let session = FileBrowserPreviewSession(cache: cache)
            defer { session.close() }
            let old = mount(session)
            let owner = try #require(session.owner)
            let native = try #require(old.subviews.first)
            let new = NSView(frame: old.bounds)
            let newOwner = UUID()
            session.mount(in: new, owner: newOwner, environment: environment) { AnyView(Text("Must reuse")) }
            session.hide(owner: owner)
            cache.releaseHidden()
            #expect(session.owner == newOwner)
            #expect(session.hasContent)
            #expect(new.subviews.first === native)
            #expect(old.subviews.isEmpty)
            session.hide(owner: newOwner)
            #expect(!session.hasContent)
        }

        @Test("Connection replacement preserves a checkpoint but file, revision and refresh changes reset it")
        func identityAndRevision() {
            let session = FileBrowserPreviewSession(cache: .init())
            defer { session.close() }
            let key = FileBrowserPreviewSession.Key(sourceID: "host-a", connectionID: UUID(), path: "/work/readme.md", refresh: 0)
            session.configure(key)
            session.acceptRevision("v1")
            session.position.scroll.y = 700
            session.position.videoWasOpened = true
            session.position.videoSeconds = 42
            session.configure(.init(sourceID: key.sourceID, connectionID: UUID(), path: key.path, refresh: 0))
            session.acceptRevision("v1")
            #expect(session.position.scroll.y == 700)
            #expect(session.position.videoSeconds == 42)
            session.acceptRevision("v2")
            #expect(session.position.scroll == .zero)
            #expect(!session.position.videoWasOpened)
            session.position.scroll.y = 88
            session.configure(.init(sourceID: key.sourceID, connectionID: key.connectionID, path: key.path, refresh: 1))
            #expect(session.position.scroll == .zero)
            session.position.scroll.y = 99
            session.configure(.init(sourceID: "host-b", connectionID: key.connectionID, path: key.path, refresh: 1))
            #expect(session.position.scroll == .zero)
        }

        @Test("Closing a Files model releases its hidden native preview and player")
        func modelCloseReleasesResources() throws {
            _ = NSApplication.shared
            weak var weakTab: FileBrowserTab?
            weak var session: FileBrowserPreviewSession?
            weak var native: NSView?
            var player: AVPlayer?
            try autoreleasepool {
                var tab: FileBrowserTab? = FileBrowserTab(path: "/work")
                weakTab = tab
                session = tab?.previewSession
                let parent = try mount(#require(session))
                native = parent.subviews.first
                player = try #require(session).player(url: URL(fileURLWithPath: "/fixture/movie.mp4"))
                try hide(#require(session), parent: parent, owner: session?.owner)
                tab = nil
            }
            #expect(weakTab == nil)
            #expect(session == nil)
            #expect(native == nil)
            #expect(player?.currentItem == nil)
        }

        @Test("Reclaiming a preview releases its screenshot provider and cached frames")
        func evictionReleasesCapture() {
            let session = FileBrowserPreviewSession(cache: .init())
            var payload: NSObject? = NSObject()
            weak var retainedPayload = payload
            session.capture.bind(owner: UUID()) { [payload] in
                throw FileBrowserError.message(String(describing: payload))
            }
            payload = nil
            #expect(retainedPayload != nil)
            session.evict()
            #expect(retainedPayload == nil)
        }

        private var environment: EnvironmentValues {
            var environment = EnvironmentValues()
            environment.scenePhase = .active
            return environment
        }

        private func mount(_ session: FileBrowserPreviewSession) -> NSView {
            let parent = NSView(frame: .init(x: 0, y: 0, width: 300, height: 200))
            session.mount(in: parent, owner: UUID(), environment: environment) { AnyView(Text("Preview")) }
            return parent
        }

        private func hide(_ session: FileBrowserPreviewSession, parent: NSView, owner: UUID?) {
            guard let owner else { Issue.record("Missing mount owner")
                return
            }
            session.hide(owner: owner)
            for child in parent.subviews {
                child.removeFromSuperview()
            }
        }
    }
#endif
