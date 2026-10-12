import AVFoundation
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("On-demand video previews", .serialized)
struct FileBrowserVideoTests {
    private let block = FileBrowserLimits.chunkBytes

    private func info(size: Int, path: String = "/Host/movie.mp4") -> FileBrowserEntry {
        .init(path: path, name: (path as NSString).lastPathComponent, kind: .unsupported, size: size, revision: "1")
    }

    @Test func formatsAndRangesAreBoundedWithoutIntegerOverflow() throws {
        for path in ["/Host/中文.MP4", "/Host/movie.MOV"] { #expect(FileBrowserVideo.supports(path: path)) }
        for path in ["movie.mkv", "movie.mp4.txt", "movie", "movie.m3u8"] { #expect(!FileBrowserVideo.supports(path: path)) }
        let entire = try FileBrowserVideoRange(offset: 7, length: 1, toEnd: true, size: 20)
        #expect(entire.start == 7 && entire.end == 20)
        let clipped = try FileBrowserVideoRange(offset: 17, length: .max, toEnd: false, size: 20)
        #expect(clipped.end == 20)
        for offset: Int64 in [-1, 21, .max] {
            #expect(throws: FileBrowserError.self) { try FileBrowserVideoRange(offset: offset, length: 1, toEnd: false, size: 20) }
        }
    }

    @Test func randomReadsCacheHitsAndLRUEviction() async throws {
        let data = Data((0..<(4 * block + 9)).map { UInt8($0 % 251) })
        let info = info(size: data.count)
        var offsets: [Int] = []
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Expected a byte read") }
            offsets.append(offset)
            return .chunk(.init(path: path, revision: revision, offset: offset,
                               data: data.subdata(in: offset..<min(offset + self.block, data.count))))
        }
        let reader = try FileBrowserVideoReader(info: info, source: source, cacheBytes: 2 * block)
        #expect(try await reader.read(offset: 0, length: 7) == data.prefix(7))
        _ = try await reader.read(offset: block + 3, length: 7)
        _ = try await reader.read(offset: 1, length: 4)
        _ = try await reader.read(offset: 2 * block, length: 1)
        _ = try await reader.read(offset: block, length: 1)
        #expect(offsets == [0, block, 2 * block, block], "A repeated head read must hit cache; eviction must be LRU")
        #expect(reader.cachedBytes == 2 * block)
        #expect(try await reader.read(offset: data.count - 2, length: .max) == data.suffix(2))
        #expect(reader.cachedBytes <= 2 * block)
        #expect(try await reader.read(offset: data.count, length: 1).isEmpty)
        #expect(try await reader.read(offset: 0, length: 0).isEmpty)
        reader.clear()
        #expect(reader.cachedBytes == 0)
    }

    @Test(arguments: ["revision", "path", "offset", "empty", "oversized", "short", "disconnect"])
    func invalidReadsNeverEnterCache(failure: String) async throws {
        let info = info(size: block + 7)
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            if failure == "disconnect" { throw FileBrowserError.message("Host offline") }
            return .chunk(.init(path: failure == "path" ? "/wrong.mp4" : path,
                               revision: failure == "revision" ? "2" : revision, offset: failure == "offset" ? offset + 1 : offset,
                               data: Data(repeating: 7, count: failure == "empty" ? 0 : failure == "oversized" ? self.block + 1 : failure == "short" ? self.block - 1 : self.block)))
        }
        let reader = try FileBrowserVideoReader(info: info, source: source)
        await #expect(throws: FileBrowserError.self) { try await reader.read(offset: 0, length: 1) }
        #expect(reader.cachedBytes == 0)
    }

    @Test func legacyAndOversizedFilesFailBeforeByteRequests() async throws {
        var calls = 0
        let source = FileBrowserSource(id: "legacy", paneID: nil, downloadUnavailableReason: "Update the Host Mac") { _ in
            calls += 1
            throw FileBrowserError.message("No request expected")
        }
        let playback = FileBrowserVideoPlayback()
        await #expect(throws: FileBrowserError.self) { try await playback.prepare(path: "/movie.mp4", source: source) }
        #expect(calls == 0)
        #expect(playback.player == nil)
        for size in [0, FileBrowserLimits.maximumDownloadBytes + 1] {
            #expect(throws: FileBrowserError.self) { try FileBrowserVideoReader(info: info(size: size), source: source) }
        }
        _ = try FileBrowserVideoReader(info: info(size: FileBrowserLimits.maximumDownloadBytes), source: source)
    }

