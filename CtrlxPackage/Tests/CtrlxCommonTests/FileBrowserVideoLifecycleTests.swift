import AVFoundation
import CtrlxNetworking
import Foundation
import SwiftUI
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("Video preview lifecycle", .serialized)
struct FileBrowserVideoLifecycleTests {
    @Test
    func repeatedUnbufferedSeeksWaitForResumeAndStopCleanly() async throws {
        let data = try await longVideo()
        let info = FileBrowserEntry(
            path: "/Host/long.mp4",
            name: "long.mp4",
            kind: .unsupported,
            size: data.count,
            revision: "test"
        )
        var reads = 0
        let source = FileBrowserSource(id: "test-host", paneID: nil) { operation in
            if case .info = operation {
                return .info(info)
            }
            guard case let .download(path, offset, revision) = operation else {
                throw FileBrowserError.message("Unexpected operation")
            }
            reads += 1
            try await Task.sleep(for: .milliseconds(20))
            return .chunk(.init(
                path: path,
                revision: revision,
                offset: offset,
                data: data.subdata(in: offset..<min(offset + FileBrowserLimits.chunkBytes, data.count))
            ))
        }
        let playback = FileBrowserVideoPlayback(startsMuted: true)
        defer { playback.stop() }
        try await playback.prepare(path: info.path, source: source)
        let player = try #require(playback.player)
        playback.play()
        try await waitUntil { player.timeControlStatus == .playing }
        #expect(reads * FileBrowserLimits.chunkBytes < data.count, "Playback must start before the full file arrives")

        for seconds in [80.0, 10.0, 95.0, 25.0, 70.0, 5.0] {
            player.pause()
            try await Task.sleep(for: .milliseconds(100))
            let pausedReads = reads
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in }
            try await Task.sleep(for: .milliseconds(100))
            #expect(reads == pausedReads, "Paused seeks wait for explicit resume rather than background downloading")
            player.play()
            try await waitUntil {
                player.timeControlStatus == .playing && abs(player.currentTime().seconds - seconds) < 1
            }
            if seconds == 80 {
                #expect(reads > pausedReads, "The first distant seek must fetch new data, not only exercise buffered playback")
            }
            #expect(playback.error == nil)
        }

        playback.stop()
        #expect(player.currentItem == nil)
        let stoppedReads = reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads == stoppedReads)
    }

    @Test("A reclaimed video restores paused and saves later progress across another eviction", arguments: [0.0, 60.0])
    func restoredVideoStaysPaused(seconds: Double) async throws {
        let data = try await longVideo()
        let info = FileBrowserEntry(path: "/Host/long.mp4", name: "long.mp4", kind: .unsupported, size: data.count, revision: "v1")
        var reads = 0
        let source = FileBrowserSource(id: "host", paneID: nil) { operation in
            if case .info = operation {
                return .info(info)
            }
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected request") }
            reads += 1
            return .chunk(.init(path: path, revision: revision, offset: offset, data: data.subdata(in: offset..<min(offset + FileBrowserLimits.chunkBytes, data.count))))
        }
        let session = FileBrowserPreviewSession()
        defer { session.close() }
        var environment = EnvironmentValues()
        environment.scenePhase = .active
        let owner = UUID()
        session.show(owner: owner, environment: environment)
        let position = session.position
        position.validate(revision: "v1")
        position.videoSeconds = seconds
        position.videoWasOpened = true
        position.videoMuted = true
        let playback = session.playback
        try await playback.prepare(path: info.path, source: source, position: position)
        if let pending = playback.restorationSeconds, pending > 0 {
            try await playback.restore(seconds: pending)
        }
        #expect(playback.restorationSeconds == nil)
        let player = try #require(playback.player)
        #expect(player.rate == 0)
        #expect(abs(player.currentTime().seconds - seconds) < 1)
        try await Task.sleep(for: .milliseconds(150))
        let pausedReads = reads
        try await Task.sleep(for: .milliseconds(150))
        #expect(reads == pausedReads)
        playback.play()
        try await waitUntil { player.timeControlStatus == .playing && player.currentTime().seconds >= seconds + 1 }
        session.hide(owner: owner)
        #expect(player.rate == 0)
        #expect(playback.player === player)
        let saved = position.videoSeconds
        #expect(saved >= seconds + 1)
        #expect(abs(saved - player.currentTime().seconds) < 0.1)

        session.evict()
        #expect(playback.player == nil)
        #expect(position.videoSeconds == saved)
        session.show(owner: UUID(), environment: environment)
        try await playback.prepare(path: info.path, source: source, position: position)
        if let pending = playback.restorationSeconds, pending > 0 {
            try await playback.restore(seconds: pending)
        }
        let restored = try #require(playback.player)
        #expect(restored !== player)
        #expect(restored.rate == 0)
        #expect(abs(restored.currentTime().seconds - saved) < 1)
        #expect(restored.currentTime().seconds >= seconds + 0.5)
    }

    private func longVideo() async throws -> Data {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let asset = AVURLAsset(url: package.appendingPathComponent("Sources/CtrlxE2ELib/Scenarios/SampleFiles/test_video.mp4"))
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for _ in 0..<24 {
            try await composition.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: asset,
                at: composition.duration
            )
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-video-lifecycle-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: output, as: .mp4)
        let data = try Data(contentsOf: output)
        #expect(data.count > FileBrowserVideo.cacheBytes)
        #expect(composition.duration.seconds > 100)
        return data
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Native playback did not reach the requested position")
    }
}
