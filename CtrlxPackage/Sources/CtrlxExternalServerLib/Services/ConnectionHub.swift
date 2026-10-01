import CtrlxNetworking
import Foundation
import Logging
import Vapor

/// Aggregate count of active WebSocket connections, partitioned by device type.
struct ConnectionCounts {
    let host: Int
    let viewer: Int
}

/// Manages active WebSocket connections for paired devices
actor ConnectionHub {
    /// Active connections indexed by pairId and deviceType
    private var connections: [String: [DeviceType: Connection]] = [:]
    private let logger = Logger(label: "connection-hub")

    /// Device types that are blocked from connecting (for E2E testing).
    /// When a device type is blocked, new WebSocket connections for that type
    /// are immediately rejected, preventing auto-reconnection.
    private var blockedDeviceTypes: Set<DeviceType> = []

    // MARK: - Connection Management

    /// Register a new connection
    func register(_ connection: Connection) {
        let previous = connections[connection.pairId]?[connection.deviceType]
        if connections[connection.pairId] == nil {
            connections[connection.pairId] = [:]
        }
        connections[connection.pairId]?[connection.deviceType] = connection
        if previous?.webSocket !== connection.webSocket {
            previous?.close()
        }
    }

    /// Unregister a connection only if the currently-registered connection for
    /// this `(pairId, deviceType)` is the given WebSocket instance.
    ///
    /// A device that reconnects — e.g. a viewer after switching networks — opens
    /// a fresh socket and `register`s it, replacing the old entry in place. The
    /// old socket's `onClose` can then fire much later: a half-open TCP connection
    /// takes seconds-to-minutes to surface as closed. Unregistering unconditionally
    /// at that point would evict the *live* replacement connection and (via the
    /// caller's `notifyConnection`) tell the peer the device disconnected —
    /// flipping the peer's `isViewerConnected`/`isHostConnected` to false while the
    /// device is actually still connected. Gating on socket identity makes a stale
    /// close a no-op.
    ///
    /// - Returns: `true` if the current connection was removed, `false` if a newer
    ///   connection had already replaced it (so the caller can skip notifying the peer).
    func unregisterIfCurrent(pairId: String, deviceType: DeviceType, webSocket: WebSocket) -> Bool {
        guard
            let current = connections[pairId]?[deviceType],
            current.webSocket === webSocket
        else {
            return false
        }

        connections[pairId]?[deviceType] = nil
        if connections[pairId]?.isEmpty == true {
            connections.removeValue(forKey: pairId)
        }
        return true
    }

    /// Whether this socket still owns routing for its device in the pair.
    func isCurrent(pairId: String, deviceType: DeviceType, webSocket: WebSocket) -> Bool {
        connections[pairId]?[deviceType]?.webSocket === webSocket
    }

    /// Close and remove a single device's connection for a pair (used by the
    /// licensing sweep to evict hosts whose entitlement lapsed mid-connection).
    func disconnect(pairId: String, deviceType: DeviceType) {
        guard let connection = connections[pairId]?[deviceType] else { return }
        // Remove ownership before closing so the close callback cannot report
        // a replacement connection offline.
        connections[pairId]?[deviceType] = nil
        if connections[pairId]?.isEmpty == true {
            connections.removeValue(forKey: pairId)
        }
        connection.close()
    }

    /// Disconnect all connections for a pair
    func disconnectAll(pairId: String) {
        guard let pairConnections = connections[pairId] else { return }

        connections.removeValue(forKey: pairId)
        for connection in pairConnections.values {
            connection.close()
        }
    }

    /// Check if a device type is currently blocked from connecting (for E2E testing)
    func isBlocked(deviceType: DeviceType) -> Bool {
        blockedDeviceTypes.contains(deviceType)
    }

    /// Block a device type from connecting (for E2E testing).
    /// Existing connections are disconnected and new connections are rejected.
    ///
    /// - Returns: the pair IDs whose connection was removed (see `disconnectAll(deviceType:)`).
    @discardableResult
    func blockDeviceType(_ deviceType: DeviceType) -> [String] {
        blockedDeviceTypes.insert(deviceType)
        let affectedPairIds = disconnectAll(deviceType: deviceType)
        logger.info("Blocked device type: \(deviceType)")
        return affectedPairIds
    }

    /// Unblock a device type, allowing connections again (for E2E testing)
    func unblockDeviceType(_ deviceType: DeviceType) {
        blockedDeviceTypes.remove(deviceType)
        logger.info("Unblocked device type: \(deviceType)")
    }

    /// Clear all blocked device types (for E2E testing cleanup)
    func clearBlockedDeviceTypes() {
        blockedDeviceTypes.removeAll()
    }

    /// Disconnect all connections of a given device type across all pairs (for E2E testing).
    ///
    /// This is a server-initiated teardown: unlike a real socket close — handled by
    /// `WebSocketController`'s `onClose`, which owns `RelayService` and notifies the peer —
    /// this removes the entry directly. The `onClose` that fires later for each closed
    /// socket therefore finds nothing current and, by design (`unregisterIfCurrent`), stays
    /// silent. Returning the affected pair IDs lets the caller drive the same
    /// `notifyConnection` a real disconnect would, so peers still learn the device left.
    ///
    /// - Returns: the pair IDs whose connection of this type was removed.
    @discardableResult
    func disconnectAll(deviceType: DeviceType) -> [String] {
        var affectedPairIds: [String] = []
        for (pairId, pairConnections) in connections {
            guard let connection = pairConnections[deviceType] else { continue }
            connections[pairId]?[deviceType] = nil
            if connections[pairId]?.isEmpty == true {
                connections.removeValue(forKey: pairId)
            }
            affectedPairIds.append(pairId)
            connection.close()
        }
        return affectedPairIds
    }

    // MARK: - Connection Status

    /// Check if host is connected for a pair
    func isHostConnected(pairId: String) -> Bool {
        connections[pairId]?[.host] != nil
    }

    /// Check if viewer is connected for a pair
    func isViewerConnected(pairId: String) -> Bool {
        connections[pairId]?[.viewer] != nil
    }

    /// Aggregate count of active connections by device type across all pairs.
    ///
    /// O(pairs); fine while pair counts stay small. If this becomes hot, swap
    /// the iteration for cached `host`/`viewer` fields maintained inside
    /// `register` / `unregister` / `disconnectAll`.
    func connectionCounts() -> ConnectionCounts {
        var host = 0
        var viewer = 0
        for pairConnections in connections.values {
            if pairConnections[.host] != nil { host += 1 }
            if pairConnections[.viewer] != nil { viewer += 1 }
        }
        return ConnectionCounts(host: host, viewer: viewer)
    }

    /// Get connection for a specific device
    func getConnection(pairId: String, deviceType: DeviceType) -> Connection? {
        connections[pairId]?[deviceType]
    }

    // MARK: - Sending Messages

    /// Send a message to a specific device
    func send(_ message: WebSocketMessage, to pairId: String, deviceType: DeviceType) async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(message)
            await sendEncoded(
                data,
                to: pairId,
                deviceType: deviceType,
                messageType: message.messageType
            )
        } catch {
            logger.error("Failed to encode message", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "error": "\(error)",
            ])
        }
    }

    /// Sends a validated encrypted frame without decoding and re-encoding its
    /// base64 ciphertext. The bytes received from the sender remain unchanged.
    func sendRawEncryptedFrame(
        _ data: Data,
        kind: RelayFrameKind,
        to pairId: String,
        deviceType: DeviceType,
        sender: DeviceType,
        sourceWebSocket: WebSocket
    ) async {
        // Recheck at the actual send boundary. A replacement can arrive while
        // envelope validation or RelayService's actor calls are suspended.
        guard isCurrent(pairId: pairId, deviceType: sender, webSocket: sourceWebSocket) else { return }
        await sendEncoded(
            data,
            to: pairId,
            deviceType: deviceType,
            messageType: "encrypted",
            frameKind: kind
        )
    }

    private func sendEncoded(
        _ data: Data,
        to pairId: String,
        deviceType: DeviceType,
        messageType: String,
        frameKind: RelayFrameKind? = nil
    ) async {
        guard let connection = connections[pairId]?[deviceType] else {
            logger.warning("Cannot send message - no connection", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "messageType": "\(messageType)",
            ])
            return
        }

        do {
            if frameKind == .binary {
                try await connection.webSocket.send(raw: data, opcode: .binary)
            } else {
                try await connection.webSocket.send(raw: data, opcode: .text)
            }
            logger.debug("Message sent", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "messageType": "\(messageType)",
            ])
        } catch {
            logger.error("Failed to send message, cleaning up dead connection", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "error": "\(error)",
            ])

            // Only evict if this is still the registered socket. The `await` above is
            // a suspension point: a concurrent reconnect (e.g. a viewer that switched
            // networks) may have replaced this entry with a live socket while the send
            // was failing on the old one. Evicting by (pairId, deviceType) here would
            // drop the fresh connection and falsely notify the peer of a disconnect.
            let removed = unregisterIfCurrent(pairId: pairId, deviceType: deviceType, webSocket: connection.webSocket)
            guard removed else { return }
            connection.close()

            // Notify the peer device that this device disconnected
            let peerDevice: DeviceType = deviceType == .host ? .viewer : .host
            let disconnectMessage: WebSocketMessage = deviceType == .host ? .hostDisconnected : .viewerDisconnected
            await send(disconnectMessage, to: pairId, deviceType: peerDevice)
        }
    }

    /// Broadcast a message to all devices in a pair except the sender
    func broadcast(_ message: WebSocketMessage, to pairId: String, excluding: DeviceType? = nil) async {
        guard let pairConnections = connections[pairId] else { return }

        for (deviceType, _) in pairConnections {
            if deviceType == excluding { continue }
            // Use send() which handles dead connection cleanup
            await send(message, to: pairId, deviceType: deviceType)
        }
    }
}
