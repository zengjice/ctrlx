import AVFoundation
import CryptoKit
import CtrlxNetworking
import Dependencies
import Foundation
import ImageIO
import Testing
@testable import CtrlxCommon

struct AgentWorkflowMediaTests {
    private func fixture() -> URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CtrlxE2ELib/Scenarios/SampleFiles/test_video_with_audio.mp4")
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test
    func actualVideoProducesReadableSamplesAndAudioFromOneFrozenOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-media-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AgentWorkflowMediaStorage(root: root)
        let original = try Data(contentsOf: fixture())
        let source = try await withDependencies { $0[FileBrowserUploadReader.self] = .liveValue } operation: {
            try await storage.prepare(fixture(), mediaType: "video/mp4")
        }
        #expect(source.hasAudio && source.hasVideo && source.duration > 1)
        #expect(source.sha256 == hash(original))
        #expect(try Data(contentsOf: source.url) == original)
        await #expect(throws: AgentWorkflowError.self) { try await storage.outputs(source.id, transcript: nil) }
        let frames = try await storage.frames(source.id, count: 4)
        #expect(frames.count == 4)
        #expect(frames.map(\.seconds) == frames.map(\.seconds).sorted())
        for (index, frame) in frames.enumerated() {
            #expect(abs(frame.seconds - source.duration * Double(index) / 4) < 0.15)
        }
        for frame in frames {
            #expect(frame.seconds >= 0 && frame.seconds < source.duration)
            let data = try Data(contentsOf: frame.url)
            let image = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
            #expect(max(decoded.width, decoded.height) <= 1_600)
            #expect(!frame.thumbnail.isEmpty)
        }
        let audio = try await storage.audio(source.id)
        let asset = AVURLAsset(url: audio)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
        let excluded = try await storage.outputs(source.id, transcript: nil)
        #expect(excluded.count == 5)
        #expect(try String(contentsOf: excluded[0].url, encoding: .utf8).contains("Audio was explicitly excluded"))
        let reviewed = try await storage.outputs(source.id, transcript: "经过校对的语音。\nSecond line.")
        let notes = try String(contentsOf: reviewed[0].url, encoding: .utf8)
        #expect(notes.contains(source.sha256) && notes.contains("not a complete account") && notes.contains("经过校对的语音。\nSecond line."))
        #expect(!notes.contains("Audio was explicitly excluded"))
        await #expect(throws: AgentWorkflowError.self) { try await storage.outputs(source.id, transcript: " ") }
        try await storage.remove(source.id)
        #expect(!FileManager.default.fileExists(atPath: source.url.path))
        await #expect(throws: AgentWorkflowError.self) { try await storage.frames(source.id, count: 4) }
    }

    @Test
    func cancelledSnapshotClosesReaderAndLeavesNoFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-media-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AgentWorkflowMediaStorage(root: root), state = CancellationState()
        let task = Task {
            try await withDependencies {
                $0[FileBrowserUploadReader.self] = .init(
                    open: { _ in .init(id: UUID(), name: "clip.mp4", size: 10) },
                    read: { _ in throw CancellationError() },
                    finish: { _ in Issue.record("Cancelled snapshot cannot be finished")
                        return ""
                    },
                    close: { _ in await state.close() }
                )
            } operation: {
                try await storage.prepare(URL(fileURLWithPath: "/unused/clip.mp4"), mediaType: "video/mp4")
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await state.closed)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test
    func badMediaNeverPublishesASource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-media-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("invalid.mp4")
        try Data("not a video".utf8).write(to: file)
        let snapshots = root.appendingPathComponent("snapshots")
        let storage = AgentWorkflowMediaStorage(root: snapshots)
        await withDependencies { $0[FileBrowserUploadReader.self] = .liveValue } operation: {
            await #expect(throws: (any Error).self) { try await storage.prepare(file, mediaType: "video/mp4") }
        }
        #expect(try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil).isEmpty)
    }

    private actor CancellationState {
        var closed = false
        func close() {
            closed = true
        }
    }

    @MainActor
    @Test
    func speechPermissionAndRecordingOwnershipAreCheckedBeforeRecognition() async throws {
        let url = URL(fileURLWithPath: "/unused/audio.wav")
        await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .denied }, microphone: { Issue.record("A file transcription must not request a microphone")
                return false
            })
        } operation: {
            await #expect(throws: AgentWorkflowError.self) { try await AgentWorkflowMediaSpeech.transcribe(url, locale: "en-US") }
        }
        let lease = try #require(VoiceInputRecordingOwnership.shared.acquire())
        defer { VoiceInputRecordingOwnership.shared.release(lease) }
        await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: { false })
        } operation: {
            await #expect(throws: AgentWorkflowError.self) { try await AgentWorkflowMediaSpeech.transcribe(url, locale: "en-US") }
        }
    }
}
