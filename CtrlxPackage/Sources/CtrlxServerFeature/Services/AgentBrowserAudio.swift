import CtrlxBrowserBridge
import CtrlxCommon
import CtrlxNetworking
import Foundation

struct BrowserAudioStream {
    let id: UUID
    let lease: BrowserControlLease
    var task: Task<Void, Never>?
}

@MainActor
extension AgentBrowserService {
    var supportsBrowserAudio: Bool {
        guard let runtime else { return true }
        return runtime.responds(to: #selector(CXBrowserRuntime.setBrowserAudioForTab(_:controlToken:enabled:)))
            && runtime.responds(to: #selector(CXBrowserRuntime.readBrowserAudio(forTab:controlToken:completion:)))
    }

    func stopBrowserAudio(_ tabID: UUID) {
        guard let stream = browserAudioStreams.removeValue(forKey: tabID) else { return }
        stream.task?.cancel()
        _ = runtime?.setBrowserAudioForTab?(tabID.uuidString, controlToken: stream.lease.id.uuidString, enabled: false)
    }

    func configureBrowserAudio(tabID: UUID, lease: BrowserControlLease, streamID: UUID, revision: UInt64, enabled: Bool) throws {
        guard supportsBrowserAudio, let runtime, sendBrowserAudio != nil else {
            throw RemoteBrowserError.message("Update the Host Mac to receive page sound.")
        }
        guard revision > (browserAudioRevisions[tabID] ?? 0) else { return }
        browserAudioRevisions[tabID] = revision
        // A Viewer has one active audible page even when multiple windows remain mounted.
        for (id, stream) in browserAudioStreams where id == tabID || (enabled && stream.lease.viewerID == lease.viewerID) {
            stopBrowserAudio(id)
        }
        guard runtime.setBrowserAudioForTab?(tabID.uuidString, controlToken: lease.id.uuidString, enabled: enabled) == true else {
            throw RemoteBrowserError.message("Browser audio control expired.")
        }
        browserAudioStreams[tabID] = BrowserAudioStream(id: streamID, lease: lease)
        guard enabled else { return }
        browserAudioStreams[tabID]?.task = Task { [weak self] in
            let encoder = BrowserAudioCodec()
            var sequence: UInt64 = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                    guard
                        let self, self.browserAudioStreams[tabID]?.id == streamID,
                        let current = self.remoteControls[tabID], current.id == lease.id, current.expires > .now else { return }
                    let pcm: Data = try await withCheckedThrowingContinuation { continuation in
                        runtime.readBrowserAudio?(forTab: tabID.uuidString, controlToken: lease.id.uuidString) { data, error in
                            if let error {
                                continuation.resume(throwing: RemoteBrowserError.message(error))
                            } else if let data {
                                continuation.resume(returning: data)
                            } else {
                                continuation.resume(throwing: RemoteBrowserError.message("The Host returned no browser audio."))
                            }
                        }
                    }
                    guard !pcm.isEmpty else { continue }
                    let encoded = try await encoder.encode(pcm)
                    guard
                        !Task.isCancelled, self.browserAudioStreams[tabID]?.id == streamID,
                        self.remoteControls[tabID]?.id == lease.id, !encoded.packets.isEmpty else { continue }
                    sequence += 1
                    let message = RemoteBrowserAudio(
                        tabID: tabID,
                        surfaceID: lease.surfaceID,
                        controlID: lease.id,
                        streamID: streamID,
                        sequence: sequence,
                        packets: encoded.packets,
                        magicCookie: encoded.cookie
                    )
                    guard message.isValid else { throw RemoteBrowserError.message("Browser audio exceeded the stream limit.") }
                    await self.sendBrowserAudio?(lease.viewerID, message)
                } catch {
                    guard !Task.isCancelled, let self, self.browserAudioStreams[tabID]?.id == streamID else { return }
                    let message = RemoteBrowserAudio(
                        tabID: tabID,
                        surfaceID: lease.surfaceID,
                        controlID: lease.id,
                        streamID: streamID,
                        sequence: sequence + 1,
                        packets: [],
                        error: String(error.localizedDescription.prefix(120))
                    )
                    await self.sendBrowserAudio?(lease.viewerID, message)
                    if self.browserAudioStreams[tabID]?.id == streamID {
                        self.stopBrowserAudio(tabID)
                    }
                    return
                }
            }
        }
    }
}
