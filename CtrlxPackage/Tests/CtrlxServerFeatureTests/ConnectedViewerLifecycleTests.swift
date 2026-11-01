#if os(macOS)
    import Dependencies
    import DependenciesTestSupport
    import Foundation
    import Testing
    import Vapor
    @testable import CtrlxCommon
    @testable import CtrlxEncryption
    @testable import CtrlxNetworking
    @testable import CtrlxServerFeature

    @Suite(
        "Connected viewer lifecycle",
        .dependency(SecretsService.inMemory()),
        .dependency(RelayCredentials.inMemory())
    )
    @MainActor
    struct ConnectedViewerLifecycleTests {
        @Test("Invalidation rejects work captured by an older connection")
        func connectionGenerationRejectsOldWork() {
            var generation = ConnectionGeneration()
            let old = generation.current

            generation.invalidate()

            #expect(!generation.isCurrent(old))
            #expect(generation.isCurrent(generation.current))
        }

        @Test("Terminal delivery requires both relay and viewer readiness")
        func terminalDeliveryRequiresViewerPresence() {
            #expect(
                ConnectedViewer.canSendTerminalStream(
                    relayConnected: true,
                    viewerConnected: true
                )
            )
            #expect(
                !ConnectedViewer.canSendTerminalStream(
                    relayConnected: true,
                    viewerConnected: false
                )
            )
            #expect(
                !ConnectedViewer.canSendTerminalStream(
                    relayConnected: false,
                    viewerConnected: true
                )
            )
        }

        @Test("A registered half-open Host socket is detected and reconnected")
        func registeredHalfOpenSocketTriggersReconnect() async throws {
            let upgrades = HostUpgradeCounter()
            let relay = try await RegisteringMuteHostRelay.start(countingUpgradesInto: upgrades)
            defer { relay.stop() }

            let e2eeService = try await E2EEService()
            let pairedViewer = PairedViewer(
                id: "test-pair",
                deviceName: "Test Viewer",
                partnerPublicKey: "",
                partnerPublicKeyId: ""
            )
            let connection = ConnectedViewer(
                pairedViewer: pairedViewer,
                e2eeService: e2eeService,
                pingIntervalSeconds: 1,
                pongTimeoutSeconds: 1
            )

            await connection.connect(
                serverURL: URL(string: "ws://127.0.0.1:\(relay.port)")!,
                deviceId: "host-device",
                deviceName: "Test Host",
                username: "tester",
                publicKey: "dGVzdC1wdWJsaWMta2V5",
                publicKeyId: "host-key-id"
            )
            defer { Task { await connection.disconnect() } }

            #expect(await waitUntil { connection.state.isConnected })
            #expect(await waitUntil { upgrades.value >= 1 })
            #expect(
                await waitUntil(timeout: .seconds(8)) { upgrades.value >= 2 },
                "Host keep-alive never detected the half-open socket"
            )
        }

        private func waitUntil(
            timeout: Duration = .seconds(4),
            _ condition: () async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return await condition()
        }
    }

    /// Registers each Host socket, then deliberately ignores its keep-alive pings.
    private struct RegisteringMuteHostRelay {
        let app: Application
        let port: Int

        static func start(countingUpgradesInto counter: HostUpgradeCounter) async throws -> Self {
            let app = try await Application.make(.testing)
            app.webSocket("api", "ws") { _, ws in
                counter.increment()
                ws.onBinary { ws, buffer in
                    let data = Data(buffer.readableBytesView)
                    guard
                        let message = try? JSONDecoder().decode(WebSocketMessage.self, from: data),
                        case .registerHost = message,
                        let response = try? JSONEncoder().encode(
                            WebSocketMessage.hostRegistered(HostRegisteredMessage(success: true))
                        )
                    else { return }

                    Task {
                        try? await ws.send(raw: response, opcode: .text)
                    }
                }
            }

            do {
                try await app.asyncBoot()
                try await app.server.start(address: .hostname("127.0.0.1", port: 0))
                guard let port = app.http.server.shared.localAddress?.port else {
                    await app.server.shutdown()
                    try await app.asyncShutdown()
                    throw HostRelayError.noPort
                }
                return Self(app: app, port: port)
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

    private enum HostRelayError: Error {
        case noPort
    }

    private final class HostUpgradeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
#endif
