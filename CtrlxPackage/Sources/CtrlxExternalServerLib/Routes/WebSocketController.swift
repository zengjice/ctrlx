import CtrlxNetworking
import Vapor

/// Handles WebSocket connections for real-time communication
struct WebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("ws") { req -> Response in
            let response = Response(status: .switchingProtocols)
            response.upgrader = RelayWebSocketUpgrader { socket in
                handleWebSocketUpgrade(req: req, ws: socket)
            }
            return response
        }
    }

    /// Handle WebSocket upgrade
    /// WS /api/ws?pairId=xxx&deviceType=host|viewer&deviceId=xxx
    @Sendable
    func handleWebSocketUpgrade(req: Request, ws: WebSocket) {
        let inbound = RelayInboundQueue()
        // Retain services for cleanup, which may finish after Application storage
        // has been cleared during server shutdown.
        let connectionHub = req.application.connectionHub
        let relayService = req.application.relayService

        // Use WebSocketKit's SYNCHRONOUS callbacks on the event loop. Its async
        // overload starts an independent Task per frame and can reorder traffic.
        // Install both before the upgrade callback returns, including validation.
        let receive: @Sendable (WebSocket, RelayInboundFrame) -> Void = { socket, frame in
            if inbound.enqueue(frame) == .overflow {
                req.logger.warning("Closing WebSocket: inbound relay queue exceeded its limit")
                // Never continue a terminal stream with missing bytes.
                socket.close(code: .policyViolation, promise: nil)
            }
        }
        ws.onText { socket, text in receive(socket, .init(data: Data(text.utf8), kind: .text)) }
        ws.onBinary { socket, buffer in receive(socket, .init(data: Data(buffer: buffer), kind: .binary)) }

        // One worker owns validation, ordered forwarding, and final cleanup for
        // this socket. There are no per-frame Tasks or parallel replay paths.
        let worker = Task {
            await handleConnection(req: req, ws: ws, inbound: inbound)
            inbound.finish()
            if let pairId = req.query[String.self, at: "pairId"],
               let type = req.query[String.self, at: "deviceType"],
               let deviceType = DeviceType(rawValue: type) {
                let removed = await connectionHub.unregisterIfCurrent(
                    pairId: pairId, deviceType: deviceType, webSocket: ws
                )
                if removed {
                    await relayService.notifyConnection(
                        pairId: pairId, deviceType: deviceType, connected: false
                    )
                    req.logger.info("WebSocket disconnected: \(deviceType) for pair \(pairId)")
                }
            }
        }
        ws.onClose.whenComplete { _ in
            inbound.finish()
            worker.cancel()
        }
    }

    private func handleConnection(req: Request, ws: WebSocket, inbound: RelayInboundQueue) async {
        guard !Task.isCancelled, !inbound.isFinished, !ws.isClosed else { return }
        // Extract query parameters
        guard
            let pairId = req.query[String.self, at: "pairId"],
            let deviceTypeString = req.query[String.self, at: "deviceType"],
            let deviceType = DeviceType(rawValue: deviceTypeString),
            let deviceId = req.query[String.self, at: "deviceId"]
        else {
            req.logger.warning("WebSocket connection rejected: missing parameters")
            try? await ws.close(code: .policyViolation)
            return
        }

        // Optional server-side minimum-client-version gate (issue #659). The client
        // reports its marketing version in the pre-E2EE `clientVersion` query param;
        // a client below the configured minimum is refused here — before the
        // connection is registered or any message is processed — with a typed
        // CLIENT_TOO_OLD error, then the socket is closed (mirroring the invalidPair
        // / subscriptionRequired rejection flow). Disabled (nil) unless
        // MIN_CLIENT_VERSION is set, so self-hosting is unaffected. This can only
        // enforce against clients new enough to report a version; older builds send
        // none and follow the gate's `rejectUnknown` policy (default: allowed).
        if let gate = req.application.minClientVersionGate {
            let clientVersion = req.query[String.self, at: "clientVersion"]
            if !gate.allows(clientVersion: clientVersion) {
                req.logger.info(
                    "WebSocket connection rejected: client version \(clientVersion ?? "<none>") below minimum \(gate.minVersion) (\(deviceType) for pair \(pairId))"
                )
                let errorMessage = WebSocketMessage.error(.clientTooOld(minVersion: gate.minVersion))
                if let data = try? JSONEncoder().encode(errorMessage) {
                    try? await ws.send(raw: data, opcode: .text)
                }
                try? await ws.close(code: .policyViolation)
                return
            }
        }

        let pairingService = req.application.pairingService
        let connectionHub = req.application.connectionHub
        let relayService = req.application.relayService
        let licensingService = req.application.licensingService
        let metricsService = req.application.metricsService

        // Reject connections from blocked device types (for E2E testing).
        // This prevents auto-reconnection while the test verifies server-side state.
        if await connectionHub.isBlocked(deviceType: deviceType) {
            req.logger.info("WebSocket connection rejected: \(deviceType) is blocked")
            try? await ws.close(code: .goingAway)
            return
        }

        guard !Task.isCancelled, !inbound.isFinished, !ws.isClosed else { return }

        // Register exactly once. The FIFO keeps early frames buffered until this
        // socket is registered and validated, so message handling never needs to
        // mutate connection ownership.
        let connection = Connection(
            pairId: pairId,
            deviceType: deviceType,
            deviceId: deviceId,
            webSocket: ws,
            stopReceiving: { inbound.finish() }
        )
        await connectionHub.register(connection)
        req.logger.info("WebSocket connected: \(deviceType) for pair \(pairId)")

        // Validate the pair (after registration so messages aren't lost)
        guard await pairingService.isValidPair(pairId: pairId) else {
            req.logger.warning("WebSocket connection rejected: invalid pairId \(pairId)")
            _ = await connectionHub.unregisterIfCurrent(
                pairId: pairId,
                deviceType: deviceType,
                webSocket: ws
            )
            let errorMessage = WebSocketMessage.error(.invalidPair())
            if let data = try? JSONEncoder().encode(errorMessage) {
                try? await ws.send(raw: data, opcode: .text)
            }
            try? await ws.close(code: .policyViolation)
            return
        }
        guard !Task.isCancelled, !inbound.isFinished, !ws.isClosed else { return }

        // Hosted-relay gate for hosts (viewers are never gated). Mirrors the
        // invalidPair rejection flow above.
        if deviceType == .host {
            // Migration safety net for grandfathered pairings: an ACTIVE
            // (completed) pair that predates licensing being enabled — or predates
            // trial-on-pairing — has no trial record. Start it on connect so such a
            // host begins its trial rather than getting ungated `.preTrial` access
            // forever. Gated to active pairs via `getPair` (nil for pending pairs),
            // so a pending pair connecting mid-pairing still never starts a trial —
            // that stays `completePairing`'s job. Idempotent no-op for normal new
            // pairings (trial already started) and for expired trials.
            if let pair = await pairingService.getPair(pairId: pairId) {
                await licensingService.startTrialIfNeeded(hostDeviceId: pair.hostDeviceId)
            }

            let entitlement = await licensingService
                .checkEntitlement(hostDeviceId: deviceId)
            if !entitlement.isAllowed {
                req.logger.info("WebSocket host rejected: subscription required for pair \(pairId)")
                await metricsService.incrementBlockedHostAttempts()
                _ = await connectionHub.unregisterIfCurrent(
                    pairId: pairId,
                    deviceType: deviceType,
                    webSocket: ws
                )
                let errorMessage = WebSocketMessage.error(.subscriptionRequired())
                if let data = try? JSONEncoder().encode(errorMessage) {
                    try? await ws.send(raw: data, opcode: .text)
                }
                await connectionHub.send(.hostSubscriptionInactive, to: pairId, deviceType: .viewer)
                try? await ws.close(code: .policyViolation)
                // Gate is left closed: any frames buffered during the check are dropped.
                return
            }

        }

        // Validation passed. Early and live traffic now have the SAME consumer.
        // The connection notification is a barrier behind the early frames.
        inbound.activate()
        await inbound.consume { event in
            guard !Task.isCancelled, !ws.isClosed, !inbound.isFinished else { return }
            switch event {
            case let .frame(frame):
                await handleIncomingMessage(
                    frame: frame,
                    ws: ws,
                    pairId: pairId,
                    deviceType: deviceType,
                    connectionHub: connectionHub,
                    relayService: relayService,
                    logger: req.logger
                )
            case .connected:
                guard await connectionHub.isCurrent(pairId: pairId, deviceType: deviceType, webSocket: ws) else { return }
                await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: true)
            }
        }
    }
}

