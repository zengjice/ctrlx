#if os(macOS) || os(iOS)
import AVFoundation
import CoreImage

/// Pulls a single displayed frame from the existing player. No second asset
/// download, capture timer, or change to the user's mute setting is needed.
@MainActor
final class FilePreviewVideoCapture {
    private weak var player: AVPlayer?
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    private var previous: (requestedTime: CMTime, snapshot: FilePreviewCapture.Snapshot)?

    init(player: AVPlayer) {
        self.player = player
        player.currentItem?.add(output)
    }

    func capture() async throws -> FilePreviewCapture.Snapshot {
        guard let player, let item = player.currentItem, item.status == .readyToPlay,
              item.outputs.contains(output), item.presentationSize.width > 0 else {
            throw FileBrowserError.message("Play the video until a frame is visible, then annotate it.")
        }
        player.pause()
        let time = player.currentTime()
        var displayedTime = CMTime.invalid
        guard let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayedTime) else {
            if let previous, CMTimeCompare(previous.requestedTime, time) == 0 { return previous.snapshot }
            throw FileBrowserError.message("No video frame is ready. Play briefly and try again.")
        }
        let tracks = try await item.asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw FileBrowserError.message("This file has no video frame to annotate.") }
        let transform = try await track.load(.preferredTransform)
        try Task.checkCancellation()
        guard player.currentItem === item, CMTimeCompare(player.currentTime(), time) == 0 else { throw CancellationError() }
        let snapshot = try await Self.render(image: CIImage(cvPixelBuffer: pixels).transformed(by: transform),
                                             time: displayedTime.isValid ? displayedTime : time)
        try Task.checkCancellation()
        guard player.currentItem === item, CMTimeCompare(player.currentTime(), time) == 0 else { throw CancellationError() }
        previous = (time, snapshot)
        return snapshot
    }

    @concurrent private static func render(image original: CIImage, time: CMTime) async throws -> FilePreviewCapture.Snapshot {
        var image = original
        let scale = min(1, 2560 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent) else {
            throw FileBrowserError.message("Could not capture the video frame.")
        }
        let seconds = max(0, CMTimeGetSeconds(time))
        let detail = seconds.isFinite ? "Time \(Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2))))" : "Video frame"
        return .init(image: rendered, detail: detail)
    }
}
#endif
