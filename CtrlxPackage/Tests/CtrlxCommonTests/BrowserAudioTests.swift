import AVFoundation
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Browser audio", .serialized)
struct BrowserAudioTests {
    @Test @MainActor
    func renderedAudioLeavesTheQueueWithoutWaitingForTheOutputDevice() async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        // Offline rendering has no device-playback completion. It must still
        // drain the queue instead of counting downstream latency as backlog.
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let output = BrowserAudioOutput(makeEngine: { engine })
        let owner = UUID()
        var failure: String?
        try output.start(owner) { failure = $0 }
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        let pcm = [Float](repeating: 0, count: 2_048 * 2).withUnsafeBytes { Data($0) }
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        for sequence in 1...32 {
            let encoded = try await encoder.encode(pcm)
            output.receive(owner, message: .init(
                tabID: UUID(), surfaceID: UUID(), controlID: UUID(), streamID: owner,
                sequence: UInt64(sequence), packets: encoded.packets, magicCookie: encoded.cookie
            ))
            try await RemoteBrowserSessionTests().wait { output.queuedFrames > 0 || failure != nil }
            try #require(failure == nil)
            #expect(try engine.renderOffline(AVAudioFrameCount(output.queuedFrames + 1_024), to: rendered) == .success)
            try await RemoteBrowserSessionTests().wait { output.queuedFrames == 0 }
        }
    }

    @Test @MainActor
    func unrenderedAudioStillClearsWhenTheQueueExceedsItsLimit() async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let output = BrowserAudioOutput(makeEngine: { engine })
        let owner = UUID()
        var failure: String?
        try output.start(owner) { failure = $0 }
        defer { output.stop(owner) }
        let encoder = BrowserAudioCodec()
        let pcm = [Float](repeating: 0, count: 2_048 * 2).withUnsafeBytes { Data($0) }
        for sequence in 1...7 {
            let encoded = try await encoder.encode(pcm)
            output.receive(owner, message: .init(
                tabID: UUID(), surfaceID: UUID(), controlID: UUID(), streamID: owner,
                sequence: UInt64(sequence), packets: encoded.packets, magicCookie: encoded.cookie
            ))
            let expected = sequence <= 6 ? sequence * 2_048 : 2_048
            try await RemoteBrowserSessionTests().wait { output.queuedFrames == expected || failure != nil }
            try #require(failure == nil)
        }
        output.stop(owner)
        #expect(output.queuedFrames == 0)
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

    @Test
    func aacRoundTripPreservesAudibleStereoWithoutUncompressedTransport() async throws {
        let encoder = BrowserAudioCodec(), decoder = BrowserAudioCodec()
        var packets: [Data] = []
        var decoded = Data()
        for block in 0..<20 {
            var samples = [Float](repeating: 0, count: 4_096 * 2)
            for frame in 0..<4_096 {
                let phase = Double(block * 4_096 + frame) / 48_000 * 2 * Double.pi
                samples[frame * 2] = Float(sin(phase * 440) * 0.25)
                samples[frame * 2 + 1] = Float(sin(phase * 880) * 0.25)
            }
            let pcm = samples.withUnsafeBytes { Data($0) }
            let encoded = try await encoder.encode(pcm)
            packets += encoded.packets
            if !encoded.packets.isEmpty {
                decoded += try await decoder.decode(encoded.packets, cookie: encoded.cookie)
            }
        }
        #expect(packets.count > 50)
        #expect(packets.reduce(0) { $0 + $1.count } < 40_000)
        #expect(decoded.count > 48_000 * 8)
        let samples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(samples.allSatisfy { $0.isFinite })
        let frames = samples.count / 2
        #expect(abs(frames - 20 * 4_096) <= 2_048)
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
