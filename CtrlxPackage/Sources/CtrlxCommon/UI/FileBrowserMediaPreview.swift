#if os(macOS)
import AVKit
import SwiftUI

/// Keep AVKit's native controls; SwiftUI VideoPlayer previously crashed in the
/// Host file viewer. Releasing the tab must stop playback and file access.
@MainActor
struct FileBrowserMediaPreview: NSViewRepresentable {
    let url: URL
    let capture: FilePreviewCapture

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        registerCapture(view.player, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
            registerCapture(view.player, coordinator: context.coordinator)
        }
    }

    private func registerCapture(_ player: AVPlayer?, coordinator: Coordinator) {
        guard let player else { return }
        let video = FilePreviewVideoCapture(player: player)
        coordinator.video = video
        capture.bind(owner: coordinator.owner) { try await video.capture() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        let owner = UUID()
        var video: FilePreviewVideoCapture?
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.video = nil
    }
}
#endif
