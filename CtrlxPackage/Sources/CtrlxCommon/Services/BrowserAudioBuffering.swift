import CtrlxNetworking

/// Bounded capture delivery and Viewer jitter buffering at 48 kHz.
package enum BrowserAudioBuffering {
    package static let maximumFrames = 24_576 // 512 ms
    package static let maximumPlaybackFrames = 49_152 // 1024 ms, including pending decode
    package static let prebufferFrames = 24_576 // 512 ms

    package static func frames(in message: RemoteBrowserAudio) -> Int {
        message.packets.count * 1_024
    }
}