    @Test func cancellationDropsLateBytes() async throws {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            startedSignal.yield()
            for await _ in gate { break }
            return .chunk(.init(path: path, revision: revision, offset: offset, data: Data(repeating: 1, count: self.block)))
        }
        let reader = try FileBrowserVideoReader(info: info(size: block), source: source)
        let request = Task { try await reader.read(offset: 0, length: 1) }
        for await _ in started { break }
        request.cancel()
        release.yield()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(reader.cachedBytes == 0)
        startedSignal.finish()
        release.finish()
    }

    @Test func defaultCacheStaysBoundedAcrossALongVideo() async throws {
        let info = info(size: 100 * block)
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            return .chunk(.init(path: path, revision: revision, offset: offset, data: Data(repeating: UInt8(offset / self.block), count: self.block)))
        }
        let reader = try FileBrowserVideoReader(info: info, source: source)
        for index in 0..<100 {
            #expect(try await reader.read(offset: index * block, length: 1) == Data([UInt8(index)]))
            #expect(reader.cachedBytes <= FileBrowserVideo.cacheBytes)
        }
        #expect(reader.cachedBytes == FileBrowserVideo.cacheBytes)
    }

    @Test(arguments: ["background", "foreground", "stop"])
    func lateMetadataCannotRestartAbortedPreparation(lifecycle: String) async throws {
        let data = try fixture()
        let info = info(size: data.count)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { startedSignal.finish(); release.finish() }
        var reads = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation {
                startedSignal.yield()
                for await _ in gate { break }
                return .info(info)
            }
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            reads += 1
            return .chunk(.init(path: path, revision: revision, offset: offset,
                               data: data.subdata(in: offset..<min(offset + self.block, data.count))))
        }
        let playback = FileBrowserVideoPlayback()
        defer { playback.stop() }
        let preparation = Task {
            try await playback.prepare(path: info.path, source: source)
            playback.play()
        }
        for await _ in started { break }
        if lifecycle == "stop" { playback.stop() }
        else {
            playback.setSceneActive(false)
            if lifecycle == "foreground" { playback.setSceneActive(true) }
        }
        // Do not cancel the task: even a non-cooperative late response must be rejected.
        release.yield()
        await #expect(throws: CancellationError.self) { try await preparation.value }
        #expect(playback.player == nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(reads == 0, "Aborted preparation must not create an asset or request video bytes")
    }

    @Test func inactiveSceneRejectsPreparationBeforeRequests() async throws {
        var calls = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { _ in
            calls += 1
            throw FileBrowserError.message("No request expected")
        }
        let playback = FileBrowserVideoPlayback()
        playback.setSceneActive(false)
        await #expect(throws: CancellationError.self) { try await playback.prepare(path: "/movie.mp4", source: source) }
        playback.play()
        playback.setSceneActive(true)
        #expect(calls == 0)
        #expect(playback.player == nil)
    }

    @Test func lateMetadataDoesNotReplaceNewForegroundPreparation() async throws {
        let data = try fixture()
        let info = info(size: data.count)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { startedSignal.finish(); release.finish() }
        var requests = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation {
                requests += 1
                if requests == 1 {
                    startedSignal.yield()
                    for await _ in gate { break }
                }
                return .info(info)
            }
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            return .chunk(.init(path: path, revision: revision, offset: offset,
                               data: data.subdata(in: offset..<min(offset + self.block, data.count))))
        }
        let playback = FileBrowserVideoPlayback()
        defer { playback.stop() }
        let oldPreparation = Task { try await playback.prepare(path: info.path, source: source) }
        for await _ in started { break }
        playback.setSceneActive(false)
        playback.setSceneActive(true)
        try await playback.prepare(path: info.path, source: source)
        let currentPlayer = try #require(playback.player)
        release.yield()
        await #expect(throws: CancellationError.self) { try await oldPreparation.value }
        #expect(playback.player === currentPlayer)
        #expect(currentPlayer.currentItem != nil)
    }

    @Test func nativePlaybackPausesResumesAndReleasesTheItem() async throws {
        let data = try fixture()
        let info = info(size: data.count)
        var reads = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation { return .info(info) }
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            reads += 1
            try await Task.sleep(for: .milliseconds(20))
            return .chunk(.init(path: path, revision: revision, offset: offset, data: data.subdata(in: offset..<min(offset + self.block, data.count))))
        }
        let playback = FileBrowserVideoPlayback()
        defer { playback.stop() }
        try await playback.prepare(path: info.path, source: source)
        let player = try #require(playback.player)
        playback.play()
        try await waitUntil { player.timeControlStatus == .playing || playback.error != nil }
        #expect(playback.error == nil)
        player.pause()
        try await Task.sleep(for: .milliseconds(80))
        let pausedReads = reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads == pausedReads, "Paused playback must not keep downloading")
        player.play()
        try await waitUntil { player.timeControlStatus == .playing || playback.error != nil }
        #expect(playback.error == nil)
        playback.setSceneActive(false)
        playback.play()
        #expect(player.timeControlStatus == .paused)
        try await Task.sleep(for: .milliseconds(80))
        let backgroundReads = reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads == backgroundReads, "Inactive playback must not keep downloading")
        playback.setSceneActive(true)
        #expect(playback.player === player, "Backgrounding must preserve a ready player's position")
        #expect(player.timeControlStatus == .paused, "Returning to the foreground must not automatically resume")
        playback.play()
        try await waitUntil { player.timeControlStatus == .playing || playback.error != nil }
        #expect(playback.error == nil)
        playback.stop()
        #expect(playback.player == nil)
        #expect(player.currentItem == nil)
        let stoppedReads = reads
        try await Task.sleep(for: .milliseconds(80))
        #expect(reads == stoppedReads)
    }

    @Test func audioLeasesOnlyDeactivateAfterTheLastOwnerReleases() throws {
        var activations = 0
        var deactivations = 0
        let leases = FileBrowserVideoAudioLeases(activate: { activations += 1 }, deactivate: { deactivations += 1 })
        let first = UUID()
        let second = UUID()
        try leases.acquire(first)
        try leases.acquire(first)
        try leases.acquire(second)
        #expect(leases.owners == [first, second])
        #expect(activations == 2, "Duplicate acquisition must not reactivate audio")
        try leases.release(UUID())
        try leases.release(first)
        try leases.release(first)
        #expect(leases.owners == [second])
        #expect(deactivations == 0, "An active player must keep the shared session")
        try leases.release(second)
        try leases.release(second)
        #expect(leases.owners.isEmpty && deactivations == 1)
        try leases.acquire(first)
        try leases.release(first)
        #expect(leases.owners.isEmpty && activations == 3 && deactivations == 2)
    }

    @Test func failedAudioLeaseDoesNotAcquireOrReleaseAnotherOwnersSession() throws {
        var attempts = 0
        var deactivations = 0
        let leases = FileBrowserVideoAudioLeases(
            activate: {
                attempts += 1
                if attempts > 1 { throw FileBrowserError.message("Audio unavailable") }
            },
            deactivate: { deactivations += 1 }
        )
        let first = UUID()
        let second = UUID()
        try leases.acquire(first)
        #expect(throws: FileBrowserError.self) { try leases.acquire(second) }
        #expect(leases.owners == [first])
        try leases.release(second)
        #expect(leases.owners == [first] && deactivations == 0)
        try leases.release(first)
        #expect(leases.owners.isEmpty && deactivations == 1)
    }

    @Test(arguments: ["nativePause", "background", "stop"])
    func onePlayerReleasingAudioDoesNotDeactivateAnotherPlayersSession(action: String) async throws {
        var sessionIsActive = false
        var deactivations = 0
        let leases = FileBrowserVideoAudioLeases(
            activate: { sessionIsActive = true },
            deactivate: { sessionIsActive = false; deactivations += 1 }
        )
        try await withDependencies {
            $0[FileBrowserVideoAudioClient.self] = .init(
                acquire: { try leases.acquire($0) },
                release: { try leases.release($0) }
            )
        } operation: {
            let first = FileBrowserVideoPlayback(startsMuted: false)
            let second = FileBrowserVideoPlayback(startsMuted: false)
            defer { first.stop(); second.stop() }
            let data = try fixture()
            let info = info(size: data.count)
            let source = videoSource(data: data, info: info)
            try await first.prepare(path: info.path, source: source)
            try await second.prepare(path: info.path, source: source)
            let firstPlayer = try #require(first.player)
            let secondPlayer = try #require(second.player)
            first.play()
            let firstOwner = try #require(leases.owners.first)
            second.play()
            let secondOwner = try #require(leases.owners.subtracting([firstOwner]).first)
            try await waitUntil {
                firstPlayer.timeControlStatus == .playing && secondPlayer.timeControlStatus == .playing && leases.owners.count == 2
            }
            let previousDeactivations = deactivations
            switch action {
            case "nativePause": firstPlayer.pause()
            case "background": first.setSceneActive(false)
            default: first.stop()
            }
            try await waitUntil { leases.owners == [secondOwner] && secondPlayer.timeControlStatus == .playing }
            #expect(sessionIsActive && deactivations == previousDeactivations)
            first.stop()
            first.stop()
            #expect(leases.owners == [secondOwner] && sessionIsActive && deactivations == previousDeactivations)
            second.stop()
            #expect(leases.owners.isEmpty && !sessionIsActive)
            #expect(deactivations == previousDeactivations + 1)
        }
    }

    @Test func audioSessionFollowsExplicitAndNativePlayback() async throws {
        var activations = 0
        var deactivations = 0
        let leases = FileBrowserVideoAudioLeases(activate: { activations += 1 }, deactivate: { deactivations += 1 })
        try await withDependencies {
            $0[FileBrowserVideoAudioClient.self] = .init(
                acquire: { try leases.acquire($0) },
                release: { try leases.release($0) }
            )
        } operation: {
            let playback = FileBrowserVideoPlayback(startsMuted: false)
            defer { playback.stop() }
            playback.play()
            #expect(activations == 0, "No player means no audio-session activation")
            let data = try fixture()
            let info = info(size: data.count)
            let source = videoSource(data: data, info: info)
            try await playback.prepare(path: info.path, source: source)
            #expect(activations == 0, "Preparing metadata must not interrupt other audio")
            let player = try #require(playback.player)
            playback.play()
            try await waitUntil { player.timeControlStatus == .playing && leases.owners.count == 1 }
            let owner = try #require(leases.owners.first)
            player.pause()
            try await waitUntil { player.timeControlStatus == .paused && leases.owners.isEmpty }
            player.play()
            try await waitUntil { leases.owners == [owner] && player.timeControlStatus == .playing }
            playback.setSceneActive(false)
            #expect(leases.owners.isEmpty)
            playback.play()
            // Native controls must not bypass the background guard either.
            player.play()
            try await waitUntil { player.timeControlStatus == .paused }
            playback.setSceneActive(true)
            try await Task.sleep(for: .milliseconds(80))
            #expect(leases.owners.isEmpty, "Returning to the foreground must not activate audio automatically")
            playback.play()
            try await waitUntil { leases.owners == [owner] && player.timeControlStatus == .playing }
            playback.stop()
            #expect(leases.owners.isEmpty)
            #expect(activations == deactivations, "Every activation must be balanced after teardown")
            let releases = deactivations
            playback.stop()
            #expect(deactivations == releases, "Repeated cleanup must not deactivate another audio session")
        }
    }

    @Test func audioActivationFailureDoesNotStartPlayback() async throws {
        var releases = 0
        try await withDependencies {
            $0[FileBrowserVideoAudioClient.self] = .init(
                acquire: { _ in throw FileBrowserError.message("Audio unavailable") },
                release: { _ in releases += 1 }
            )
        } operation: {
            let playback = FileBrowserVideoPlayback(startsMuted: false)
            defer { playback.stop() }
            let data = try fixture()
            let info = info(size: data.count)
            try await playback.prepare(path: info.path, source: videoSource(data: data, info: info))
            let player = try #require(playback.player)
            playback.play()
            #expect(playback.error?.contains("Audio unavailable") == true)
            #expect(player.timeControlStatus == .paused)
            player.play()
            try await waitUntil { player.timeControlStatus == .paused }
            playback.stop()
            #expect(releases == 0, "A failed activation must not release audio owned by another feature")
        }
    }

    @Test func defaultMutePolicyOnlyChangesOnIOS() {
        let playback = FileBrowserVideoPlayback()
        #if os(iOS)
        #expect(playback.isMuted)
        #else
        #expect(!playback.isMuted, "Mac playback must retain its existing audible default")
        #endif
    }

    @Test func mutedPlaybackAndSoundTogglePreserveThePlayer() async throws {
        var activations = 0
        var deactivations = 0
        let leases = FileBrowserVideoAudioLeases(activate: { activations += 1 }, deactivate: { deactivations += 1 })
        try await withDependencies {
            $0[FileBrowserVideoAudioClient.self] = .init(
                acquire: { try leases.acquire($0) },
                release: { try leases.release($0) }
            )
        } operation: {
            let playback = FileBrowserVideoPlayback(startsMuted: true)
            defer { playback.stop() }
            let data = try fixture()
            let info = info(size: data.count)
            try await playback.prepare(path: info.path, source: videoSource(data: data, info: info))
            let player = try #require(playback.player)
            let item = try #require(player.currentItem)
            #expect(playback.isMuted && player.isMuted)
            playback.play()
            try await waitUntil { player.timeControlStatus == .playing }
            #expect(activations == 0, "Starting muted must not explicitly activate media audio")
            let beforeToggle = player.currentTime()
            playback.toggleSound()
            #expect(!playback.isMuted && !player.isMuted)
            #expect(leases.owners.count == 1)
            let owner = try #require(leases.owners.first)
            playback.toggleSound()
            #expect(playback.isMuted && player.isMuted)
            #expect(player.timeControlStatus == .playing)
            #expect(playback.player === player && player.currentItem === item)
            #expect(CMTimeCompare(player.currentTime(), beforeToggle) >= 0, "Sound toggling must not seek back")
            player.pause()
            try await waitUntil { player.timeControlStatus == .paused && leases.owners.isEmpty }
            let pausedActivations = activations
            playback.toggleSound()
            #expect(!playback.isMuted)
            #expect(player.timeControlStatus == .paused)
            #expect(activations == pausedActivations, "Enabling sound while paused must not start playback or audio")
            player.play()
            try await waitUntil { leases.owners == [owner] && player.timeControlStatus == .playing }
            playback.setSceneActive(false)
            #expect(leases.owners.isEmpty)
            playback.setSceneActive(true)
            #expect(!playback.isMuted && !player.isMuted, "The current preview keeps the user's choice")
            #expect(player.timeControlStatus == .paused)
            playback.play()
            // AVPlayer may briefly pause again while completing a rapid background/resume.
            // Verify effective ownership, not the lifetime count of its status callbacks.
            try await waitUntil { leases.owners == [owner] && player.timeControlStatus == .playing }
            player.isMuted = true
            try await waitUntil { playback.isMuted }
            #expect(player.timeControlStatus == .playing, "Native mute must update the button, not pause the video")
            playback.stop()
            #expect(leases.owners.isEmpty && activations == deactivations)
            #expect(playback.isMuted, "Closing a preview resets its mute choice")
            try await playback.prepare(path: info.path, source: videoSource(data: data, info: info))
            #expect(playback.player?.isMuted == true, "Reopening must assign mute before the first frame")
            playback.play()
            try await waitUntil { playback.player?.timeControlStatus == .playing }
            #expect(leases.owners.isEmpty)
            playback.player?.isMuted = false
            try await waitUntil { !playback.isMuted && leases.owners == [owner] }
            playback.stop()
            #expect(leases.owners.isEmpty && activations == deactivations)
        }
    }

    @Test func failedSoundActivationKeepsTheVideoMuted() async throws {
        try await withDependencies {
            $0[FileBrowserVideoAudioClient.self] = .init(
                acquire: { _ in throw FileBrowserError.message("Audio unavailable") },
                release: { _ in Issue.record("Failed activation must not own an audio session") }
            )
        } operation: {
            let playback = FileBrowserVideoPlayback(startsMuted: true)
            defer { playback.stop() }
            let data = try fixture()
            let info = info(size: data.count)
            try await playback.prepare(path: info.path, source: videoSource(data: data, info: info))
            let player = try #require(playback.player)
            playback.play()
            try await waitUntil { player.timeControlStatus == .playing }
            playback.toggleSound()
            #expect(playback.isMuted && player.isMuted)
            #expect(player.timeControlStatus == .paused)
            #expect(playback.error?.contains("Audio unavailable") == true)
            player.isMuted = false
            player.play()
            try await waitUntil { playback.isMuted && player.timeControlStatus == .paused }
        }
    }

    @Test func streamedVideoPreservesItsAudioTrack() async throws {
        let data = try fixture(name: "test_video_with_audio.mp4")
        let info = info(size: data.count)
        let reader = try FileBrowserVideoReader(info: info, source: videoSource(data: data, info: info))
        let loader = try FileBrowserVideoResourceLoader(reader: reader) { Issue.record("\($0)") }
        defer { loader.stop() }
        let asset = loader.makeAsset()
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-video-audio-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        let export = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        try await export.export(to: output, as: .m4a)
        let audioAsset = AVURLAsset(url: output)
        #expect(try await audioAsset.loadTracks(withMediaType: .audio).count == 1)
        #expect(CMTimeGetSeconds(try await audioAsset.load(.duration)) > 1)
    }

    private func videoSource(data: Data, info: FileBrowserEntry) -> FileBrowserSource {
        FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation { return .info(info) }
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            return .chunk(.init(path: path, revision: revision, offset: offset,
                               data: data.subdata(in: offset..<min(offset + self.block, data.count))))
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), "Native video playback did not converge")
    }

    private func fixture(name: String = "test_video.mp4") throws -> Data {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: package.appendingPathComponent("Sources/CtrlxE2ELib/Scenarios/SampleFiles/\(name)"))
    }

    @Test(arguments: ["mp4", "mov"])
    func systemDecoderShowsFirstFrameAndSeeksBeforeFullDownload(format: String) async throws {
        let data: Data
        if format == "mov" {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let original = package.appendingPathComponent("Sources/CtrlxE2ELib/Scenarios/SampleFiles/test_video.mp4")
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-video-test-\(UUID()).mov")
            defer { try? FileManager.default.removeItem(at: copy) }
            let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPresetPassthrough))
            export.shouldOptimizeForNetworkUse = false
            try await export.export(to: copy, as: .mov)
            data = try Data(contentsOf: copy)
        } else { data = try fixture() }
        let info = info(size: data.count, path: "/Host/movie.\(format.uppercased())")
        var received = 0
        var offsets: [Int] = []
        var inFlight = 0
        var maximumInFlight = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Expected random video read") }
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            defer { inFlight -= 1 }
            try await Task.sleep(for: .milliseconds(10))
            let chunk = data.subdata(in: offset..<min(offset + self.block, data.count))
            received += chunk.count
            offsets.append(offset)
            return .chunk(.init(path: path, revision: revision, offset: offset, data: chunk))
        }
        let reader = try FileBrowserVideoReader(info: info, source: source)
        let loader = try FileBrowserVideoResourceLoader(reader: reader) { message in Issue.record("\(message)") }
        defer { loader.stop() }
        let asset = loader.makeAsset()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let first = try await generator.image(at: .zero)
        #expect(first.image.width == 1280 && first.image.height == 720)
        #expect(received < data.count, "The first decoded frame must not require a complete download")
        if format == "mov" {
            #expect(offsets.contains(data.count / block * block), "Tail-indexed MOV metadata must be reachable before decoding the first frame")
        }
        let later = try await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600))
        let previous = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        #expect(later.image.width == first.image.width)
        #expect(previous.image.width == first.image.width)
        #expect(maximumInFlight == 1)
        #expect(reader.cachedBytes <= FileBrowserVideo.cacheBytes)
        loader.stop()
        #expect(reader.cachedBytes == 0)
    }

    @Test func suspensionAndStopPreventFurtherRequests() async throws {
        let data = try fixture()
        let info = info(size: data.count)
        var calls = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Expected random read") }
            calls += 1
            try await Task.sleep(for: .milliseconds(5))
            return .chunk(.init(path: path, revision: revision, offset: offset, data: data.subdata(in: offset..<min(offset + self.block, data.count))))
        }
        let reader = try FileBrowserVideoReader(info: info, source: source)
        let loader = try FileBrowserVideoResourceLoader(reader: reader) { message in Issue.record("\(message)") }
        defer { loader.stop() }
        loader.setSuspended(true)
        let asset = loader.makeAsset()
        let duration = Task { try await asset.load(.duration) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(calls == 0)
        loader.setSuspended(false)
        #expect(CMTimeGetSeconds(try await duration.value) > 4)
        #expect(calls > 0)
        loader.stop()
        let completed = calls
        try await Task.sleep(for: .milliseconds(80))
        #expect(calls == completed)
        #expect(reader.cachedBytes == 0)
    }
}
