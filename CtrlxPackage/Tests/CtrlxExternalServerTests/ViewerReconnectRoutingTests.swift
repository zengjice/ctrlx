import CtrlxNetworking
import Foundation
import Testing
import VaporTesting
@testable import CtrlxExternalServerLib
#if os(macOS)
    import CtrlxCommon
    import SwiftTerm
#endif

/// Regression coverage for issue #642: after a device reconnects (e.g. a viewer
/// that switched networks), the *old* half-open socket's `onClose` fires later
/// and used to unregister the live replacement connection — evicting it from the
/// routing table and falsely telling the peer the device disconnected.
///
/// The fix (`ConnectionHub.unregisterIfCurrent`) only tears a connection down
/// when the closing socket is still the registered one, so a stale close is a
/// no-op.
///
/// These tests drive the real WebSocket lifecycle against a running relay: they
/// open two viewer sockets for the same pair (the second replaces the first in
/// `ConnectionHub`), then assert the *first* closes and the live replacement keeps
/// routing and the host is never told the viewer left. `deviceId` isn't validated
/// on upgrade, so distinct viewer sockets simply model "same viewer, new socket".
///
/// Nested under `EnvSerializedSuites` to bound how many full Vapor apps boot
/// concurrently (see that container's doc for why setenv is banned here).
extension EnvSerializedSuites {
    @Suite("Viewer reconnect routing (#642)", .serialized)
    struct ViewerReconnectRoutingTests {
        // Valid 32-byte base64 keys so `notifyConnection` has public keys to attach
        // (without them it logs "no public key available" and skips the notification,
        // which would hide the very host-notification we assert on).
        private static let hostPublicKey = "aG9zdC1wdWJsaWMta2V5LTAxMjM0NTY3ODkwMTIzNDU2Nw=="
        private static let hostKeyId = "host-key-id-1"
        private static let viewerPublicKey = "dmlld2VyLXB1YmxpYy1rZXktMDEyMzQ1Njc4OTAxMjM0NTY="
        private static let viewerKeyId = "viewer-key-id-1"

        // MARK: - Test

        @Test("A fragmented message within the limit is forwarded without changing bytes")
        func fragmentedMessageIsForwarded() async throws {
            try await withRunningRelay { app, port in
                try await verifyFragmentedMessageIsForwarded(app: app, port: port)
            }
        }

        private func verifyFragmentedMessageIsForwarded(app: Application, port: Int) async throws {
            let pairId = try await makePair(app)
            let viewer = TextCollector()
            let viewerWS = try await connectClient(
                port: port, query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-fragments", collector: viewer
            )
            let hostWS = try await connectClient(
                port: port, query: "pairId=\(pairId)&deviceType=host&deviceId=host-fragments", collector: TextCollector()
            )
            #expect(await waitUntil { count(of: "hostConnected", in: viewer.all()) == 1 })
            let frame = try opaqueFrame(Data(repeating: 42, count: 600_000))
            let chunkSize = 256 * 1024
            for offset in stride(from: 0, to: frame.count, by: chunkSize) {
                let end = min(offset + chunkSize, frame.count)
                try await hostWS.send(
                    raw: frame.subdata(in: offset..<end),
                    opcode: offset == 0 ? .binary : .continuation, fin: end == frame.count
                )
            }
            #expect(await waitUntil { count(of: "encrypted", in: viewer.all()) == 1 })
            #expect(viewer.all().contains(String(decoding: frame, as: UTF8.self)))
            try await hostWS.close()
            try await viewerWS.close()
        }

        @Test("An unfinished fragmented message exceeding 1 MiB closes the socket")
        func oversizedFragmentsAreRejectedBeforeFinalFrame() async throws {
            try await withRunningRelay { app, port in
                try await verifyOversizedFragmentsAreRejected(app: app, port: port)
            }
        }