// MARK: - Message Handling

private func handleIncomingMessage(
    frame: RelayInboundFrame,
    ws: WebSocket,
    pairId: String,
    deviceType: DeviceType,
    connectionHub: ConnectionHub,
    relayService: RelayService,
    logger: Logger
) async {
    // A replaced half-open socket may still deliver a frame after its successor
    // registered. It must never reclaim routing or relay stale traffic.
    guard await connectionHub.isCurrent(pairId: pairId, deviceType: deviceType, webSocket: ws) else {
        logger.debug("Ignoring frame from stale \(deviceType) WebSocket for pair \(pairId)")
        return
    }

    do {
        let data = frame.data
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let rawEncryptedFrame = try RelayMessageEnvelope.rawEncryptedFrame(
            in: data,
            using: decoder
        ) {
            await relayService.handleEncryptedFrame(
                rawEncryptedFrame,
                kind: frame.kind,
                pairId: pairId,
                sender: deviceType,
                sourceWebSocket: ws
            )
            return
        }
        let message = try decoder.decode(WebSocketMessage.self, from: data)

        switch deviceType {
        case .host:
            await relayService.handleHostMessage(message, pairId: pairId)
        case .viewer:
            await relayService.handleViewerMessage(message, pairId: pairId)
        }
    } catch {
        logger.error("Failed to decode WebSocket message: \(error)")
    }
}

