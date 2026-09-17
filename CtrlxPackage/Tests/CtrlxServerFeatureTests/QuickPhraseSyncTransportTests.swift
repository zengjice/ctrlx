import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
import Vapor
@testable import CtrlxServerFeature

@MainActor
@Suite("Quick phrases over real encrypted WebSockets")
struct QuickPhraseSyncTransportTests {
    @Test("Host and shared iOS/Mac viewer exchange libraries without plaintext or terminal commands")
    func transport() async throws {
        // SPM's test runner has no CFBundleShortVersionString. Use the existing
        // E2E override so the real clients' compatibility gate remains enabled.
        let originalVersion = VersionCompatibility.appVersionOverride
        VersionCompatibility.appVersionOverride = "3.0.24"
        defer { VersionCompatibility.appVersionOverride = originalVersion }
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws") { _, ws in
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
            let hostStore = library(), viewerStore = library()
            hostStore.updateSyncPairings([.init(pairID: "pair", name: "Viewer", publicKey: viewerEncryption.publicKey.base64EncodedString())])
            viewerStore.updateSyncPairings([.init(pairID: "pair", name: "Host", publicKey: hostEncryption.publicKey.base64EncodedString())])
            try hostStore.add("Mac-only secret")
            try viewerStore.add("iPhone-only secret")
            let host = ConnectedViewer(
                pairedViewer: .init(id: "pair", deviceName: "Viewer",
                                    partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(),
                                    partnerPublicKeyId: viewerEncryption.keyId),
                e2eeService: hostEncryption
            )
            let viewer = ViewerRelayClient()
            host.configureQuickPhraseSync(store: hostStore)
            viewer.configureQuickPhraseSync(store: viewerStore, pairID: "pair")
            await host.connect(serverURL: url, deviceId: "host", deviceName: "Host", username: "test",
                               publicKey: hostEncryption.publicKey.base64EncodedString(), publicKeyId: hostEncryption.keyId)
            await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
            do {
                try await waitUntil { host.isViewerConnected && viewer.isHostConnected }
                #expect(hostStore.phrases.count == 1)
                #expect(viewerStore.phrases.count == 1)
                hostStore.setSyncEnabled(true, for: "pair")
                viewerStore.setSyncEnabled(true, for: "pair")
                try await waitUntil { hostStore.phrases.count == 2 && hostStore.phrases == viewerStore.phrases }
                #expect(hostStore.syncStatus(for: hostStore.syncDevices[0].id) == .ready)
                #expect(viewerStore.syncStatus(for: viewerStore.syncDevices[0].id) == .ready)
                try viewerStore.add("live addition")
                try await waitUntil { hostStore.phrases.count == 3 }
                await viewer.disconnect()
                try await waitUntil { !host.isViewerConnected }
                #expect(hostStore.syncStatus(for: hostStore.syncDevices[0].id) == .offline)
                try hostStore.remove(hostStore.phrases[0].id)
                try viewerStore.add("offline addition")
                await connect(viewer, url: url, encryption: viewerEncryption, hostEncryption: hostEncryption)
                try await waitUntil { hostStore.records == viewerStore.records && hostStore.phrases.count == 3 }
                #expect(await relay.encryptedFrames > 0)
                #expect(await relay.unexpectedTypes.isEmpty)
                #expect(await relay.errors.isEmpty)
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

    private func encryption() async throws -> E2EEService {
        try await withDependencies { $0[SecretsService.self] = .inMemory() } operation: { try await E2EEService() }
    }

    private func library() -> QuickPhraseStore {
        withDependencies { $0[PreferencesService.self] = .inMemory() } operation: { QuickPhraseStore() }
    }

    private func connect(_ viewer: ViewerRelayClient, url: URL, encryption: E2EEService, hostEncryption: E2EEService) async {
        await viewer.connect(serverURL: url, pairId: "pair", deviceId: "viewer", deviceName: "Viewer",
                             publicKey: encryption.publicKey.base64EncodedString(), publicKeyId: encryption.keyId,
                             e2eeService: encryption, partnerPublicKey: hostEncryption.publicKey.base64EncodedString(),
                             partnerPublicKeyId: hostEncryption.keyId)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Encrypted sync did not converge")
    }
}

/// A deliberately content-blind relay: only registration and encrypted envelopes
/// are understood. It cannot decode a quickPhraseSync payload or execute input.
private actor PhraseTestRelay {
    var host: WebSocket?
    var viewer: WebSocket?
    var hostKey: ViewerConnectedMessage?
    var viewerKey: ViewerConnectedMessage?
    private(set) var encryptedFrames = 0
    private(set) var unexpectedTypes: [String] = []
    private(set) var errors: [String] = []

    func receive(_ data: Data, from ws: WebSocket) async {
        do {
            let message = try JSONDecoder().decode(WebSocketMessage.self, from: data)
            switch message {
            case let .registerHost(value):
                host = ws
                hostKey = .init(publicKey: value.publicKey, publicKeyId: value.publicKeyId)
                try await send(.hostRegistered(.init(success: true)), to: ws)
                try await notifyPeers()
            case let .registerViewer(value):
                viewer = ws
                viewerKey = .init(publicKey: value.publicKey, publicKeyId: value.publicKeyId)
                try await send(.viewerRegistered(.init(success: true)), to: ws)
                try await notifyPeers()
            case .encrypted:
                encryptedFrames += 1
                if let target = ws === host ? viewer : host {
                    try await target.send(raw: data, opcode: .binary)
                }
            case .requestSessionState:
                break
            case .ping:
                try await send(.pong, to: ws)
            default:
                unexpectedTypes.append(message.messageType)
            }
        } catch { errors.append(error.localizedDescription) }
    }

    func closed(_ ws: WebSocket) async {
        do {
            if ws === viewer {
                viewer = nil
                if let host, !host.isClosed { try await send(.viewerDisconnected, to: host) }
            } else if ws === host {
                host = nil
                if let viewer, !viewer.isClosed { try await send(.hostDisconnected, to: viewer) }
            }
        } catch { errors.append(error.localizedDescription) }
    }

    private func notifyPeers() async throws {
        guard let host, let viewer, let hostKey, let viewerKey else { return }
        try await send(.hostConnected(hostKey), to: viewer)
        try await send(.viewerConnected(viewerKey), to: host)
    }

    private func send(_ message: WebSocketMessage, to ws: WebSocket) async throws {
        try await ws.send(raw: JSONEncoder().encode(message), opcode: .binary)
    }
}