        private func verifyOversizedFragmentsAreRejected(app: Application, port: Int) async throws {
            let pairId = try await makePair(app)
            let hostWS = try await connectClient(
                port: port, query: "pairId=\(pairId)&deviceType=host&deviceId=host-overflow", collector: TextCollector()
            )
            #expect(await waitUntil { await app.connectionHub.isHostConnected(pairId: pairId) })
            let fragment = Data(repeating: 42, count: 256 * 1024)
            for index in 0..<4 {
                try await hostWS.send(raw: fragment, opcode: index == 0 ? .binary : .continuation, fin: false)
            }
            #expect(!hostWS.isClosed)
            try await hostWS.send(raw: fragment, opcode: .continuation, fin: false)
            let closed = await waitUntil { hostWS.isClosed }
            #expect(closed)
            #expect(await waitUntil { !(await app.connectionHub.isHostConnected(pairId: pairId)) })
        }

        @Test("Empty continuation frames cannot bypass the fragment count limit")
        func excessiveEmptyFragmentsAreRejected() async throws {
            try await withRunningRelay { app, port in
                try await verifyEmptyFragmentsAreRejected(app: app, port: port)
            }
        }

        private func verifyEmptyFragmentsAreRejected(app: Application, port: Int) async throws {
            let pairId = try await makePair(app)
            let hostWS = try await connectClient(
                port: port, query: "pairId=\(pairId)&deviceType=host&deviceId=host-fragment-count", collector: TextCollector()
            )
            #expect(await waitUntil { await app.connectionHub.isHostConnected(pairId: pairId) })
            for index in 0..<RelayWebSocketUpgrader.maximumFragments {
                hostWS.send(raw: Data(), opcode: index == 0 ? .binary : .continuation, fin: false, promise: nil)
            }
            let closed = await waitUntil { hostWS.isClosed }
            #expect(closed)
            #expect(await waitUntil { !(await app.connectionHub.isHostConnected(pairId: pairId)) })
        }

        @Test("Frames sent immediately at upgrade survive validation in order")
        func immediateUpgradeFrames() async throws {
            try await withRunningRelay { app, port in
                let pairId = try await makePair(app)
                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port, query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-early", collector: viewer
                )
                #expect(await waitUntil { await app.connectionHub.isViewerConnected(pairId: pairId) })
                let frames = try (0..<48).map { index in
                    try opaqueFrame(Data(("\(index):" + String(repeating: "x", count: index.isMultiple(of: 3) ? 9000 : 20)).utf8))
                }
                let hostWS = try await connectClient(
                    port: port, query: "pairId=\(pairId)&deviceType=host&deviceId=host-early",
                    collector: TextCollector(), earlyFrames: frames
                )
                #expect(await waitUntil { count(of: "encrypted", in: viewer.all()) == frames.count })
                let actual = viewer.all().filter { count(of: "encrypted", in: [$0]) == 1 }
                let ordered = actual == frames.map { String(decoding: $0, as: UTF8.self) }
                #expect(ordered)
                try await hostWS.close()
                try await viewerWS.close()
            }
        }

