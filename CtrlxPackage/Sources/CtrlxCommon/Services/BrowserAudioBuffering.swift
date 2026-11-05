import CtrlxNetworking

/// A time budget shared by capture delivery and Viewer playback at 48 kHz.
package enum BrowserAudioBuffering {
    package static let maximumFrames = 24_576 // 512 ms
    package static let prebufferFrames = 12_288 // 256 ms

    package static func frames(in message: RemoteBrowserAudio) -> Int {
        message.packets.count * 1_024
    }
}
