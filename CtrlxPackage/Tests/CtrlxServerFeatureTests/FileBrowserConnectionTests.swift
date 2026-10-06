import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
import Vapor
@testable import CtrlxServerFeature

@MainActor
@Suite("File requests across Viewer reconnects", .serialized)
struct FileBrowserConnectionTests {
    @Test func viewerDisconnectFreesSlotsBeforeOldIOFinishes() async throws {
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.43"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws", maxFrameSize: .init(integerLiteral: RelayPayloadLimits.maxWebSocketFrameBytes)) { _, ws in
            ws.onBinary { ws, bytes in
                let data = Data(bytes.readableBytesView)
                Task { await relay.receive(data, from: ws) }
            }
            ws.onClose.whenComplete { _ in Task { await relay.closed(ws) } }
        }
        try await app.asyncBoot()
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            let port = try #require(app.http.server.shared.localAddress?.port)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
            let hostEncryption = try await encryption(), viewerEncryption = try await encryption()
            let host = ConnectedViewer(
                pairedViewer: .init(id: "pair", deviceName: "Viewer",
                                    partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(),
                                    partnerPublicKeyId: viewerEncryption.keyId),
                e2eeService: hostEncryption
            )
            let viewer = ViewerRelayClient()
            var waiters: [CheckedContinuation<Void, Never>] = []
            var finishedCancelled: [Bool] = []
            let downloadsEnabled = LockIsolated(false)
            defer { for waiter in waiters { waiter.resume() } }
            host.onSessionStateRequest = {
                .init(pairId: "", paneStates: [:], supportsFileBrowsing: true, supportsFileDownloads: downloadsEnabled.value ? true : nil)
            }
            host.onCommand = { command in
                if case let .browseFiles(spec) = command.command,
                   case let .info(path) = spec.operation, path.hasPrefix("/old/") {
                    // Simulates I/O that cannot finish immediately on cancellation.
                    await withCheckedContinuation { waiters.append($0) }
                    finishedCancelled.append(Task.isCancelled)
                }
                if case let .browseFiles(spec) = command.command,
                   case let .download(path, offset, revision) = spec.operation {
                    return .init(commandId: command.id, success: true,
                                 fileBrowser: .chunk(.init(path: path, revision: revision, offset: offset,
                                                          data: Data(repeating: 7, count: FileBrowserLimits.chunkBytes))))
                }
                return .success(for: command.id)
            }
            await host.connect(serverURL: url, deviceId: "host", deviceName: "Host", username: "test",
                               publicKey: hostEncryption.publicKey.base64EncodedString(), publicKeyId: hostEncryption.keyId)
            do {
                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { host.isViewerConnected && viewer.hostSupportsFileBrowsing }
                let frameCount = await relay.encryptedFrames
                let started = ContinuousClock.now
                let unsupported = await viewer.sendCommand(BrowseFiles(.download(path: "/movie.mp4", offset: 0, revision: "1")), paneId: "%7")
                if case .success = unsupported { Issue.record("Legacy Host accepted a download") }
                #expect(ContinuousClock.now - started < .seconds(1))
                #expect(await relay.encryptedFrames == frameCount, "Do not send a new enum case to an old Host")
                downloadsEnabled.setValue(true)
                await host.pushSessionState()
                try await waitUntil { viewer.hostSupportsFileDownloads }
                let modern = await viewer.sendCommand(BrowseFiles(.download(path: "/movie.mp4", offset: 0, revision: "1")), paneId: "%7")
                if case let .chunk(chunk) = try modern.get().fileBrowser {
                    #expect(chunk.data == Data(repeating: 7, count: FileBrowserLimits.chunkBytes))
                } else { Issue.record("Missing encrypted file chunk") }
                let requests = (0..<4).map { index in
                    Task { await viewer.sendCommand(BrowseFiles(.info(path: "/old/\(index)")), paneId: "%7", timeout: 5) }
                }
                try await waitUntil { waiters.count == 4 }
                requests[0].cancel()
                let cancelled = await requests[0].value
                if case let .failure(error) = cancelled { #expect(error is CancellationError) }
                else { Issue.record("Cancelled request unexpectedly succeeded") }
                await viewer.disconnect()
                #expect(!viewer.hostSupportsFileDownloads)
                downloadsEnabled.setValue(false)
                try await waitUntil { !host.isViewerConnected }
                #expect(host.state.isConnected, "This must exercise peer disconnect, not Host socket cleanup")
                for request in requests { _ = await request.value }

                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { host.isViewerConnected && viewer.hostSupportsFileBrowsing }
                #expect(!viewer.hostSupportsFileDownloads)
                let result = await viewer.sendCommand(BrowseFiles(.info(path: "/new")), paneId: "%7", timeout: 5)
                #expect(try result.get().success, "Old requests must not retain the four slots after reconnect")
                #expect(finishedCancelled.isEmpty, "New work must enter before old I/O finishes")
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
                try await waitUntil { finishedCancelled.count == 4 }
                #expect(finishedCancelled.allSatisfy { $0 })
                #expect(await relay.errors.isEmpty)
                #expect(await relay.unexpectedTypes.isEmpty)
            } catch {
                await viewer.disconnect()
                await host.disconnect()
                throw error
            }
            await viewer.disconnect()
            await host.disconnect()
        } catch {
            await app.server.shutdown()
            try await app.asyncShutdown()
            throw error
        }
        await app.server.shutdown()
        try await app.asyncShutdown()
    }

    private func connect(_ viewer: ViewerRelayClient, url: URL, encryption: E2EEService, hostEncryption: E2EEService) async {
        await viewer.connect(serverURL: url, pairId: "pair", deviceId: "viewer", deviceName: "Viewer",
                             publicKey: encryption.publicKey.base64EncodedString(), publicKeyId: encryption.keyId,
                             e2eeService: encryption, partnerPublicKey: hostEncryption.publicKey.base64EncodedString(),
                             partnerPublicKeyId: hostEncryption.keyId)
    }

    private func encryption() async throws -> E2EEService {
        try await withDependencies { $0[SecretsService.self] = .inMemory() } operation: { try await E2EEService() }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let met = await condition()
        try #require(met, "File-request connection state did not converge")
    }
}