        #if os(macOS)
            @Test("Chunked snapshots followed by live ANSI preserve the final composer", arguments: [false, true])
            func snapshotAndLiveRendering(reset: Bool) async throws {
                try await withRunningRelay { app, port in
                    app.logger.logLevel = .error
                    let pairId = try await makePair(app)
                    let host = TextCollector()
                    let viewer = TextCollector()
                    let hostWS = try await connectClient(
                        port: port, query: "pairId=\(pairId)&deviceType=host&deviceId=host-render", collector: host
                    )
                    let viewerWS = try await connectClient(
                        port: port, query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-render", collector: viewer
                    )
                    #expect(await waitUntil { count(of: "viewerConnected", in: host.all()) == 1 })

                    let history = (0..<3000).map { "历史 \($0): 中文和 emoji 🐈\r\n" }.joined()
                    let snapshot = Data((history + "\u{1b}[2J\u{1b}[Hsnapshot\u{1b}[64;1H> OLD INPUT\u{1b}[66;1HSTATUS").utf8)
                    let initial = TerminalStreamMessage.InitialState(
                        width: 241, height: 66, content: Data(), scrollbackLineLimit: 4000,
                        contentByteCount: snapshot.count
                    )
                    var messages = [TerminalStreamMessage(
                        paneId: "%6", updateType: reset ? .resetState(initial) : .initialState(initial)
                    )]
                    let chunkSizes = [16384, 1, 3, 19, 64, 4096]
                    var offset = 0
                    var chunkIndex = 0
                    while offset < snapshot.count {
                        let end = min(snapshot.count, offset + chunkSizes[chunkIndex % chunkSizes.count])
                        var data = snapshot.subdata(in: offset..<end)
                        if end == snapshot.count {
                            // Exercise a snapshot boundary inside a data chunk.
                            data.append(contentsOf: "\u{1b}[64;1H\u{1b}[2K> READY".utf8)
                        }
                        messages.append(.dataChunk(paneId: "%6", data: data))
                        offset = end
                        chunkIndex += 1
                    }
                    for index in 0..<60 {
                        messages.append(.dataChunk(paneId: "%6", data: Data(
                            "\u{1b}[64;1H\u{1b}[2K> INPUT \(index)\u{1b}[66;1H\u{1b}[2KSTATUS \(index)".utf8
                        )))
                    }
                    let payloads = try messages.map { try JSONEncoder().encode($0) }
                    for (index, payload) in payloads.enumerated() {
                        try await hostWS.send(raw: opaqueFrame(payload), opcode: index.isMultiple(of: 2) ? .binary : .text)
                    }
                    #expect(await waitUntil(timeout: .seconds(10)) {
                        count(of: "encrypted", in: viewer.all()) == payloads.count
                    })
                    let relayed = try viewer.all().filter { count(of: "encrypted", in: [$0]) == 1 }.map { text in
                        let message = try JSONDecoder().decode(WebSocketMessage.self, from: Data(text.utf8))
                        guard case let .encrypted(encrypted) = message else { throw RelayTestError.connectFailed("Expected encrypted frame") }
                        return encrypted.payload.ciphertext
                    }
                    let exactBytes = relayed == payloads
                    #expect(exactBytes)
                    let expected = try await renderedRows(payloads)
                    let actual = try await renderedRows(relayed)
                    let identicalCells = actual == expected
                    #expect(identicalCells, "Relay output must render the same screen as the original stream")
                    #expect(actual[63].hasPrefix("> INPUT 59"))
                    #expect(actual[65].hasPrefix("STATUS 59"))
                    try await hostWS.close()
                    try await viewerWS.close()
                }
            }

            @MainActor
            private func renderedRows(_ payloads: [Data]) throws -> [String] {
                let delegate = RenderingDelegate()
                let terminal = SwiftTerm.Terminal(delegate: delegate)
                terminal.resize(cols: 241, rows: 66)
                var snapshot = TerminalStreamSnapshotAccumulator()
                func feed(_ data: Data) { terminal.feed(buffer: Array(data)[...]) }
                for payload in payloads {
                    let message = try JSONDecoder().decode(TerminalStreamMessage.self, from: payload)
                    switch message.updateType {
                    case let .initialState(initial), let .resetState(initial):
                        _ = snapshot.begin(expectedByteCount: initial.contentByteCount ?? 0)
                    case let .dataChunk(chunk):
                        let data = try #require(chunk.data)
                        if snapshot.isCollecting {
                            if let complete = snapshot.append(data) {
                                feed(complete.content)
                                feed(complete.remainder)
                            }
                        } else {
                            feed(data)
                        }
                    default: break
                    }
                }
                #expect(!snapshot.isCollecting)
                return (0..<terminal.rows).map { row in
                    guard let line = terminal.getLine(row: row) else { return "" }
                    return (0..<terminal.cols).map { String(line[$0].getCharacter()) }.joined()
                }
            }
        #endif

        @Test("Mixed-size opaque frames retain wire order in both directions", arguments: [0, 1, 2], [false, true])
        func encryptedFramesPreserveWireOrder(framing: Int, fromViewer: Bool) async throws {
            try await withRunningRelay { app, port in
                app.logger.logLevel = .error
                let pairId = try await makePair(app)
                let host = TextCollector()
                let viewer = TextCollector()
                let hostWS = try await connectClient(
                    port: port, query: "pairId=\(pairId)&deviceType=host&deviceId=host-order", collector: host
                )
                let viewerWS = try await connectClient(
                    port: port, query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-order", collector: viewer
                )
                #expect(await waitUntil { count(of: "viewerConnected", in: host.all()) == 1 })

                // Large frames take longer to validate than their small successors.
                // Per-frame Tasks reorder these even on a lossless localhost link.
                let total = 600
                var expected: [String] = []
                for index in 0..<total {
                    let payload = Data(("\(index):" + String(repeating: "x", count: index.isMultiple(of: 3) ? 9000 : 20)).utf8)
                    let frame = try opaqueFrame(payload)
                    expected.append(String(decoding: frame, as: UTF8.self))
                    let binary = framing == 1 || (framing == 2 && index.isMultiple(of: 2))
                    try await (fromViewer ? viewerWS : hostWS).send(raw: frame, opcode: binary ? .binary : .text)
                }
                let receiver = fromViewer ? host : viewer
                #expect(await waitUntil(timeout: .seconds(10)) {
                    count(of: "encrypted", in: receiver.all()) == total
                })
                let actual = receiver.all().filter { count(of: "encrypted", in: [$0]) == 1 }
                #expect(actual.count == total)
                #expect(Set(actual).count == total)
                let ordered = actual == expected
                #expect(ordered, "Relay must preserve original frame bytes AND order")
                try await hostWS.close()
                try await viewerWS.close()
            }
        }

        /// The Relay treats ciphertext as opaque. Counter/ANSI bytes stand in for
        /// ciphertext here so tests can inspect the forwarded order without keys.
        private func opaqueFrame(_ payload: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "encrypted",
                "payload": ["payload": [
                    "ciphertext": payload.base64EncodedString(),
                    "senderKeyId": "test-key",
                    "version": 1,
                ]],
            ])
        }

        @Test("A stale viewer socket closing does not evict the reconnected viewer or notify the host")
        func staleCloseKeepsLiveViewerRouting() async throws {
            try await withRunningRelay { app, port in
                try await verifyStaleViewerCloseKeepsRouting(app: app, port: port)
            }
        }

        private func verifyStaleViewerCloseKeepsRouting(app: Application, port: Int) async throws {
            let pairId = try await makePair(app)

            // Host stays connected throughout; it's the peer that would be
            // (wrongly) told "viewer disconnected".
            let host = TextCollector()
            let hostWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=host&deviceId=host-1",
                collector: host
            )

            // Viewer socket A — the connection that will go half-open and close late.
            let viewerA = TextCollector()
            let viewerAWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-A",
                collector: viewerA
            )
            // Server processed A's registration once the host is told the viewer connected.
            #expect(await waitUntil { count(of: "viewerConnected", in: host.all()) == 1 })

            // Viewer socket B — the reconnection. Registering it replaces A in the
            // hub (last-write-wins on `(pairId, .viewer)`) and closes A.
            let viewerB = TextCollector()
            let viewerBWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-B",
                collector: viewerB
            )
            // Waiting for the *second* viewerConnected guarantees register(B) ran
            // after register(A) — so B is the current entry when A closes next.
            #expect(await waitUntil { count(of: "viewerConnected", in: host.all()) == 2 })
            #expect(await app.connectionHub.isViewerConnected(pairId: pairId))

            let oldViewerClosed = await waitUntil { viewerAWS.isClosed }
            #expect(oldViewerClosed, "Replaced viewer socket must be reclaimed")

            // The buggy behavior surfaces fast (a clean localhost close's onClose
            // fires in well under this window): the live viewer B gets evicted
            // and/or the host is told the viewer disconnected. Assert neither
            // happens within a generous window — this is the non-event we're proving.
            let sawRegression = await waitUntil(timeout: .seconds(2)) {
                let viewerEvicted = !(await app.connectionHub.isViewerConnected(pairId: pairId))
                let hostToldDisconnected = count(of: "viewerDisconnected", in: host.all()) > 0
                return viewerEvicted || hostToldDisconnected
            }
            #expect(
                sawRegression == false,
                "Stale viewer close evicted the live replacement and/or falsely notified the host"
            )

            // Positive confirmation the replacement is still routable: a host→viewer
            // relay lands on B. On the buggy path the viewer entry is gone, so this
            // never arrives.
            await app.connectionHub.send(.ping, to: pairId, deviceType: .viewer)
            #expect(
                await waitUntil { count(of: "ping", in: viewerB.all()) > 0 },
                "Host→viewer routing broke after the stale close (replacement viewer was evicted)"
            )

            // And A — the socket that closed — should never have received the relay.
            #expect(count(of: "ping", in: viewerA.all()) == 0)

            try await hostWS.close()
            try await viewerBWS.close()
        }

        @Test("A stale host frame cannot reclaim routing from the replacement socket")
        func staleHostFrameCannotReclaimRouting() async throws {
            try await withRunningRelay { app, port in
                try await verifyStaleHostFrameIsRejected(app: app, port: port)
            }
        }

        private func verifyStaleHostFrameIsRejected(app: Application, port: Int) async throws {
            let pairId = try await makePair(app)

            let viewer = TextCollector()
            let viewerWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1",
                collector: viewer
            )

            let hostA = TextCollector()
            let hostAWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=host&deviceId=host-A",
                collector: hostA
            )
            #expect(await waitUntil { count(of: "hostConnected", in: viewer.all()) == 1 })
            let oldHostConnection = try #require(await app.connectionHub.getConnection(pairId: pairId, deviceType: .host))

            let hostB = TextCollector()
            let hostBWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=host&deviceId=host-B",
                collector: hostB
            )
            #expect(await waitUntil { count(of: "hostConnected", in: viewer.all()) == 2 })

            // Also model an old frame suspended AFTER the controller's ownership
            // check: the final send boundary must reject it after replacement.
            await app.relayService.handleEncryptedFrame(
                try opaqueFrame(Data("stale in-flight frame".utf8)), kind: .binary,
                pairId: pairId, sender: .host, sourceWebSocket: oldHostConnection.webSocket
            )
            #expect(count(of: "encrypted", in: viewer.all()) == 0)

            let oldHostClosed = await waitUntil { hostAWS.isClosed }
            #expect(oldHostClosed, "Replaced host socket must be reclaimed")

            let sawRegression = await waitUntil(timeout: .seconds(2)) {
                let hostEvicted = !(await app.connectionHub.isHostConnected(pairId: pairId))
                let viewerToldDisconnected = count(of: "hostDisconnected", in: viewer.all()) > 0
                return hostEvicted || viewerToldDisconnected
            }
            #expect(
                !sawRegression,
                "Stale Host traffic reclaimed routing and its close reported the live Host offline"
            )

            await app.connectionHub.send(.ping, to: pairId, deviceType: .host)
            #expect(await waitUntil { count(of: "ping", in: hostB.all()) > 0 })

            try await viewerWS.close()
            try await hostBWS.close()
        }

        // MARK: - Relay lifecycle

        /// Boots the real relay on an ephemeral port, runs the body, and tears down
        /// both the HTTP server and the application.
        private func withRunningRelay(
            _ body: (Application, Int) async throws -> Void
        ) async throws {
            // Isolate each run's `pairs.json` into a fresh temp dir. Config is
            // injected (never setenv — see `configure(_:env:)`).
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-reconnect-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let app = try await Application.make(.testing)
            do {
                try await configure(app, env: ["DATA_DIRECTORY": tempDir.path])
                // Match the framework's own test flow (`testing()` calls `boot()` before
                // starting a live server): run lifecycle handlers before binding.
                try await app.asyncBoot()
                // Bind to 127.0.0.1:0 so the OS picks a free port; the explicit address
                // overrides configure()'s 0.0.0.0:8080 default.
                try await app.server.start(address: .hostname("127.0.0.1", port: 0))
                guard let port = app.http.server.shared.localAddress?.port else {
                    Issue.record("Relay did not report a bound port")
                    await app.server.shutdown()
                    try await app.asyncShutdown()
                    return
                }
                try await body(app, port)
                await app.server.shutdown()
            } catch {
                await app.server.shutdown()
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }

        /// Registers a host code and completes pairing from the viewer, yielding an
        /// active pair whose host and viewer public keys are both populated.
        private func makePair(_ app: Application) async throws -> String {
            let code = "PAIR-\(UUID().uuidString.prefix(6))"
            let register = await app.pairingService.registerCode(
                code: String(code),
                deviceId: "host-device",
                deviceName: "Test Host",
                username: "tester",
                publicKey: Self.hostPublicKey,
                publicKeyId: Self.hostKeyId
            )
            guard case let .registered(info) = register else {
                throw RelayTestError.pairingFailed("register returned \(register)")
            }
            let complete = await app.pairingService.completePairing(
                code: String(code),
                deviceId: "viewer-device",
                deviceName: "Test Viewer",
                publicKey: Self.viewerPublicKey,
                publicKeyId: Self.viewerKeyId
            )
            guard case .paired = complete else {
                throw RelayTestError.pairingFailed("complete returned \(complete)")
            }
            return info.pairId
        }

        // MARK: - WebSocket client helpers

        /// Opens a raw WebSocket client to the relay and streams every inbound text
        /// frame into `collector`. Returns the live socket so the test can close it.
        private func connectClient(
            port: Int,
            query: String,
            collector: TextCollector,
            earlyFrames: [Data] = []
        ) async throws -> WebSocket {
            // Resume inside `onUpgrade` (not on the connect future) so we only proceed
            // once the socket exists: websocket-kit succeeds the connect future from a
            // completion handler that can run before `onUpgrade` sets up the socket.
            // A one-shot guard makes the two resume paths (upgrade vs. connect failure)
            // mutually safe.
            let gate = ResumeGate()
            return try await withCheckedThrowingContinuation { continuation in
                WebSocket.connect(
                    to: "ws://127.0.0.1:\(port)/api/ws?\(query)",
                    configuration: .init(maxFrameSize: RelayPayloadLimits.maxWebSocketFrameBytes),
                    on: MultiThreadedEventLoopGroup.singleton
                ) { ws in
                    ws.onText { _, text in collector.append(text) }
                    ws.onBinary { _, data in collector.append(String(decoding: data.readableBytesView, as: UTF8.self)) }
                    for (index, frame) in earlyFrames.enumerated() {
                        ws.send(raw: frame, opcode: index.isMultiple(of: 2) ? .binary : .text, promise: nil)
                    }
                    if gate.claim() { continuation.resume(returning: ws) }
                }.whenFailure { error in
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
        }

        // MARK: - Polling

        /// Polls `condition` until it's true or the timeout elapses. Used both to
        /// wait for a positive signal and to bound the window in which a non-event
        /// (the regression) would otherwise appear.
        private func waitUntil(
            timeout: Duration = .seconds(3),
            _ condition: () async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return await condition()
        }

        // MARK: - Frame inspection

        private struct Envelope: Decodable { let type: String }

        /// Counts inbound frames whose `type` discriminator matches, ignoring frames
        /// that don't decode (none are expected, but this keeps the helper total).
        private func count(of type: String, in texts: [String]) -> Int {
            texts.reduce(into: 0) { total, text in
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
                else { return }
                if envelope.type == type { total += 1 }
            }
        }
    }
}

#if os(macOS)
    private final class RenderingDelegate: TerminalDelegate {
        func send(source _: SwiftTerm.Terminal, data _: ArraySlice<UInt8>) { }
        func showCursor(source _: SwiftTerm.Terminal) { }
        func hideCursor(source _: SwiftTerm.Terminal) { }
        func setTerminalTitle(source _: SwiftTerm.Terminal, title _: String) { }
        func setTerminalIconTitle(source _: SwiftTerm.Terminal, title _: String) { }
        func sizeChanged(source _: SwiftTerm.Terminal) { }
        func scrolled(source _: SwiftTerm.Terminal, yDisp _: Int) { }
        func hostCurrentDirectoryUpdated(source _: SwiftTerm.Terminal) { }
        func hostCurrentDocumentUpdated(source _: SwiftTerm.Terminal) { }
    }
#endif

// MARK: - Support types

private enum RelayTestError: Error {
    case pairingFailed(String)
    case connectFailed(String)
}

/// Thread-safe accumulator of inbound WebSocket text frames. `onText` fires on a
/// NIO event loop, so appends must be synchronized.
final private class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []

    func append(_ text: String) {
        lock.lock()
        texts.append(text)
        lock.unlock()
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }
}

/// One-shot guard so a continuation is resumed exactly once across the two racing
/// callbacks (successful upgrade vs. connect failure).
final private class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns `true` for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
