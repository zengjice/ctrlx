#if os(macOS) || os(iOS)
import AVFoundation
import CtrlxNetworking
import Dependencies
import Foundation
import Observation
import UniformTypeIdentifiers
import os

@MainActor @Observable
final class FileBrowserVideoPlayback {
    private(set) var player: AVPlayer?
    private(set) var isBuffering = false
    private(set) var isMuted: Bool
    private(set) var error: String?
    @ObservationIgnored private let startsMuted: Bool
    @ObservationIgnored @Dependency(FileBrowserVideoAudioClient.self) private var audio
    @ObservationIgnored private var ownsAudioSession = false
    @ObservationIgnored private let audioOwnerID = UUID()
    @ObservationIgnored private var loader: FileBrowserVideoResourceLoader?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var sceneIsActive = true
    @ObservationIgnored private var preparationID = UUID()
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "VideoPlayback")

    nonisolated static var defaultMuted: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    init(startsMuted: Bool = FileBrowserVideoPlayback.defaultMuted) {
        self.startsMuted = startsMuted
        isMuted = startsMuted
    }

    func prepare(path: String, source: FileBrowserSource) async throws {
        try Task.checkCancellation()
        guard sceneIsActive else { throw CancellationError() }
        let preparationID = UUID()
        self.preparationID = preparationID
        if let reason = source.unavailableReason ?? source.downloadUnavailableReason { throw FileBrowserError.message(reason) }
        guard case let .info(info) = try await source.request(.info(path: path)) else {
            throw FileBrowserError.message("Missing video information.")
        }
        try Task.checkCancellation()
        // A late response must not revive preparation stopped while away from the foreground.
        guard sceneIsActive, self.preparationID == preparationID else { throw CancellationError() }
        let reader = try FileBrowserVideoReader(info: info, source: source)
        let loader = try FileBrowserVideoResourceLoader(reader: reader) { [weak self] message in
            self?.error = message
            self?.player?.pause()
            self?.releaseAudio()
        }
        let asset = loader.makeAsset()
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        let player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        self.loader = loader
        self.player = player
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateState() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateState() }
            },
            player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateState() }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateState() }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateState() }
        }
    }

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        guard !active else { return }
        if player == nil { stop() }
        else {
            player?.pause()
            loader?.setSuspended(true)
            releaseAudio()
        }
    }

    func play() {
        guard sceneIsActive, let player else { return }
        if !isMuted, !activateAudio() { return }
        player.play()
    }

    func toggleSound() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        if !muted, sceneIsActive, let player, player.timeControlStatus != .paused,
           !activateAudio() { return }
        isMuted = muted
        player?.isMuted = muted
    }

    private func updateState() {
        guard let player else { return }
        if isMuted != player.isMuted { isMuted = player.isMuted }
        if player.currentItem?.status == .failed {
            if error == nil { error = player.currentItem?.error?.localizedDescription ?? "This video cannot be played. Use Download and Open." }
            player.pause()
            releaseAudio()
            loader?.stop()
            return
        }
        // Native AVKit controls resume the AVPlayer directly, not through play().
        if sceneIsActive, player.timeControlStatus != .paused {
            if !isMuted, !activateAudio() {
                isMuted = true
                player.isMuted = true
                return
            }
        } else {
            if !sceneIsActive { player.pause() }
            releaseAudio()
        }
        let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isBuffering != buffering { isBuffering = buffering }
        let now = player.currentTime()
        let buffered = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue).first { CMTimeRangeContainsTime($0, time: now) }
        let ahead = buffered.map { CMTimeGetSeconds(CMTimeSubtract(CMTimeRangeGetEnd($0), now)) } ?? 0
        // preferredForwardBufferDuration alone is only a hint. Also stop feeding
        // long resource requests once the native player has enough buffered time.
        loader?.setSuspended(!sceneIsActive || player.timeControlStatus == .paused || (!buffering && ahead >= 3))
    }

    private func activateAudio() -> Bool {
        guard !ownsAudioSession else { return true }
        do {
            try audio.acquire(audioOwnerID)
            ownsAudioSession = true
            return true
        } catch {
            self.error = "Could not start video audio: \(error.localizedDescription)"
            player?.pause()
            loader?.setSuspended(true)
            return false
        }
    }

    private func releaseAudio() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        do { try audio.release(audioOwnerID) }
        catch { Self.logger.error("Could not release video audio: \(error)") }
    }

    func stop() {
        preparationID = UUID()
        observations.removeAll()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        releaseAudio()
        player?.replaceCurrentItem(with: nil)
        loader?.stop()
        loader = nil
        player = nil
        isBuffering = false
        isMuted = startsMuted
    }
}

