#if os(macOS) || os(iOS)
    import AVKit
    import Observation
    import SwiftUI

    /// One current document per Files tab. Checkpoints contain no file data or history.
    @MainActor
    final class FileBrowserPreviewPosition {
        var acceptsUpdates = false
        var revision: String?
        var scroll = CGPoint.zero
        var pdfPage = 0
        var pdfPoint: CGPoint?
        var videoSeconds = 0.0
        var videoWasOpened = false
        var videoMuted = FileBrowserVideoPlayback.defaultMuted
        var capturePDF: (() -> Void)?

        func validate(revision: String) {
            if let previous = self.revision, previous != revision {
                scroll = .zero
                pdfPage = 0
                pdfPoint = nil
                videoSeconds = 0
                videoWasOpened = false
                videoMuted = FileBrowserVideoPlayback.defaultMuted
            }
            self.revision = revision
        }
    }

    @MainActor @Observable
    final class FileBrowserPreviewActions {
        struct Link {
            let id = UUID()
            let url: URL
            let documentPath: String
        }

        var link: Link?
    }

    extension EnvironmentValues {
        @Entry var fileBrowserPreviewIsActive = true
    }

    @MainActor @Observable
    final private class FileBrowserPreviewEnvironment {
        var values: EnvironmentValues
        init(_ values: EnvironmentValues) {
            self.values = values
        }
    }

    @MainActor
    private struct FileBrowserRetainedContent: View {
        let content: AnyView
        let environment: FileBrowserPreviewEnvironment
        var body: some View {
            content.environment(\.self, environment.values)
        }
    }

    /// Owns the native preview independently of the disposable workbench view.
    /// Its hosted content must not capture the owning FileBrowserTab or this session.
    @MainActor @Observable
    final class FileBrowserPreviewSession {
        struct Key: Equatable {
            let sourceID: String
            let connectionID: UUID?
            let path: String?
            let refresh: Int
        }

        let id = UUID()
        let capture = FilePreviewCapture()
        let actions = FileBrowserPreviewActions()
        let playback = FileBrowserVideoPlayback()
        private(set) var generation = UUID()
        private(set) var isReady = false
        @ObservationIgnored private(set) var key: Key?
        @ObservationIgnored private(set) var revision: String?
        @ObservationIgnored private(set) var position = FileBrowserPreviewPosition()
        @ObservationIgnored private(set) var owner: UUID?
        @ObservationIgnored var onEvict: (() -> Void)?
        @ObservationIgnored private var environment: EnvironmentValues?
        @ObservationIgnored private var renderEnvironment: FileBrowserPreviewEnvironment?
        @ObservationIgnored private var localPlayer: AVPlayer?
        @ObservationIgnored private var localSeekPending = false
        @ObservationIgnored var retentionLease: UUID?
        @ObservationIgnored private let cache: FileBrowserPreviewCache
        #if os(macOS)
            @ObservationIgnored private var host: NSHostingView<FileBrowserRetainedContent>?
        #else
            @ObservationIgnored private var host: UIHostingController<FileBrowserRetainedContent>?
        #endif

        init(cache: FileBrowserPreviewCache = .shared) {
            self.cache = cache
        }

        isolated deinit {
            localPlayer?.pause()
            localPlayer?.replaceCurrentItem(with: nil)
            playback.stop()
        }

        var hasContent: Bool {
            host != nil
        }

        func configure(_ key: Key) {
            guard self.key != key else { return }
            let keepsPosition = self.key.map { $0.sourceID == key.sourceID && $0.path == key.path && $0.refresh == key.refresh } == true
            evict()
            if !keepsPosition {
                position = FileBrowserPreviewPosition()
                revision = nil
            }
            self.key = key
        }

        func acceptRevision(_ revision: String) {
            if let previous = self.revision, previous != revision {
                evict()
                position = FileBrowserPreviewPosition()
            }
            self.revision = revision
            position.validate(revision: revision)
            isReady = true
        }

        func player(url: URL) -> AVPlayer {
            if let localPlayer {
                return localPlayer
            }
            let player = AVPlayer(url: url)
            player.isMuted = position.videoMuted
            if position.videoSeconds > 0 {
                localSeekPending = true
                player.seek(to: CMTime(seconds: position.videoSeconds, preferredTimescale: 600)) { [weak self, weak player] _ in
                    Task { @MainActor in
                        guard let self, self.localPlayer === player else { return }
                        self.localSeekPending = false
                    }
                }
            }
            position.videoWasOpened = true
            localPlayer = player
            return player
        }

        func savePosition() {
            guard owner != nil else { return }
            position.capturePDF?()
            if let player = localPlayer ?? playback.player {
                let seconds = player.currentTime().seconds
                let seeking = localPlayer != nil ? localSeekPending : playback.restorationSeconds != nil
                if !seeking, seconds.isFinite, seconds >= 0 {
                    position.videoSeconds = seconds
                }
                position.videoWasOpened = true
                position.videoMuted = player.isMuted
            }
        }

        func show(owner: UUID, environment: EnvironmentValues) {
            self.owner = owner
            position.acceptsUpdates = true
            cache.remove(self)
            playback.setSceneActive(environment.scenePhase == .active)
            updateEnvironment(environment, active: true)
        }

        func hide(owner: UUID) {
            guard self.owner == owner else { return }
            savePosition()
            position.acceptsUpdates = false
            self.owner = nil
            localPlayer?.pause()
            playback.setSceneActive(false)
            if let environment {
                updateEnvironment(environment, active: false)
            }
            if hasContent {
                cache.retainHidden(self)
            }
        }

        func evict() {
            savePosition()
            position.acceptsUpdates = false
            owner = nil
            cache.remove(self)
            localPlayer?.pause()
            localPlayer?.replaceCurrentItem(with: nil)
            localPlayer = nil
            localSeekPending = false
            playback.stop()
            capture.reset()
            if let environment {
                updateEnvironment(environment, active: false)
            }
            #if os(macOS)
                host?.removeFromSuperview()
            #else
                host?.willMove(toParent: nil)
                host?.view.removeFromSuperview()
                host?.removeFromParent()
            #endif
            host = nil
            environment = nil
            renderEnvironment = nil
            position.capturePDF = nil
            actions.link = nil
            isReady = false
            generation = UUID()
            onEvict?()
        }

        func close() {
            evict()
            position = FileBrowserPreviewPosition()
            key = nil
            revision = nil
        }

        private func updateEnvironment(_ environment: EnvironmentValues, active: Bool) {
            // Retained content must not retain workbench action closures or app stores.
            var preview = EnvironmentValues()
            preview.colorScheme = environment.colorScheme
            preview.dynamicTypeSize = environment.dynamicTypeSize
            preview.locale = environment.locale
            preview.layoutDirection = environment.layoutDirection
            preview.displayScale = environment.displayScale
            preview.font = environment.font
            preview.isEnabled = environment.isEnabled
            preview.scenePhase = environment.scenePhase
            preview.fileBrowserPreviewIsActive = active
            self.environment = preview
            renderEnvironment?.values = preview
        }

        #if os(macOS)
            func mount(in parent: NSView, owner: UUID, environment: EnvironmentValues, content: () -> AnyView) {
                if host == nil {
                    updateEnvironment(environment, active: true)
                    let content = content()
                    let environment = FileBrowserPreviewEnvironment(self.environment ?? EnvironmentValues())
                    renderEnvironment = environment
                    let host = NSHostingView(rootView: FileBrowserRetainedContent(content: content, environment: environment))
                    host.sizingOptions = []
                    self.host = host
                }
                show(owner: owner, environment: environment)
                guard let host, host.superview !== parent else { return }
                host.frame = parent.bounds
                host.autoresizingMask = [.width, .height]
                parent.addSubview(host)
            }
        #else
            func mount(in parent: UIViewController, owner: UUID, environment: EnvironmentValues, content: () -> AnyView) {
                if host == nil {
                    updateEnvironment(environment, active: true)
                    let content = content()
                    let environment = FileBrowserPreviewEnvironment(self.environment ?? EnvironmentValues())
                    renderEnvironment = environment
                    host = UIHostingController(rootView: FileBrowserRetainedContent(content: content, environment: environment))
                }
                show(owner: owner, environment: environment)
                guard let host, host.parent !== parent else { return }
                host.willMove(toParent: nil)
                host.removeFromParent()
                parent.addChild(host)
                host.view.frame = parent.view.bounds
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                parent.view.addSubview(host.view)
                host.didMove(toParent: parent)
            }
        #endif
    }

    /// Bound the number of hidden native previews; NSCache also permits pressure eviction.
    @MainActor
    final class FileBrowserPreviewCache: NSObject, NSCacheDelegate {
        static let shared = FileBrowserPreviewCache()
        private let limit: Int
        private let pressureCache = NSCache<NSUUID, Entry>()
        private var hidden: [WeakSession] = []

        private struct WeakSession {
            weak var value: FileBrowserPreviewSession?
        }

        @MainActor
        final private class Entry: NSObject {
            weak var session: FileBrowserPreviewSession?
            let generation: UUID
            let lease = UUID()
            init(_ session: FileBrowserPreviewSession) {
                self.session = session
                self.generation = session.generation
            }
        }

        init(limit: Int = 2) {
            self.limit = limit
            super.init()
            pressureCache.delegate = self
        }

        func retainHidden(_ session: FileBrowserPreviewSession) {
            remove(session)
            hidden.append(.init(value: session))
            let entry = Entry(session)
            session.retentionLease = entry.lease
            pressureCache.setObject(entry, forKey: session.id as NSUUID)
            while hidden.count > limit {
                let oldest = hidden.removeFirst().value
                if oldest?.owner == nil {
                    oldest?.evict()
                }
            }
        }

        func remove(_ session: FileBrowserPreviewSession) {
            session.retentionLease = nil
            hidden.removeAll { $0.value == nil || $0.value === session }
            pressureCache.removeObject(forKey: session.id as NSUUID)
        }

        func releaseHidden() {
            let sessions = hidden.compactMap(\.value)
            hidden = []
            pressureCache.removeAllObjects()
            for session in sessions where session.owner == nil {
                session.evict()
            }
        }

        nonisolated func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
            guard let entry = object as? Entry else { return }
            Task { @MainActor in
                guard
                    let session = entry.session, session.owner == nil, session.generation == entry.generation,
                    session.retentionLease == entry.lease else { return }
                session.evict()
            }
        }
    }
#endif
