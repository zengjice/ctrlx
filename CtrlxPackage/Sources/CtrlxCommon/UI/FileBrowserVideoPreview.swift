#if os(macOS) || os(iOS)
    import AVKit
    import SwiftUI

    @MainActor
    struct FileBrowserVideoPreview: View {
        let path: String
        let source: FileBrowserSource
        let capture: FilePreviewCapture
        let playback: FileBrowserVideoPlayback
        let position: FileBrowserPreviewPosition
        @State private var started: Bool
        @State private var requestedPlay = false
        @State private var error: String?
        @State private var captureOwner = UUID()
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.fileBrowserPreviewIsActive) private var isActive

        init(path: String, source: FileBrowserSource, capture: FilePreviewCapture, playback: FileBrowserVideoPlayback, position: FileBrowserPreviewPosition) {
            self.path = path
            self.source = source
            self.capture = capture
            self.playback = playback
            self.position = position
            _started = State(initialValue: position.videoWasOpened)
        }

        var body: some View {
            VStack(spacing: 8) {
                if let message = error ?? playback.error {
                    Text(message).padding().textSelection(.enabled)
                } else if let player = playback.player {
                    FileBrowserVideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .top) {
                            if playback.isBuffering {
                                ProgressView("Buffering Video").padding(8)
                            }
                        }
                    #if os(iOS)
                        Button(action: playback.toggleSound) {
                            Label(
                                playback.isMuted ? "Enable Sound" : "Mute",
                                symbol: playback.isMuted ? .speakerSlashFill : .speakerWave2Fill
                            )
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityValue(playback.isMuted ? "Muted" : "Sound On")
                        .padding(.bottom, 8)
                    #endif
                } else if started {
                    ProgressView("Loading Video")
                    Button("Cancel", role: .cancel) { started = false
                        playback.stop()
                    }
                } else {
                    Button { requestedPlay = true
                        started = true
                    } label: { Label("Play Video", symbol: .playFill) }
                        .disabled(source.unavailableReason != nil || source.downloadUnavailableReason != nil)
                    Text(source.unavailableReason ?? source.downloadUnavailableReason ?? "Plays from the Host without downloading the entire file.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                    #if os(iOS)
                        Text("Starts muted. Tap Enable Sound to hear audio.")
                            .font(.caption).foregroundStyle(.secondary)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: started && isActive && scenePhase == .active) {
                guard started, isActive, scenePhase == .active else { return }
                do {
                    playback.setSceneActive(true)
                    if playback.player == nil {
                        try await playback.prepare(path: path, source: source, position: position)
                        position.videoWasOpened = true
                    }
                    if let seconds = playback.restorationSeconds, seconds > 0 {
                        try await playback.restore(seconds: seconds)
                    }
                    try Task.checkCancellation()
                    if let video = playback.annotationCapture {
                        capture.bind(owner: captureOwner) { try await video.capture() }
                    }
                    if requestedPlay {
                        playback.play()
                        requestedPlay = false
                    }
                } catch is CancellationError {
                    // Lifecycle handlers own cleanup; an old task must not stop a newer attempt.
                    return
                } catch {
                    if !Task.isCancelled {
                        self.error = error.localizedDescription
                    }
                }
            }
            .onDisappear { requestedPlay = false }
            .onChange(of: isActive) { _, active in
                playback.setSceneActive(active && scenePhase == .active)
                if !active {
                    requestedPlay = false
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                playback.setSceneActive(phase == .active && isActive)
                if phase != .active {
                    requestedPlay = false
                }
                if phase != .active, playback.player == nil {
                    started = false
                }
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
                if view.player !== player {
                    view.player = player
                }
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
                if controller.player !== player {
                    controller.player = player
                }
            }

            static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
                controller.player?.pause()
                controller.player = nil
            }
        }
    #endif
#endif
