#if os(macOS)
    import CtrlxCommon
    import CtrlxEncryption
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import SwiftTerm
    import Testing
    import Vapor
    @testable import CtrlxServerFeature

    @Suite("Ordered terminal stream transport", .serialized)
    @MainActor
    struct TerminalStreamTransportTests {
        @Test("Concurrent fan-out preserves Shell redraw bytes for every viewer", arguments: [1, 2, 7, 8_192])
        func shellRedrawRemainsOrdered(fragmentSize: Int) async throws {
            let oldVersion = VersionCompatibility.appVersionOverride
            VersionCompatibility.appVersionOverride = "3.0.50"
            defer { VersionCompatibility.appVersionOverride = oldVersion }

            try await withDependencies {
                $0[SecretsService.self] = .inMemory()
                $0[PreferencesService.self] = .inMemory()
                $0[DeviceNameClient.self].current = { "Test Host" }
            } operation: {
                let encryption = try await E2EEService()
                let settings = AppSettings()
                let manager = ConnectedViewerManager(
                    settings: settings,
                    e2eeService: encryption,
                    keyPair: encryption.storedKeyPair
                )
                var peers: [TerminalTransportPeer] = []
                do {
                    for pairID in ["viewer-a", "viewer-b"] {
                        let peer = try await TerminalTransportPeer.start(pairID: pairID)
                        peers.append(peer)
                        settings.externalServerURL = peer.url.absoluteString
                        await manager.connect(to: PairedViewer(
                            id: pairID,
                            deviceName: pairID,
                            partnerPublicKey: peer.encryption.publicKey.base64EncodedString(),
                            partnerPublicKeyId: peer.encryption.keyId
                        ))
                        await peer.viewer.connect(
                            serverURL: peer.url,
                            pairId: pairID,
                            deviceId: pairID,
                            deviceName: pairID,
                            publicKey: peer.encryption.publicKey.base64EncodedString(),
                            publicKeyId: peer.encryption.keyId,
                            e2eeService: peer.encryption,
                            partnerPublicKey: encryption.publicKey.base64EncodedString(),
                            partnerPublicKeyId: encryption.keyId
                        )
                    }
                    try await waitUntil {
                        peers.allSatisfy {
                            $0.viewer.isHostConnected
                                && manager.connection(for: $0.pairID)?.isViewerConnected == true
                        }
                    }

                    // Captured from a private zsh with syntax highlighting and
                    // autosuggestions: one typed c, two redraws, gray at, then BS×2.
                    let prompt = "\u{1B}[H\u{1B}[2J(base) Office \u{1B}[1m\u{1B}[32m➜  \u{1B}[36mfeature-bug\u{1B}[0m \u{1B}[1m\u{1B}[34mgit:(\u{1B}[31mfeature-bug\u{1B}[34m)\u{1B}[0m "
                    let redraw = "c\u{8}\u{1B}[1m\u{1B}[31mc\u{1B}[0m\u{1B}[39m\u{8}\u{1B}[1m\u{1B}[31mc\u{1B}[0m\u{1B}[39m\u{1B}[90mat\u{1B}[39m\u{8}\u{8}"
                    let bytes = Array(String(repeating: prompt + redraw, count: 12).utf8)
                    let frames = stride(from: 0, to: bytes.count, by: fragmentSize).map { offset in
                        TerminalStreamMessage.dataChunk(
                            paneId: "%fixture",
                            data: Data(bytes[offset..<min(offset + fragmentSize, bytes.count)])
                        )
                    }
                    let admitted = TerminalTransportTranscript()
                    let sendNext: @MainActor @Sendable () async -> Void = { [frames, admitted, manager] in
                        let frame = frames[admitted.messages.count]
                        admitted.receive(frame)
                        await manager.sendTerminalStream(frame, to: ["viewer-a", "viewer-b"])
                    }
                    await withTaskGroup(of: Void.self) { group in
                        for _ in frames.indices {
                            group.addTask { await sendNext() }
                        }
                    }
                    try await waitUntil {
                        peers.allSatisfy { $0.transcript.messages.count == frames.count }
                    }
                    for peer in peers {
                        #expect(peer.transcript.messages.map(\.id) == admitted.messages.map(\.id))
                        #expect(peer.transcript.bytes == Data(bytes))
                        #expect(peer.transcript.firstLine == "(base) Office ➜  feature-bug git:(feature-bug) cat")
                        #expect(peer.transcript.terminal.getCursorLocation().x == 48)
                        #expect(peer.transcript.terminal.getCursorLocation().y == 0)
                        #expect(await peer.relay.errors.isEmpty)
                        #expect(await peer.relay.unexpectedTypes.isEmpty)
                    }
                } catch {
                    await manager.disconnectAll()
                    for peer in peers { try await peer.stop() }
                    throw error
                }
                await manager.disconnectAll()
                for peer in peers { try await peer.stop() }
            }
        }

        @Test("Disconnected viewers cannot admit terminal bytes")
        func disconnectedViewerDoesNotEnqueue() async throws {
            let encryption = try await withDependencies {
                $0[SecretsService.self] = .inMemory()
            } operation: { try await E2EEService() }
            let connection = ConnectedViewer(
                pairedViewer: PairedViewer(
                    id: "offline",
                    deviceName: "Offline",
                    partnerPublicKey: "",
                    partnerPublicKeyId: ""
                ),
                e2eeService: encryption
            )
            let send = connection.enqueueTerminalStream(.dataChunk(paneId: "%fixture", data: Data("c".utf8)))
            #expect(send == nil)
            #expect(connection.terminalSendQueueSnapshot == .empty)
        }

        private func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition(), "Terminal transport did not finish")
        }
    }

    @MainActor
    private final class TerminalTransportTranscript: TerminalDelegate {
        private(set) var messages: [TerminalStreamMessage] = []
        private(set) var bytes = Data()
        lazy var terminal = SwiftTerm.Terminal(delegate: self, options: TerminalOptions(cols: 69, rows: 57))

        func receive(_ message: TerminalStreamMessage) {
            messages.append(message)
            guard case let .dataChunk(chunk) = message.updateType,
                  let data = Data(base64Encoded: chunk.dataBase64) else { return }
            bytes.append(data)
            terminal.feed(buffer: Array(data)[...])
        }

        var firstLine: String { terminal.getLine(row: 0)?.translateToString(trimRight: true) ?? "" }

        nonisolated func showCursor(source _: SwiftTerm.Terminal) { }
        nonisolated func hideCursor(source _: SwiftTerm.Terminal) { }
        nonisolated func send(source _: SwiftTerm.Terminal, data _: ArraySlice<UInt8>) { }
    }

    @MainActor
    private struct TerminalTransportPeer {
        let pairID: String
        let app: Application
        let url: URL
        let relay: PhraseTestRelay
        let encryption: E2EEService
        let viewer: ViewerRelayClient
        let transcript: TerminalTransportTranscript

        static func start(pairID: String) async throws -> Self {
            let encryption = try await withDependencies {
                $0[SecretsService.self] = .inMemory()
            } operation: { try await E2EEService() }
            let relay = PhraseTestRelay()
            let app = try await Application.make(.testing)
            app.webSocket("api", "ws") { _, socket in
                // Synchronous admission and one consumer keep the test relay
                // from introducing the same per-frame Task ordering hole.
                let input = AsyncStream<Data>.makeStream()
                let consumer = Task {
                    for await data in input.stream { await relay.receive(data, from: socket) }
                }
                socket.onBinary { _, data in input.continuation.yield(Data(data.readableBytesView)) }
                socket.onClose.whenComplete { _ in
                    input.continuation.finish()
                    Task {
                        await consumer.value
                        await relay.closed(socket)
                    }
                }
            }
            do {
                try await app.asyncBoot()
                try await app.server.start(address: .hostname("127.0.0.1", port: 0))
                let port = try #require(app.http.server.shared.localAddress?.port)
                let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
                let viewer = ViewerRelayClient()
                let transcript = TerminalTransportTranscript()
                viewer.registerTerminalStreamHandler(for: "%fixture") { transcript.receive($0) }
                return Self(
                    pairID: pairID, app: app, url: url, relay: relay,
                    encryption: encryption, viewer: viewer, transcript: transcript
                )
            } catch {
                await app.server.shutdown()
                try await app.asyncShutdown()
                throw error
            }
        }

        func stop() async throws {
            await viewer.disconnect()
            await app.server.shutdown()
            try await app.asyncShutdown()
        }
    }
#endif
