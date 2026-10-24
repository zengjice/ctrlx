import AVFoundation
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

struct AgentWorkflowMediaSource: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let mediaType: String
    let sha256: String
    let duration: Double
    let hasAudio: Bool
    let hasVideo: Bool
}

struct AgentWorkflowMediaFrame: Identifiable, Sendable {
    let id: UUID
    let seconds: Double
    let thumbnail: Data
    let url: URL
}

struct AgentWorkflowMediaOutput: Sendable {
    let url: URL
    let mediaType: String
    let description: String
}

@DependencyClient
struct AgentWorkflowMediaClient: Sendable {
    var prepare: @Sendable (URL, String) async throws -> AgentWorkflowMediaSource
    var frames: @Sendable (UUID, Int) async throws -> [AgentWorkflowMediaFrame]
    var transcribe: @Sendable (UUID, String) async throws -> String
    var outputs: @Sendable (UUID, String?) async throws -> [AgentWorkflowMediaOutput]
    var remove: @Sendable (UUID) async throws -> Void
}

extension AgentWorkflowMediaClient: DependencyKey {
    static let liveValue: Self = {
        let storage = AgentWorkflowMediaStorage()
        return Self(
            prepare: { try await storage.prepare($0, mediaType: $1) },
            frames: { try await storage.frames($0, count: $1) },
            transcribe: { id, locale in
                let audio = try await storage.audio(id)
                let text = try await AgentWorkflowMediaSpeech.transcribe(audio, locale: locale)
                try Task.checkCancellation()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentWorkflowError("No speech was recognized. Try another language or enter the transcript yourself.")
                }
                return text
            },
            outputs: { try await storage.outputs($0, transcript: $1) },
            remove: { try await storage.remove($0) }
        )
    }()
}

