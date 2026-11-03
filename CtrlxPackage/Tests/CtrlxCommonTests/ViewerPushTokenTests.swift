import CtrlxNetworking
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing
import Vapor
@testable import CtrlxCommon
@testable import CtrlxEncryption

@Suite(
    "Viewer push token delivery",
    .dependency(SecretsService.inMemory()),
    .dependency(RelayCredentials.inMemory())
)
@MainActor
struct ViewerPushTokenTests {
    @Test("A token received before connecting is delivered after registration")
    func tokenBeforeConnection() async throws {
        let relay = try await PushTokenRelay.start()
        defer { relay.stop() }
        let client = ViewerRelayClient()
        defer { Task { await client.disconnect() } }

        await client.sendPushToken("early-token")
        try await connect(client, to: relay)
        #expect(await waitUntil { relay.recorder.tokens.contains("early-token") })
        #expect(relay.recorder.prematureTokens == 0)
    }

    @Test("A late APNs callback delivers its token on the existing connection")
    func tokenAfterConnection() async throws {
        let relay = try await PushTokenRelay.start()
        defer { relay.stop() }
        let client = ViewerRelayClient()
        defer { Task { await client.disconnect() } }

        try await connect(client, to: relay)
        #expect(await waitUntil { relay.recorder.acknowledgements > 0 })
        await client.sendPushToken("late-token")
        #expect(await waitUntil { relay.recorder.tokens.contains("late-token") })
    }

    @Test("Push registration waits for the Relay's viewer-registration acknowledgement")
    func tokenWaitsForRegistration() async throws {
        let relay = try await PushTokenRelay.start(acknowledge: false)
        defer { relay.stop() }
        let client = ViewerRelayClient()
        defer { Task { await client.disconnect() } }

        try await connect(client, to: relay)
        #expect(await waitUntil { client.state.isConnected })
        await client.sendPushToken("queued-token")
        let sentEarly = await waitUntil(timeout: .milliseconds(150)) {
            !relay.recorder.tokens.isEmpty
        }
        #expect(!sentEarly)
        relay.recorder.enableAcknowledgements()
        await client.reconnectImmediately()
        #expect(await waitUntil { relay.recorder.tokens.contains("queued-token") })
        #expect(relay.recorder.prematureTokens == 0)
    }

    @Test("Reconnection registers the latest token, including rotation while disconnected")
    func latestTokenSurvivesReconnect() async throws {
        let relay = try await PushTokenRelay.start()
        defer { relay.stop() }
        let client = ViewerRelayClient()
        defer { Task { await client.disconnect() } }

        try await connect(client, to: relay)
        await client.sendPushToken("old-token")
        #expect(await waitUntil { relay.recorder.tokens.contains("old-token") })
        await client.disconnect()
        await client.sendPushToken("new-token")
        try await connect(client, to: relay)
        #expect(await waitUntil { relay.recorder.latestConnectionTokens.contains("new-token") })
        #expect(relay.recorder.latestConnectionTokens.allSatisfy { $0 == "new-token" })
        #expect(relay.recorder.prematureTokens == 0)
    }

    private func connect(_ client: ViewerRelayClient, to relay: PushTokenRelay) async throws {
        let encryption = try await withDependencies {
            $0[SecretsService.self] = .inMemory()
        } operation: {
            try await E2EEService()
        }
        await client.connect(
            serverURL: URL(string: "ws://127.0.0.1:\(relay.port)")!,
            pairId: "push-test-pair",
            deviceId: "push-test-viewer",
            deviceName: "Test Viewer",
            publicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            publicKeyId: "test-key",
            e2eeService: encryption,
            partnerPublicKey: nil,
            partnerPublicKeyId: nil
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}

private struct PushTokenRelay {
    let app: Application
    let port: Int
    let recorder: PushTokenRecorder

    static func start(acknowledge: Bool = true) async throws -> PushTokenRelay {
        let recorder = PushTokenRecorder(acknowledge: acknowledge)
        let acknowledgement = try JSONEncoder().encode(
            WebSocketMessage.viewerRegistered(ViewerRegisteredMessage(success: true))
        )
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws") { _, socket in
            let connection = recorder.openConnection()
            socket.onText { _, text in
                if recorder.receive(Data(text.utf8), connection: connection) {
                    socket.send(String(decoding: acknowledgement, as: UTF8.self))
                }
            }
            socket.onBinary { _, buffer in
                if recorder.receive(Data(buffer.readableBytesView), connection: connection) {
                    socket.send(String(decoding: acknowledgement, as: UTF8.self))
                }
            }
        }
        do {
            try await app.asyncBoot()
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            guard let port = app.http.server.shared.localAddress?.port else {
                throw URLError(.cannotConnectToHost)
            }
            return PushTokenRelay(app: app, port: port, recorder: recorder)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    func stop() {
        let app = app
        Task {
            await app.server.shutdown()
            try? await app.asyncShutdown()
        }
    }
}

final private class PushTokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledge: Bool
    private var connectionCount = 0
    private var acknowledgedConnections: Set<Int> = []
    private var receivedTokens: [(connection: Int, token: String)] = []
    private var prematureCount = 0

    init(acknowledge: Bool) {
        self.acknowledge = acknowledge
    }

    func openConnection() -> Int {
        lock.withLock {
            connectionCount += 1
            return connectionCount
        }
    }

    func enableAcknowledgements() {
        lock.withLock { acknowledge = true }
    }

    func receive(_ data: Data, connection: Int) -> Bool {
        guard let message = try? JSONDecoder().decode(WebSocketMessage.self, from: data) else { return false }
        return lock.withLock {
            switch message {
            case .registerViewer:
                guard acknowledge else { return false }
                acknowledgedConnections.insert(connection)
                return true
            case let .registerPushToken(registration):
                receivedTokens.append((connection, registration.deviceToken))
                if !acknowledgedConnections.contains(connection) {
                    prematureCount += 1
                }
                return false
            default:
                return false
            }
        }
    }

    var tokens: [String] {
        lock.withLock { receivedTokens.map(\.token) }
    }

    var latestConnectionTokens: [String] {
        lock.withLock { receivedTokens.filter { $0.connection == connectionCount }.map(\.token) }
    }

    var acknowledgements: Int {
        lock.withLock { acknowledgedConnections.count }
    }

    var prematureTokens: Int {
        lock.withLock { prematureCount }
    }
}