/// Decodes only the outer encrypted wrapper. Ciphertext remains a String, so
/// the relay avoids the full Data base64 decode/encode round trip while still
/// rejecting malformed wrappers before forwarding their original bytes.
struct RelayMessageEnvelope: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private struct EncryptedMessagePayload: Decodable {
        let payload: OpaqueEncryptedPayload
    }

    private struct OpaqueEncryptedPayload: Decodable {
        let ciphertext: String
        let senderKeyId: String
        let version: Int
    }

    let isValidatedEncrypted: Bool

    /// Returns the caller's original `Data` value for a validated encrypted
    /// envelope. No JSON encoder or base64 decoder touches the payload.
    static func rawEncryptedFrame(in data: Data, using decoder: JSONDecoder) throws -> Data? {
        let envelope = try decoder.decode(Self.self, from: data)
        return envelope.isValidatedEncrypted ? data : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "encrypted" else {
            isValidatedEncrypted = false
            return
        }

        let wrapper = try container.decode(EncryptedMessagePayload.self, forKey: .payload)
        let encrypted = wrapper.payload
        guard
            Self.isValidBase64(encrypted.ciphertext),
            !encrypted.senderKeyId.isEmpty,
            encrypted.version > 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .payload,
                in: container,
                debugDescription: "Invalid encrypted relay wrapper"
            )
        }
        isValidatedEncrypted = true
    }

    private static func isValidBase64(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 4) else { return false }

        var paddingCount = 0
        var sawPadding = false
        for byte in bytes {
            if byte == 0x3D { // =
                sawPadding = true
                paddingCount += 1
                guard paddingCount <= 2 else { return false }
            } else {
                guard !sawPadding, isBase64Byte(byte) else { return false }
            }
        }
        return true
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F:
            true
        default:
            false
        }
    }
}

// MARK: - Device Type

enum DeviceType: String {
    case host
    case viewer
}

enum RelayFrameKind: Sendable, Equatable {
    case text
    case binary
}
