import AVFoundation
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Browser audio", .serialized)
struct BrowserAudioTests {
    @Test(arguments: [44_100.0, 48_000.0, 96_000.0]) @MainActor
    func jitteredDeliveryPreservesContinuousStereoAtDeviceSampleRate(rate: Double) async throws {
        let (output, engine, format, owner) = try outputFixture(rate: rate)
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        var events: [(tick: Int, message: RemoteBrowserAudio)] = []
        var produced = 0
        for block in 1...250 {
            // CEF produces 1024-frame packets; the Host polls every 40 ms.
            let frames = block * 1_920 / 1_024 * 1_024 - produced
            var samples = [Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                let phase = 2 * Double.pi * Double(produced + frame) / 48_000
                samples[frame * 2] = Float(0.25 * sin(phase * 440))
                samples[frame * 2 + 1] = Float(0.25 * sin(phase * 880))
            }
            produced += frames
            let encoded = try await encoder.encode(samples.withUnsafeBytes { Data($0) })
            let group = (block - 1) / 5
            // Five messages arrive together, with up to 80 ms extra jitter.
            events.append(((group + 1) * 20 + [0, 8, 0, 4][group % 4], .init(
                tabID: owner, surfaceID: owner, controlID: owner, streamID: owner,
                sequence: UInt64(block), packets: encoded.packets, magicCookie: encoded.cookie
            )))
        }
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate / 100)))
        var next = 0, renderedFrames = 0
        var crossings = [0, 0], previous: [Float] = [0, 0]
        for tick in 0..<1_000 {
            while next < events.count, events[next].tick <= tick {
                output.receive(owner, message: events[next].message)
                next += 1
            }
            if output.pendingFrames > 0 {
                try await wait { output.pendingFrames == 0 }
            }
            guard engine.isRunning else { continue }
            #expect(try engine.renderOffline(rendered.frameCapacity, to: rendered) == .success)
            if tick >= 100 {
                for channel in 0..<2 {
                    let samples = try #require(rendered.floatChannelData)[channel]
                    for frame in 0..<Int(rendered.frameLength) {
                        if samples[frame] > 0, previous[channel] <= 0 {
                            crossings[channel] += 1
                        }
                        previous[channel] = samples[frame]
                    }
                }
                renderedFrames += Int(rendered.frameLength)
            }
            // Offline rendering outruns Core Audio's asynchronous completion
            // callbacks; allow them to arrive between simulated 10 ms quanta.
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(output.underruns == 0)
        #expect(output.droppedFrames == 0)
        #expect(output.resynchronizations == 0)
        for (channel, expected) in [440.0, 880.0].enumerated() {
            let frequency = Double(crossings[channel]) * rate / Double(renderedFrames)
            #expect(abs(frequency - expected) < 2)
        }
    }

    @Test @MainActor
    func renderedAudioLeavesTheQueueWithoutWaitingForTheOutputDevice() async throws {
        let (output, engine, format, owner) = try outputFixture()
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        for sequence in 1...32 {
            try output.receive(owner, message: await message(encoder, owner, sequence, frames: 6_144))
            try await wait { output.queuedFrames == 6_144 && output.isPlaying }
            #expect(try engine.renderOffline(7_168, to: rendered) == .success)
            try await wait { output.queuedFrames == 0 }
            #expect(!output.isPlaying)
        }
        #expect(output.droppedFrames == 0)
        #expect(output.resynchronizations == 0)
    }

    @Test @MainActor
    func concentratedDeliveryPreservesEveryBatchWithinTheTimeBudget() async throws {
        let (output, engine, format, owner) = try outputFixture()
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        var messages: [RemoteBrowserAudio] = []
        for sequence in 1...120 {
            try messages.append(await message(encoder, owner, sequence))
        }
        for start in stride(from: 0, to: 120, by: 6) {
            for packet in messages[start..<start + 6] {
                output.receive(owner, message: packet)
            }
            try await wait { output.pendingFrames == 0 && output.queuedFrames == 12_288 }
            #expect(output.isPlaying)
            #expect(try engine.renderOffline(8_192, to: rendered) == .success)
            #expect(try engine.renderOffline(4_096, to: rendered) == .success)
            try await wait { output.queuedFrames == 0 }
        }
        #expect(output.droppedFrames == 0)
        #expect(output.resynchronizations == 0)
    }

    @Test @MainActor
    func decodeAndPlaybackShareOneBudget() async throws {
        let (output, _, _, owner) = try outputFixture()
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        for sequence in 1...3 {
            try output.receive(owner, message: await message(encoder, owner, sequence, frames: 8_192))
            try await wait { output.pendingFrames == 0 }
        }
        #expect(output.queuedFrames == BrowserAudioBuffering.maximumFrames)
        try output.receive(owner, message: await message(encoder, owner, 4))
        try await wait { output.pendingFrames == 0 && output.queuedFrames == 2_048 }
        #expect(output.droppedFrames == 24_576)
        #expect(output.resynchronizations == 1)
        #expect(!output.isPlaying)
    }

    @Test @MainActor
    func incomingBurstIsBoundedBeforeDecodeStarts() async throws {
        let (output, _, _, owner) = try outputFixture()
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        var messages: [RemoteBrowserAudio] = []
        for sequence in 1...13 {
            try messages.append(await message(encoder, owner, sequence))
        }
        for packet in messages {
            output.receive(owner, message: packet)
        }
        #expect(output.pendingFrames == 2_048)
        try await wait { output.pendingFrames == 0 && output.queuedFrames == 2_048 }
        #expect(output.droppedFrames == 24_576)
        #expect(output.resynchronizations == 1)
    }

    @Test @MainActor
    func shortSoundsAndUnderrunsRebufferWithoutChangingSpeed() async throws {
        let (output, engine, format, owner) = try outputFixture()
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        for sequence in 1...2 {
            try output.receive(owner, message: await message(encoder, owner, sequence))
            try await wait { output.queuedFrames == 2_048 }
            #expect(!output.isPlaying)
            try await wait { output.isPlaying }
            #expect(try engine.renderOffline(3_072, to: rendered) == .success)
            try await wait { output.queuedFrames == 0 }
            #expect(!output.isPlaying)
        }
        #expect(output.underruns == 2)
        #expect(output.droppedFrames == 0)
    }

    @Test @MainActor
    func sequenceGapResynchronizesAndStopCancelsDelayedPlayback() async throws {
        let (output, _, _, owner) = try outputFixture()
        let encoder = BrowserAudioCodec()
        try output.receive(owner, message: await message(encoder, owner, 1))
        try await wait { output.queuedFrames == 2_048 }
        try output.receive(owner, message: await message(encoder, owner, 3))
        try await wait { output.pendingFrames == 0 && output.queuedFrames == 2_048 }
        #expect(output.resynchronizations == 1)
        #expect(output.droppedFrames == 2_048)
        output.stop(owner)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!output.isPlaying && output.queuedFrames == 0 && output.pendingFrames == 0)
    }

    @MainActor
    private func outputFixture(rate: Double = 48_000) throws -> (BrowserAudioOutput, AVAudioEngine, AVAudioFormat, UUID) {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 8_192)
        let output = BrowserAudioOutput(makeEngine: { engine }), owner = UUID()
        try output.start(owner) {
            if let error = $0 {
                Issue.record("Playback failed: \(error)")
            }
        }
        return (output, engine, format, owner)
    }

    private func message(_ encoder: BrowserAudioCodec, _ owner: UUID, _ sequence: Int, frames: Int = 2_048) async throws -> RemoteBrowserAudio {
        let pcm = [Float](repeating: 0.15, count: frames * 2).withUnsafeBytes { Data($0) }
        let encoded = try await encoder.encode(pcm)
        return .init(
            tabID: UUID(),
            surfaceID: UUID(),
            controlID: UUID(),
            streamID: owner,
            sequence: UInt64(sequence),
            packets: encoded.packets,
            magicCookie: encoded.cookie
        )
    }

    @MainActor
    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        try await RemoteBrowserSessionTests().wait(condition)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_BROWSER_AUDIO_PLAYBACK_TEST"] == "1"))
    @MainActor
    func aacBatchesCanBeScheduledOnTheNativeOutputDevice() async throws {
        var acquired = 0, released = 0
        var failure: String?
        try await withDependencies {
            $0[FileBrowserVideoAudioClient.self] = .init(acquire: { _ in acquired += 1 }, release: { _ in released += 1 })
        } operation: {
            let owner = UUID()
            let output = BrowserAudioOutputClient.liveValue
            try output.start(owner) { failure = $0 }
            defer { output.stop(owner) }
            let encoder = BrowserAudioCodec()
            let pcm = [Float](repeating: 0, count: 4_096 * 2).withUnsafeBytes { Data($0) }
            for sequence in 1...4 {
                let encoded = try await encoder.encode(pcm)
                if !encoded.packets.isEmpty {
                    output.receive(owner, .init(
                        tabID: UUID(),
                        surfaceID: UUID(),
                        controlID: UUID(),
                        streamID: owner,
                        sequence: UInt64(sequence),
                        packets: encoded.packets,
                        magicCookie: encoded.cookie
                    ))
                }
            }
            try await RemoteBrowserSessionTests().wait { acquired > 0 || failure != nil }
            try await Task.sleep(for: .milliseconds(100))
            #expect(acquired == 1)
            #expect(failure == nil)
            output.stop(owner)
            #expect(released == 1)
        }
    }

    @Test @MainActor
    func aSilentPageDoesNotAcquireTheSystemAudioSession() throws {
        var acquisitions = 0, releases = 0
        try withDependencies {
            $0[FileBrowserVideoAudioClient.self] = .init(acquire: { _ in acquisitions += 1 }, release: { _ in releases += 1 })
        } operation: {
            let owner = UUID()
            try BrowserAudioOutputClient.liveValue.start(owner) { _ in }
            #expect(acquisitions == 0)
            BrowserAudioOutputClient.liveValue.stop(owner)
            #expect(releases == 0)
        }
    }

    @Test(arguments: [[4_096], [8_192], [1_024, 8_192, 2_048, 4_096]])
    func aacRoundTripPreservesAudibleStereoWithoutUncompressedTransport(pattern: [Int]) async throws {
        let encoder = BrowserAudioCodec(), decoder = BrowserAudioCodec()
        var packets: [Data] = []
        var decoded = Data()
        var totalFrames = 0
        for block in 0..<20 {
            let count = pattern[block % pattern.count]
            var samples = [Float](repeating: 0, count: count * 2)
            for frame in 0..<count {
                let phase = Double(totalFrames + frame) / 48_000 * 2 * Double.pi
                samples[frame * 2] = Float(sin(phase * 440) * 0.25)
                samples[frame * 2 + 1] = Float(sin(phase * 880) * 0.25)
            }
            totalFrames += count
            let pcm = samples.withUnsafeBytes { Data($0) }
            let encoded = try await encoder.encode(pcm)
            packets += encoded.packets
            if !encoded.packets.isEmpty {
                decoded += try await decoder.decode(encoded.packets, cookie: encoded.cookie)
            }
        }
        #expect(packets.count > 50)
        #expect(packets.reduce(0) { $0 + $1.count } < totalFrames * 4)
        #expect(decoded.count > 48_000 * 8)
        let samples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(samples.allSatisfy { $0.isFinite })
        let frames = samples.count / 2
        #expect(abs(frames - totalFrames) <= 2_048)
        // Ignore codec priming and check both channel pitches, not just energy.
        let start = 8_192
        for (channel, expected) in [440.0, 880.0].enumerated() {
            let crossings = (start..<frames).count { frame in
                samples[frame * 2 + channel] > 0 && samples[(frame - 1) * 2 + channel] <= 0
            }
            let frequency = Double(crossings) * 48_000 / Double(frames - start)
            #expect(abs(frequency - expected) < 2)
        }
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        #expect(energy > 0.01 && energy < 0.1)
    }

    @Test
    func rejectsOversizedOrMalformedCodecInput() async {
        let codec = BrowserAudioCodec()
        await #expect(throws: (any Error).self) { try await codec.encode(Data([1])) }
        await #expect(throws: (any Error).self) { try await codec.encode(Data(repeating: 0, count: 65_544)) }
        await #expect(throws: (any Error).self) { try await codec.decode([Data(repeating: 1, count: 4_097)], cookie: nil) }
    }

    @Test @MainActor
    func onlyCurrentControlAndStreamCanPlayAndMuteFlushesImmediately() async throws {
        var played: [RemoteBrowserAudio] = [], stopped: [UUID] = [], requests: [BrowseBrowser] = []
        let tab = RemoteBrowserTab(id: UUID(), sessionName: "s", title: "page", url: "https://example.com", isLoading: false, isAgentOwned: false)
        let grant = UUID()
        var controlled = false
        var preempt: (@MainActor @Sendable (String?) -> Void)?
        try await withDependencies {
            $0[BrowserAudioOutputClient.self] = .init(start: { _, callback in preempt = callback }, receive: { _, message in played.append(message) }, stop: { stopped.append($0) })
        } operation: {
            let session = RemoteBrowserSession(tab: tab) { request in
                requests.append(request)
                if request.operation == .takeControl {
                    controlled = true
                }
                if request.operation == .releaseControl {
                    controlled = false
                }
                return .init(tab: tab, frame: .init(jpeg: Data([1]), width: 300, height: 400, generation: 1), controlID: controlled ? grant : nil)
            }
            session.setAudioSupport(true)
            let watching = Task { await session.watch() }
            defer { session.stop()
                watching.cancel()
            }
            try await RemoteBrowserSessionTests().wait { requests.contains {
                if case .audio = $0.operation {
                    true
                } else {
                    false
                }
            } }
            let audio = try #require(requests.first {
                if case .audio = $0.operation {
                    true
                } else {
                    false
                }
            })
            guard case let .audio(streamID, _, enabled) = audio.operation else { return }
            #expect(enabled)
            func packet(tabID: UUID? = nil, control: UUID? = nil, stream: UUID? = nil, sequence: UInt64 = 1) -> RemoteBrowserAudio {
                .init(
                    tabID: tabID ?? tab.id,
                    surfaceID: audio.surfaceID,
                    controlID: control ?? grant,
                    streamID: stream ?? streamID,
                    sequence: sequence,
                    packets: [Data([1])]
                )
            }
            session.receiveAudio(packet(tabID: UUID()))
            session.receiveAudio(packet(control: UUID()))
            session.receiveAudio(packet(stream: UUID()))
            #expect(played.isEmpty)
            session.receiveAudio(packet())
            session.receiveAudio(packet())
            #expect(played.count == 1)
            preempt?(nil)
            #expect(session.audioEnabled && !session.isAudioActive)
            session.submit(.pointer(.init(.move, x: 1, y: 1)))
            #expect(!session.isAudioActive)
            session.submit(.text("focus returns"))
            #expect(session.isAudioActive)
            session.setAudioEnabled(false)
            #expect(stopped.contains(streamID))
            preempt?(nil)
            session.submit(.text("focus returns while muted"))
            #expect(session.isAudioActive && !session.audioEnabled)
            session.receiveAudio(packet(sequence: 2))
            #expect(played.count == 1)
            session.setAudioEnabled(true)
            session.receiveAudio(packet(sequence: 3))
            #expect(played.count == 1)
            session.releaseControl()
            session.receiveAudio(packet(sequence: 4))
            #expect(played.count == 1)
        }
    }
}