/// AVFoundation delivers its legacy delegate callbacks on the explicitly chosen
/// main queue. All scheduling uses Swift tasks; the queue is only the SDK bridge.
@MainActor
final class FileBrowserVideoResourceLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let url: URL
    private let reader: FileBrowserVideoReader
    private let onFailure: @MainActor (String) -> Void
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var worker: Task<Void, Never>?
    private var activeRequest: AVAssetResourceLoadingRequest?
    private var suspended = false
    private var stopped = false

    init(reader: FileBrowserVideoReader, onFailure: @escaping @MainActor (String) -> Void) throws {
        self.reader = reader
        self.onFailure = onFailure
        var components = URLComponents()
        components.scheme = "ctrlx-video"
        components.host = "preview"
        components.path = "/\(UUID())/\(reader.info.name)"
        guard let url = components.url else { throw FileBrowserError.message("Invalid video preview URL.") }
        self.url = url
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url == url else { return false }
        guard !stopped, requests.count < 16 else {
            request.finishLoading(with: FileBrowserError.message("Video preview is closed or has too many pending reads."))
            return true
        }
        if let content = request.contentInformationRequest {
            let type = (reader.info.path as NSString).pathExtension.lowercased() == "mov" ? UTType.quickTimeMovie : UTType.mpeg4Movie
            if let allowed = content.allowedContentTypes, !allowed.isEmpty, !allowed.contains(type.identifier) {
                request.finishLoading(with: FileBrowserError.message("The system player does not support this video type."))
                return true
            }
            content.contentType = type.identifier
            content.contentLength = Int64(reader.info.size)
            content.isByteRangeAccessSupported = true
        }
        guard request.dataRequest != nil else { request.finishLoading(); return true }
        requests.append(request)
        schedule()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === request }
        if activeRequest === request { worker?.cancel() }
    }

    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        if suspended { worker?.cancel() }
        else { schedule() }
    }

    func stop(with error: any Error = CancellationError()) {
        stopped = true
        worker?.cancel()
        for request in requests where !request.isCancelled && !request.isFinished {
            request.finishLoading(with: error)
        }
        requests.removeAll()
        reader.clear()
    }

    private func schedule() {
        guard worker == nil, !stopped, !suspended, !requests.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                activeRequest = nil
                worker = nil
                schedule()
            }
            do {
                while !requests.isEmpty, !stopped, !suspended {
                    try Task.checkCancellation()
                    let request = requests[0]
                    if request.isCancelled || request.isFinished { requests.removeFirst(); continue }
                    guard let dataRequest = request.dataRequest else { requests.removeFirst(); request.finishLoading(); continue }
                    let range = try FileBrowserVideoRange(offset: dataRequest.requestedOffset,
                        length: dataRequest.requestedLength, toEnd: dataRequest.requestsAllDataToEndOfResource, size: reader.info.size)
                    let offset = max(range.start, Int(dataRequest.currentOffset))
                    guard offset <= range.end else { throw FileBrowserError.message("Invalid video byte range.") }
                    if offset == range.end { requests.removeFirst(); request.finishLoading(); continue }
                    activeRequest = request
                    let data = try await reader.read(offset: offset, length: range.end - offset)
                    try Task.checkCancellation()
                    guard !request.isCancelled, !request.isFinished, !stopped else { continue }
                    dataRequest.respond(with: data)
                    requests.removeAll { $0 === request }
                    if offset + data.count == range.end { request.finishLoading() }
                    else { requests.append(request) }
                    // Let keyboard/transport work run between blocks, including cache hits.
                    await Task.yield()
                }
            } catch is CancellationError { return }
            catch {
                stop(with: error)
                onFailure(error.localizedDescription)
            }
        }
    }
}
#endif
