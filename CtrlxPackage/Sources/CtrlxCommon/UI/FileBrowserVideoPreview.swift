#if os(macOS) || os(iOS)
import AVKit
import SwiftUI

@MainActor
struct FileBrowserVideoPreview: View {
    let path: String
    let source: FileBrowserSource
    @State private var started = false
    @State private var playback = FileBrowserVideoPlayback()
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            if let message = error ?? playback.error {
                Text(message).padding().textSelection(.enabled)
            } else if let player = playback.player {
                FileBrowserVideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if playback.isBuffering { ProgressView("Buffering Video").padding(8) }
                    }
            } else if started {
                ProgressView("Loading Video")
                Button("Cancel", role: .cancel) { started = false; playback.stop() }
            } else {
                Button { started = true } label: { Label("Play Video", symbol: .playFill) }
                    .disabled(source.unavailableReason != nil || source.downloadUnavailableReason != nil)
                Text(source.unavailableReason ?? source.downloadUnavailableReason ?? "Plays from the Host without downloading the entire file.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: started) {
            guard started, scenePhase == .active else { return }
            do {
                try await playback.prepare(path: path, source: source)
                try Task.checkCancellation()
                playback.play()
            } catch is CancellationError {
                // Lifecycle handlers own cleanup; an old task must not stop a newer attempt.
                return
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { started = false; playback.stop() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            playback.setSceneActive(phase == .active)
            if phase != .active, playback.player == nil { started = false }
        }
    }
}

#if os(macOS)
@MainActor
private struct FileBrowserVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
#else
@MainActor
private struct FileBrowserVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
#endif
#endif
