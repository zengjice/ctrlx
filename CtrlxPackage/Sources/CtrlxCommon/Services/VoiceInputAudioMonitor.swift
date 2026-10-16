#if os(iOS) || os(macOS)
    import AVFoundation
    import Foundation

    /// Engine notifications can arrive on an audio thread. Never tear down audio
    /// there, and ignore already queued notifications after normal stop/restart.
    @MainActor
    final class VoiceInputAudioMonitor {
        private let center: NotificationCenter
        private var observers: [NSObjectProtocol] = []
        private var generation: UUID?

        init(center: NotificationCenter = .default) {
            self.center = center
        }

        func start(engine: AVAudioEngine, onFailure: @escaping @MainActor @Sendable (String) -> Void) {
            stop()
            let id = UUID()
            generation = id
            observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
                Task { @MainActor in
                    guard let self, self.generation == id, let engine, !engine.isRunning else { return }
                    self.stop()
                    onFailure("The audio device changed and recording stopped. Please record again.")
                }
            })
            #if os(iOS)
                observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
                    guard
                        let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        type == AVAudioSession.InterruptionType.began.rawValue else { return }
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.stop()
                        onFailure("Recording was interrupted. Please record again.")
                    }
                })
            #endif
        }

        func stop() {
            generation = nil
            for observer in observers {
                center.removeObserver(observer)
            }
            observers.removeAll()
        }
    }
#endif