/// A private snapshot is the source of both the conversion and the uploaded
/// original. No conversion reads the user's potentially changing source twice.
actor AgentWorkflowMediaStorage {
    private let root: URL
    private var sources: [UUID: AgentWorkflowMediaSource] = [:]
    private var samples: [UUID: [AgentWorkflowMediaFrame]] = [:]
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowMedia")

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-media")) {
        self.root = root
    }

    func prepare(_ url: URL, mediaType: String) async throws -> AgentWorkflowMediaSource {
        guard ["audio/wav", "audio/mpeg", "audio/mp4", "video/mp4", "video/quicktime"].contains(mediaType) else {
            throw AgentWorkflowError("Choose an audio or video file to convert.")
        }
        @Dependency(FileBrowserUploadReader.self) var reader
        let file = try await reader.open(url)
        let directory = directory(file.id)
        let original = directory.appendingPathComponent("original").appendingPathComponent(file.name)
        do {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: original.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AgentWorkflowError("Could not create a private media snapshot.")
            }
            let handle = try FileHandle(forWritingTo: original)
            do {
                var size = 0
                while size < file.size {
                    try Task.checkCancellation()
                    let chunk = try await reader.read(file.id)
                    guard !chunk.isEmpty, chunk.count <= file.size - size else { throw AgentWorkflowError("The media snapshot was incomplete.") }
                    try handle.write(contentsOf: chunk)
                    size += chunk.count
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let checksum = try await reader.finish(file.id)
            await reader.close(file.id)
            try Task.checkCancellation()
            let asset = AVURLAsset(url: original)
            let duration = try await asset.load(.duration).seconds
            let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
            let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            guard
                duration.isFinite, duration > 0, hasVideo || hasAudio,
                !mediaType.hasPrefix("audio/") || !hasVideo else {
                throw AgentWorkflowError("This file does not contain readable audio or video.")
            }
            try Task.checkCancellation()
            let source = AgentWorkflowMediaSource(id: file.id, url: original, mediaType: mediaType, sha256: checksum, duration: duration, hasAudio: hasAudio, hasVideo: hasVideo)
            sources[file.id] = source
            return source
        } catch {
            await reader.close(file.id)
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch { Self.logger.error("Could not remove a failed media snapshot: \(error.localizedDescription)") }
            throw error
        }
    }

    func frames(_ id: UUID, count: Int) async throws -> [AgentWorkflowMediaFrame] {
        let source = try source(id)
        guard source.hasVideo, (1...16).contains(count) else { throw AgentWorkflowError("Choose between 1 and 16 video samples.") }
        var frames: [AgentWorkflowMediaFrame] = []
        // An unsuccessful resampling must not leave old frames presented as new.
        samples[id] = nil
        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = source.duration * Double(index) / Double(count)
            let result = try await Self.image(source.url, seconds: seconds)
            _ = try self.source(id)
            let name = String(format: "frame-%02d.jpg", index + 1)
            let url = directory(id).appendingPathComponent(name)
            let jpeg = try Self.jpeg(result.image)
            try jpeg.write(to: url, options: .atomic)
            guard
                let imageSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                ] as CFDictionary) else { throw AgentWorkflowError("Could not preview the video sample.") }
            try frames.append(.init(id: UUID(), seconds: result.actualTime.seconds, thumbnail: Self.jpeg(thumbnail), url: url))
        }
        _ = try self.source(id)
        samples[id] = frames
        return frames
    }

    func audio(_ id: UUID) async throws -> URL {
        let source = try source(id)
        guard source.hasAudio else { throw AgentWorkflowError("This media file has no audio track.") }
        if !source.hasVideo {
            return source.url
        }
        let url = directory(id).appendingPathComponent("audio.m4a")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try await Self.exportAudio(source.url, to: url)
        _ = try self.source(id)
        return url
    }

    func outputs(_ id: UUID, transcript: String?) throws -> [AgentWorkflowMediaOutput] {
        let source = try source(id)
        let frames = samples[id] ?? []
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.hasVideo || !frames.isEmpty else { throw AgentWorkflowError("Sample and review the video before importing.") }
        guard source.hasVideo || text?.isEmpty == false else { throw AgentWorkflowError("Enter or transcribe the audio before importing.") }
        guard transcript == nil || text?.isEmpty == false else { throw AgentWorkflowError("The transcript is empty. Review it or explicitly exclude audio.") }
        var document = "# Reviewed media conversion\n\nOriginal: \(source.url.lastPathComponent)\nSHA-256: \(source.sha256)\nDuration: \(String(format: "%.3f", source.duration)) seconds\n"
        if source.hasVideo {
            document += "\nThese are sampled frames, not a complete account of the video. Events between samples may be missing. Find each frame by its attachment name in the workflow attachment list, not by a relative path.\n\n"
            for frame in frames {
                document += "- \(frame.url.lastPathComponent): \(String(format: "%.3f", frame.seconds)) seconds\n"
            }
        }
        if let text {
            document += "\n## User-reviewed transcript\n\n\(text)\n"
        } else {
            document += source.hasAudio ? "\nAudio was explicitly excluded by the user.\n" : "\nThe source has no audio track.\n"
        }
        guard document.utf8.count <= 2 * 1_024 * 1_024 else { throw AgentWorkflowError("The reviewed transcript exceeds the 2 MiB text limit.") }
        let url = directory(id).appendingPathComponent("media-notes.md")
        try Data(document.utf8).write(to: url, options: .atomic)
        return [.init(url: url, mediaType: "text/markdown", description: source.hasVideo ? "Reviewed video sampling notes and audio inclusion decision" : "User-reviewed audio transcript")]
            + frames.map { .init(url: $0.url, mediaType: "image/jpeg", description: "Video sample at \(String(format: "%.3f", $0.seconds)) seconds; intervening frames are not included") }
    }

    func remove(_ id: UUID) throws {
        sources.removeValue(forKey: id)
        samples.removeValue(forKey: id)
        let directory = directory(id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func source(_ id: UUID) throws -> AgentWorkflowMediaSource {
        try Task.checkCancellation()
        guard let source = sources[id] else { throw AgentWorkflowError("The media conversion is no longer open.") }
        return source
    }

    private func directory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString)
    }

    @concurrent
    private static func image(_ url: URL, seconds: Double) async throws -> (image: CGImage, actualTime: CMTime) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        try Task.checkCancellation()
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        try Task.checkCancellation()
        return image
    }

    @concurrent
    private static func exportAudio(_ source: URL, to destination: URL) async throws {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw AgentWorkflowError("Could not extract this video's audio.")
        }
        try Task.checkCancellation()
        try await export.export(to: destination, as: .m4a)
        try Task.checkCancellation()
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AgentWorkflowError("Could not encode the video frame.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AgentWorkflowError("Could not finish the video frame.") }
        return data as Data
    }
}
