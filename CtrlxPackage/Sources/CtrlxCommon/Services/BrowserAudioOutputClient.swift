#if os(macOS) || os(iOS)
    import AVFoundation
    import CtrlxNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging
    import os

    @DependencyClient
    struct BrowserAudioOutputClient: Sendable {
        var start: @MainActor @Sendable (_ owner: UUID, _ onStop: @escaping @MainActor @Sendable (String?) -> Void) throws -> Void
        var receive: @MainActor @Sendable (_ owner: UUID, _ message: RemoteBrowserAudio) -> Void
        var stop: @MainActor @Sendable (_ owner: UUID) -> Void
    }

    extension BrowserAudioOutputClient: DependencyKey {
        static let liveValue = Self(
            start: { try BrowserAudioOutput.shared.start($0, onStop: $1) },
            receive: { BrowserAudioOutput.shared.receive($0, message: $1) },
            stop: { BrowserAudioOutput.shared.stop($0) }
        )
        static let testValue = Self(start: { _, _ in }, receive: { _, _ in }, stop: { _ in })
    }

    /// Shared across Hosts and windows: only the most recently controlled page speaks.
    @MainActor
    final class BrowserAudioOutput {
        static let shared = BrowserAudioOutput()
        private var owner: UUID?
        private var onStop: (@MainActor @Sendable (String?) -> Void)?
        private var engine: AVAudioEngine?
        private var player: AVAudioPlayerNode?
        private var continuation: AsyncStream<RemoteBrowserAudio>.Continuation?
        private var task: Task<Void, Never>?
        private var observers: [NSObjectProtocol] = []
        private var audioSessionActive = false
        var queuedFrames: Int {
            queuedFrameCount.withLock { $0 }
        }

        private var queuedFrameCount = OSAllocatedUnfairLock(initialState: 0)
        private var playerEpoch = UUID()
        private(set) var pendingFrames = 0
        private(set) var droppedFrames = 0
        private(set) var underruns = 0
        private(set) var resynchronizations = 0
        private(set) var isPlaying = false
        private var lastSequence: UInt64 = 0
        private var prebufferTask: Task<Void, Never>?
        private var playbackEpoch = UUID()
        private let makeEngine: () -> AVAudioEngine
        private let makePlayer: () -> AVAudioPlayerNode
        @Dependency(FileBrowserVideoAudioClient.self) private var audioSession

        init(
            makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
            makePlayer: @escaping () -> AVAudioPlayerNode = { AVAudioPlayerNode() }
        ) {
            self.makeEngine = makeEngine
            self.makePlayer = makePlayer
        }

        func start(_ id: UUID, onStop: @escaping @MainActor @Sendable (String?) -> Void) throws {
            if let previous = owner {
                let callback = self.onStop
                stop(previous)
                callback?(nil)
            }
            owner = id
            self.onStop = onStop
            droppedFrames = 0
            underruns = 0
            resynchronizations = 0
            lastSequence = 0
            startDecoder(id)
        }

        private func startDecoder(_ id: UUID) {
            // Admission is bounded in audio frames, including in-flight decode,
            // rather than message count (batches vary from 1 to 8 AAC packets).
            let (stream, continuation) = AsyncStream<RemoteBrowserAudio>.makeStream()
            let epoch = playbackEpoch
            self.continuation = continuation
            task = Task { [weak self] in
                var decoder = BrowserAudioCodec()
                var sequence: UInt64?
                for await message in stream {
                    do {
                        // Reset AAC overlap only at the missing batch, after
                        // decoding earlier batches. Already scheduled PCM is valid.
                        if let previous = sequence, message.sequence != previous + 1 {
                            decoder = BrowserAudioCodec()
                        }
                        sequence = message.sequence
                        let pcm = try await decoder.decode(message.packets, cookie: message.magicCookie)
                        guard !Task.isCancelled, let self, self.owner == id, self.playbackEpoch == epoch else { return }
                        self.pendingFrames -= BrowserAudioBuffering.frames(in: message)
                        try self.schedule(pcm, owner: id)
                    } catch {
                        guard !Task.isCancelled, self?.playbackEpoch == epoch else { return }
                        self?.fail(id, message: error.localizedDescription)
                        return
                    }
                }
            }
        }

        private func prepareOutput(_ id: UUID) throws {
            try audioSession.acquire(id)
            audioSessionActive = true
            let engine = makeEngine()
            let player = makePlayer()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.format)
            do { try engine.start() } catch {
                try audioSession.release(id)
                audioSessionActive = false
                throw error
            }
            self.engine = engine
            self.player = player
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.fail(id, message: "Audio output changed. Turn page sound on again to resume.") }
            })
            #if os(iOS)
                observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
                    guard
                        let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        type == AVAudioSession.InterruptionType.began.rawValue else { return }
                    Task { @MainActor in self?.fail(id, message: "Page sound was interrupted. Turn it on again to resume.") }
                })
            #endif
        }

        func receive(_ id: UUID, message: RemoteBrowserAudio) {
            guard owner == id, message.isValid, !message.packets.isEmpty, message.sequence > lastSequence else { return }
            let frames = BrowserAudioBuffering.frames(in: message)
            if pendingFrames + queuedFrames + frames > BrowserAudioBuffering.maximumPlaybackFrames {
                droppedFrames += pendingFrames + queuedFrames
                resynchronizations += 1
                resetPlayback()
                startDecoder(id)
            } else if lastSequence > 0, message.sequence != lastSequence + 1 {
                resynchronizations += 1
            }
            lastSequence = message.sequence
            pendingFrames += frames
            continuation?.yield(message)
        }

        func stop(_ id: UUID) {
            guard owner == id else { return }
            owner = nil
            onStop = nil
            if droppedFrames > 0 || underruns > 0 || resynchronizations > 0 {
                Logger(label: "com.ctrlx.browser-audio").info("Viewer audio: discarded \(droppedFrames) frames, \(underruns) underruns, \(resynchronizations) resynchronizations")
            }
            resetPlayback()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            engine?.stop()
            player = nil
            engine = nil
            guard audioSessionActive else { return }
            audioSessionActive = false
            do { try audioSession.release(id) } catch {
                Logger(label: "com.ctrlx.browser-audio").error("Could not release audio output: \(error)")
            }
        }

        private func fail(_ id: UUID, message: String?) {
            guard owner == id else { return }
            let callback = onStop
            stop(id)
            callback?(message)
        }

        private static var format: AVAudioFormat {
            AVAudioFormat(standardFormatWithSampleRate: RemoteBrowserAudio.sampleRate, channels: RemoteBrowserAudio.channels)!
        }

        private func schedule(_ pcm: Data, owner id: UUID) throws {
            guard !pcm.isEmpty else { return }
            if engine == nil {
                try prepareOutput(id)
            }
            guard let player else { return }
            rebufferIfDrained()
            let frames = pcm.count / 8
            let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: UInt32(frames))!
            buffer.frameLength = buffer.frameCapacity
            pcm.withUnsafeBytes { bytes in
                let samples = bytes.bindMemory(to: Float.self)
                for channel in 0..<2 {
                    for frame in 0..<frames {
                        buffer.floatChannelData![channel][frame] = samples[frame * 2 + channel]
                    }
                }
            }
            let queuedFrameCount = queuedFrameCount
            queuedFrameCount.withLock { $0 += frames }
            let epoch = playbackEpoch
            let playerEpoch = playerEpoch
            // Account on the audio callback thread, before hopping to a busy UI
            // actor. Player time can include silence between scheduled buffers.
            player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
                queuedFrameCount.withLock { $0 -= frames }
                Task { @MainActor in
                    guard let self, self.owner == id, self.playbackEpoch == epoch, self.playerEpoch == playerEpoch else { return }
                    self.rebufferIfDrained()
                }
            }
            if !isPlaying {
                if queuedFrames >= BrowserAudioBuffering.prebufferFrames {
                    beginPlayback()
                } else if prebufferTask == nil {
                    // A short sound must still play even if it never fills the buffer.
                    prebufferTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(Double(BrowserAudioBuffering.prebufferFrames) / RemoteBrowserAudio.sampleRate))
                        } catch { return }
                        guard
                            !Task.isCancelled, let self, self.owner == id,
                            self.playbackEpoch == epoch, self.playerEpoch == playerEpoch else { return }
                        self.beginPlayback()
                    }
                }
            }
        }

        private func beginPlayback() {
            prebufferTask?.cancel()
            prebufferTask = nil
            guard queuedFrames > 0 else { return }
            player?.play()
            isPlaying = true
        }

        private func rebufferIfDrained() {
            guard isPlaying, queuedFrames == 0 else { return }
            underruns += 1
            resetPlayer()
        }

        private func resetPlayer() {
            // A retired player's callbacks keep their own counter, including
            // callbacks invoked by stop() while cancelling scheduled buffers.
            playerEpoch = UUID()
            queuedFrameCount = OSAllocatedUnfairLock(initialState: 0)
            player?.stop()
            isPlaying = false
        }

        private func resetPlayback() {
            playbackEpoch = UUID()
            task?.cancel()
            task = nil
            continuation?.finish()
            continuation = nil
            prebufferTask?.cancel()
            prebufferTask = nil
            resetPlayer()
            pendingFrames = 0
        }
    }
#endif
