import CtrlxNetworking
import Foundation
import Synchronization
import Testing
import VaporTesting
@testable import CtrlxExternalServerLib

extension EnvSerializedSuites {
    @Suite("Metered Relay transport", .serialized)
    struct RelayAccessTransportTests {
        @Test("Credentials cannot cross roles, devices or pairings; a rejected socket cannot replace a valid one")
        func scopesAndReplacement() async throws {
            try await withRelay { app, port in
                let service = try #require(app.relayAccess)
                let key = try await service.createAccount(name: "alice", monthlyBytes: 100_000)
                let (pair, host, viewer) = try await makePair(service: service, key: key.key, code: "ABC123")
                await app.pairingService.installPair(pair)
                let frames = WireFrames()
                let good = try await connect(port: port, pairID: pair.id, role: "viewer", device: "viewer", token: viewer, frames: frames)
                try #require(await wait { await app.connectionHub.isViewerConnected(pairId: pair.id) })
                let original = try #require(await app.connectionHub.getConnection(pairId: pair.id, deviceType: .viewer))
                let badFrames = WireFrames()
                let bad = try await connect(port: port, pairID: pair.id, role: "viewer", device: "viewer", token: host, frames: badFrames)
                #expect(await wait { bad.isClosed })
                let current = await app.connectionHub.getConnection(pairId: pair.id, deviceType: .viewer)
                #expect(current?.webSocket === original.webSocket)
                #expect(!good.isClosed)
                #expect(badFrames.failures().first?.code == .accessDenied)
                await #expect(throws: RelayAccessFailure.self) {
                    try await service.authenticate(viewer, pairID: "another", role: "viewer", deviceID: "viewer")
                }
                await #expect(throws: RelayAccessFailure.self) {
                    try await service.authenticate(viewer, pairID: pair.id, role: "viewer", deviceID: "another")
                }
                try await good.close()
            }
        }

        @Test("Bidirectional raw bytes are charged once; quota denial closes both peers, preserves pairing, and top-up permits reconnect")
        func transferAndTopUp() async throws {
            try await withRelay { app, port in
                let service = try #require(app.relayAccess)
                let raw = Data(#"{"type":"encrypted","payload":{"payload":{"ciphertext":"AQIDBA==","senderKeyId":"test","version":1}}}"#.utf8)
                let key = try await service.createAccount(name: "alice", monthlyBytes: Int64(raw.count * 2 + 1))
                let (pair, hostKey, viewerKey) = try await makePair(service: service, key: key.key, code: "DEF456")
                await app.pairingService.installPair(pair)
                let hostFrames = WireFrames()
                let viewerFrames = WireFrames()
                let host = try await connect(port: port, pairID: pair.id, role: "host", device: "host", token: hostKey, frames: hostFrames)
                let viewer = try await connect(port: port, pairID: pair.id, role: "viewer", device: "viewer", token: viewerKey, frames: viewerFrames)
                try #require(await wait { await app.connectionHub.isViewerConnected(pairId: pair.id) })
                try await host.send(raw: raw, opcode: .text)
                try #require(await wait { viewerFrames.encryptedCount == 1 })
                try await viewer.send(raw: raw, opcode: .text)
                try #require(await wait { hostFrames.encryptedCount == 1 })
                #expect(try await service.status(token: key.key).usedBytes == Int64(raw.count * 2))
                try await host.send(raw: raw, opcode: .text)
                #expect(await wait { host.isClosed && viewer.isClosed })
                #expect(viewerFrames.failures().first?.code == .quotaExceeded)
                #expect(viewerFrames.failures().first?.quota?.remainingBytes == 1)
                #expect(viewerFrames.encryptedCount == 1)
                #expect(await app.pairingService.getPair(pairId: pair.id)?.id == pair.id)
                let status = try await service.status(token: viewerKey)
                _ = try await service.addQuota(account: key.accountID, month: status.period, bytes: 1_000, requestID: "support", reason: "test")
                let retry = try await connect(port: port, pairID: pair.id, role: "viewer", device: "viewer", token: viewerKey, frames: WireFrames())
                #expect(await wait { await app.connectionHub.isViewerConnected(pairId: pair.id) })
                try await retry.close()
            }
        }

        @Test("HTTP status works at zero quota while unauthorized pair deletion is rejected")
        func httpPermissions() async throws {
            try await withRelay { app, port in
                let service = try #require(app.relayAccess)
                let key = try await service.createAccount(name: "alice", monthlyBytes: 0)
                let registration = PairingRegistration(
                    deviceId: "host",
                    deviceName: "Host",
                    pairingCode: "GHI789",
                    publicKey: "host-key",
                    publicKeyId: "host-id",
                    username: "tester"
                )
                let response = try await request(
                    port: port,
                    path: "/api/pairing/register",
                    method: "POST",
                    token: key.key,
                    body: JSONEncoder().encode(registration)
                )
                let result = try JSONDecoder().decode(PairingResponse.self, from: response.0)
                guard case let .registered(info) = result else { Issue.record("Expected registered pairing")
                    return
                }
                let token = try #require(info.relayCredential)
                let pendingResponse = try await request(port: port, path: "/api/pairing/\(info.pairId)/status", method: "GET", token: token)
                let pending = try JSONDecoder().decode(PairingStatus.self, from: pendingResponse.0)
                #expect(pending.valid)
                #expect(pending.pairingCompleted == false)
                let completion = PairingCompletion(pairingCode: "GHI789", deviceId: "viewer", deviceName: "Viewer", publicKey: "viewer-key", publicKeyId: "viewer-id")
                _ = try await request(port: port, path: "/api/pairing/complete", method: "POST", body: JSONEncoder().encode(completion))
                let completedResponse = try await request(port: port, path: "/api/pairing/\(info.pairId)/status", method: "GET", token: token)
                let completed = try JSONDecoder().decode(PairingStatus.self, from: completedResponse.0)
                #expect(completed.pairingCompleted == true)
                #expect(!completed.viewerConnected)
                let denied = try await request(port: port, path: "/api/pairing/\(info.pairId)", method: "DELETE")
                #expect(denied.1 == 401)
                let statusResponse = try await request(port: port, path: "/api/access/status", method: "GET", token: token)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let status = try decoder.decode(RelayAccessStatus.self, from: statusResponse.0)
                #expect(status.quota?.remainingBytes == 0)
                #expect(status.failure == nil)
                #expect(statusResponse.2 == "no-store")
                let wrongRole = try await request(port: port, path: "/api/access/status?role=account", method: "GET", token: token)
                #expect(try decoder.decode(RelayAccessStatus.self, from: wrongRole.0).failure?.code == .accessDenied)
                let accountStatus = try await request(port: port, path: "/api/access/status?role=account", method: "GET", token: key.key)
                #expect(try decoder.decode(RelayAccessStatus.self, from: accountStatus.0).quota?.accountID == key.accountID)
                let allowed = try await request(port: port, path: "/api/pairing/\(info.pairId)", method: "DELETE", token: token)
                #expect(allowed.1 == 204)
                await #expect(throws: RelayAccessFailure.self) { try await service.status(token: token) }
            }
        }

        @Test("Anonymous status flooding cannot throttle an authenticated account behind the same proxy")
        func statusLimitIsolation() async throws {
            try await withRelay { app, port in
                let service = try #require(app.relayAccess)
                let key = try await service.createAccount(name: "valid", monthlyBytes: 100)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                for _ in 0..<240 {
                    _ = try await request(port: port, path: "/api/access/status", method: "GET")
                }
                let denied = try await request(port: port, path: "/api/access/status", method: "GET")
                #expect(try decoder.decode(RelayAccessStatus.self, from: denied.0).failure?.code == .rateLimited)
                let allowed = try await request(port: port, path: "/api/access/status", method: "GET", token: key.key)
                #expect(try decoder.decode(RelayAccessStatus.self, from: allowed.0).quota?.accountID == key.accountID)
            }
        }

        @Test("Closing a Viewer while its ledger work is queued does not reject the healthy Host")
        func cancelledLedgerWork() async throws {
            try await withRelay { app, port in
                let service = try #require(app.relayAccess)
                let key = try await service.createAccount(name: "cancel", monthlyBytes: 100_000)
                let (pair, hostKey, viewerKey) = try await makePair(service: service, key: key.key, code: "CAN123")
                await app.pairingService.installPair(pair)
                let frames = WireFrames()
                let host = try await connect(port: port, pairID: pair.id, role: "host", device: "host", token: hostKey, frames: frames)
                let viewer = try await connect(port: port, pairID: pair.id, role: "viewer", device: "viewer", token: viewerKey, frames: WireFrames())
                try #require(await wait {
                    let hostConnected = await app.connectionHub.isHostConnected(pairId: pair.id)
                    let viewerConnected = await app.connectionHub.isViewerConnected(pairId: pair.id)
                    return hostConnected && viewerConnected
                })
                let gate = LedgerGate()
                defer { gate.release() }
                let held = Task { try await service.perform { _ in gate.block() } }
                for await _ in gate.entered.stream {
                    break
                }
                try await viewer.send(#"{"type":"ping"}"#)
                try await Task.sleep(for: .milliseconds(100))
                try await viewer.close()
                // The queued pool job must drain before its cancelled caller
                // can finish unregistering the socket.
                gate.release()
                try await held.value
                try #require(await wait { await !app.connectionHub.isViewerConnected(pairId: pair.id) })
                try await host.send(#"{"type":"ping"}"#)
                #expect(await wait { frames.pongCount > 0 || host.isClosed })
                #expect(!host.isClosed)
                #expect(frames.failures().isEmpty)
                #expect(await app.connectionHub.isHostConnected(pairId: pair.id))
                try await host.close()
            }
        }

        @Test("A late rejection from a replaced socket cannot close its replacement or peer")
        func staleAccessRejection() async throws {
            try await withRelay { app, port in
                let service = try #require(app.relayAccess)
                let key = try await service.createAccount(name: "stale", monthlyBytes: 100_000)
                let (pair, hostKey, viewerKey) = try await makePair(service: service, key: key.key, code: "STA123")
                await app.pairingService.installPair(pair)
                let host = try await connect(port: port, pairID: pair.id, role: "host", device: "host", token: hostKey, frames: WireFrames())
                let old = try await connect(port: port, pairID: pair.id, role: "viewer", device: "viewer", token: viewerKey, frames: WireFrames())
                try #require(await wait { await app.connectionHub.isViewerConnected(pairId: pair.id) })
                let source = try #require(await app.connectionHub.getConnection(pairId: pair.id, deviceType: .viewer))
                let replacement = try await connect(port: port, pairID: pair.id, role: "viewer", device: "viewer", token: viewerKey, frames: WireFrames())
                try #require(await wait { old.isClosed })
                await app.connectionHub.rejectAccess(.init(code: .unavailable, message: "late failure"), pairID: pair.id, accountID: key.accountID, sourceWebSocket: source.webSocket)
                #expect(!host.isClosed && !replacement.isClosed)
                #expect(await app.connectionHub.isHostConnected(pairId: pair.id))
                #expect(await app.connectionHub.isViewerConnected(pairId: pair.id))
                try await replacement.close()
                try await host.close()
            }
        }

        @Test("Queued badge and alert push bodies consume the shared allowance and are not sent after denial")
        func pushAdmission() async throws {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-quota-push-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: log) }
            try await withRelay(env: ["APNS_E2E_LOG_PATH": log.path]) { app, port in
                let service = try #require(app.relayAccess)
                let key = try await service.createAccount(name: "push", monthlyBytes: 100_000)
                var (pair, hostKey, _) = try await makePair(service: service, key: key.key, code: "PUS123")
                pair.pushToken = "disposable-push-token"
                await app.pairingService.installPair(pair)
                let frames = WireFrames()
                let host = try await connect(port: port, pairID: pair.id, role: "host", device: "host", token: hostKey, frames: frames)
                try #require(await wait { await app.connectionHub.isHostConnected(pairId: pair.id) })
                try await app.injectE2EPush(pairId: pair.id, hostBadge: 1, silent: true)
                try #require(await wait { (try? String(contentsOf: log, encoding: .utf8).split(separator: "\n").count) == 1 })
                let badge = try await service.status(token: key.key)
                #expect(badge.usedBytes > 0)
                try await app.injectE2EPush(pairId: pair.id, hostBadge: 2, silent: false)
                try #require(await wait { (try? String(contentsOf: log, encoding: .utf8).split(separator: "\n").count) == 2 })
                let alert = try await service.status(token: key.key)
                #expect(alert.usedBytes > badge.usedBytes)
                let principal = try await service.authenticate(hostKey)
                _ = try await service.admit(principal, bytes: Int(alert.remainingBytes - 1))
                try await app.injectE2EPush(pairId: pair.id, hostBadge: 3, silent: true)
                #expect(try await service.status(token: key.key).remainingBytes == 1)
                #expect(await wait { host.isClosed })
                #expect(frames.failures().first?.code == .quotaExceeded)
                let records = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                    try JSONDecoder().decode(APNsPushLogEntry.self, from: Data($0.utf8))
                }
                #expect(records.count == 2)
                #expect(records.map(\.pushType) == ["alert", "alert"])
            }
        }

        private func withRelay(env: [String: String] = [:], _ body: (Application, Int) async throws -> Void) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-metered-transport-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let app = try await Application.make(.testing)
            do {
                try await configure(app, env: ["RELAY_ACCESS_MODE": "metered", "DATA_DIRECTORY": directory.path].merging(env) { _, value in value })
                app.http.server.configuration.hostname = "127.0.0.1"
                app.http.server.configuration.port = 0
                try await app.server.start()
                let port = try #require(app.http.server.shared.localAddress?.port)
                try await body(app, port)
                await app.server.shutdown()
                try await app.asyncShutdown()
            } catch {
                await app.server.shutdown()
                try await app.asyncShutdown()
                throw error
            }
        }

        private func makePair(service: RelayAccessService, key: String, code: String) async throws -> (Pair, String, String) {
            let host = try await service.register(PairingRegistration(
                deviceId: "host",
                deviceName: "Host",
                pairingCode: code,
                publicKey: "host-key",
                publicKeyId: "host-id",
                username: "tester"
            ), token: key)
            let (pair, viewer) = try await service.complete(PairingCompletion(
                pairingCode: code,
                deviceId: "viewer",
                deviceName: "Viewer",
                publicKey: "viewer-key",
                publicKeyId: "viewer-id"
            ))
            return try (pair, #require(host.relayCredential), #require(viewer.relayCredential))
        }

        private func connect(port: Int, pairID: String, role: String, device: String, token: String, frames: WireFrames) async throws -> WebSocket {
            let (stream, continuation) = AsyncThrowingStream<WebSocket, any Error>.makeStream()
            WebSocket.connect(
                to: "ws://127.0.0.1:\(port)/api/ws?pairId=\(pairID)&deviceType=\(role)&deviceId=\(device)",
                headers: ["Authorization": "Bearer \(token)"],
                on: MultiThreadedEventLoopGroup.singleton
            ) { socket in
                socket.onText { _, text in frames.append(text) }
                continuation.yield(socket)
                continuation.finish()
            }.whenFailure { continuation.finish(throwing: $0) }
            var iterator = stream.makeAsyncIterator()
            return try #require(try await iterator.next())
        }

        private func request(port: Int, path: String, method: String, token: String? = nil, body: Data? = nil) async throws -> (Data, Int, String?) {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            }
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            return (data, http.statusCode, http.value(forHTTPHeaderField: "Cache-Control"))
        }

        private func wait(_ condition: () async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if await condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return await condition()
        }
    }
}

final private class WireFrames: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ text: String) {
        storage.withLock { $0.append(text) }
    }

    var encryptedCount: Int {
        storage.withLock { $0.filter { $0.contains("\"type\":\"encrypted\"") }.count }
    }

    var pongCount: Int {
        storage.withLock { $0.filter { $0.contains("\"type\":\"pong\"") }.count }
    }

    func failures() -> [RelayAccessFailure] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return storage.withLock { texts in
            texts.compactMap {
                guard
                    let message = try? decoder.decode(WebSocketMessage.self, from: Data($0.utf8)),
                    case let .error(error) = message else { return nil }
                return error.relayAccess
            }
        }
    }
}

/// Blocks only the dedicated ledger pool thread, leaving the network responsive.
final private class LedgerGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let condition = NSCondition()
    private var released = false

    func block() {
        condition.lock()
        defer { condition.unlock() }
        entered.continuation.yield()
        entered.continuation.finish()
        while !released {
            condition.wait()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
