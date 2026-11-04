@preconcurrency import APNS
@preconcurrency import APNSCore
import CtrlxNetworking
import Foundation
import Logging
import NIOCore
import NIOPosix
@preconcurrency import VaporAPNS

/// Sends push notifications to iOS devices via APNs
actor APNsService {
    private let client: APNSClient<JSONDecoder, JSONEncoder>?
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let access: RelayAccessService?
    private let metricsService: MetricsService
    private let logger = Logger(label: "apns-service")
    private let bundleId: String

    /// Latest per-host needs-attention contribution to the iOS app badge,
    /// keyed by pairId. The APS `aps.badge` we send is the sum across every
    /// pair that maps to the same APNs device token, so a single iOS device
    /// paired with multiple Macs sees the *total* unhandled count rather than
    /// last-write-wins. In-memory only: if the server restarts, each Mac's
    /// next push re-establishes its entry (Macs always send their current
    /// `pendingSessionCount`).
    private var lastBadge: [String: Int] = [:]

    /// E2E-test mode: when non-nil, every outgoing push is appended as a JSON
    /// line to this file *instead of* being sent over the wire (the real APNs
    /// client is also nil in E2E since no key/team is configured). Lets E2E
    /// scenarios assert on what the relay would have sent — including the
    /// aggregated `aps.badge` and the `apns-push-type` chosen for silent vs.
    /// alert pushes. Mirrors the Mac-side `TerminalNotificationService.e2eTest`
    /// pattern, just plumbed via env var because the relay doesn't use the
    /// Point-Free Dependencies library.
    private let e2eLogPath: String?

    // MARK: - Initialization

    init(
        pairingService: PairingService,
        connectionHub: ConnectionHub,
        metricsService: MetricsService,
        access: RelayAccessService? = nil,
        keyPath: String? = nil,
        keyId: String? = nil,
        teamId: String? = nil,
        bundleId: String? = nil,
        environment: APNSEnvironment = .development,
        e2eLogPath: String? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
        self.metricsService = metricsService
        self.access = access
        self.bundleId = bundleId
            ?? processEnvironment["APNS_BUNDLE_ID"]
            ?? "com.jicezeng.ctrlx"
        self.e2eLogPath = e2eLogPath
            ?? processEnvironment["APNS_E2E_LOG_PATH"]

        // Get config from environment or parameters
        let resolvedKeyPath = keyPath ?? processEnvironment["APNS_KEY_PATH"]
        let resolvedKeyId = keyId ?? processEnvironment["APNS_KEY_ID"]
        let resolvedTeamId = teamId ?? processEnvironment["APNS_TEAM_ID"]

        guard
            let keyPath = resolvedKeyPath,
            let keyId = resolvedKeyId,
            let teamId = resolvedTeamId
        else {
            logger.warning("APNs not configured - missing APNS_KEY_PATH, APNS_KEY_ID, or APNS_TEAM_ID environment variables")
            self.client = nil
            return
        }

        do {
            let keyData = try String(contentsOfFile: keyPath, encoding: .utf8)

            let configuration = try APNSClientConfiguration(
                authenticationMethod: .jwt(
                    privateKey: .loadFrom(string: keyData),
                    keyIdentifier: keyId,
                    teamIdentifier: teamId
                ),
                environment: environment
            )

            self.client = APNSClient(
                configuration: configuration,
                eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
                responseDecoder: JSONDecoder(),
                requestEncoder: JSONEncoder()
            )
            logger.info("APNs client initialized successfully", metadata: [
                "environment": "\(environment)",
                "bundleId": "\(self.bundleId)",
            ])
        } catch {
            logger.error("Failed to initialize APNs client: \(error)")
            self.client = nil
        }
    }

    // MARK: - Public API

    /// Check if APNs is configured and ready
    var isConfigured: Bool {
        client != nil
    }

    /// Send an encrypted push notification.
    /// Delivery depends on the registered APNs token, never Viewer socket presence.
    ///
    /// The notification is sent with `mutable-content: 1` so the iOS Notification
    /// Service Extension can intercept it, decrypt the payload, and update the
    /// notification with the decrypted title/body.
    ///
    /// - Parameters:
    ///   - payload: The encrypted push payload from Mac
    ///   - pairId: The pair ID for token lookup
    func sendEncryptedNotification(payload: EncryptedPushPayload, pairId: String) async {
        guard let deviceToken = await pairingService.getPushToken(for: pairId) else {
            logger.debug("No push token for pair", metadata: ["pairId": "\(pairId)"])
            return
        }

        // The aggregation block runs in both production and E2E. In E2E the
        // real `client` is nil (no APNs key/team configured), so we'd normally
        // bail here — but we still want to exercise the badge-aggregation logic
        // and record what would have been sent. Production paths still hit the
        // `client.send(...)` branches below; E2E paths short-circuit to the log
        // file and never touch the network.
        let isE2EMode = e2eLogPath != nil
        if client == nil, !isE2EMode {
            logger.warning("APNs client not configured, cannot send notification")
            return
        }

        // Aggregate this host's contribution into the device-wide badge by
        // summing over every pair that shares the same APNs device token.
        // Hosts that haven't reported a count yet (nil entries) are treated as
        // zero — accurate, since "haven't reported" means we have no evidence
        // of unhandled work from that Mac.
        let aggregatedBadge: Int?
        if let hostBadge = payload.badge {
            lastBadge[pairId] = hostBadge
            let siblingPairs = await pairingService.pairIds(withToken: deviceToken)
            aggregatedBadge = siblingPairs.compactMap { lastBadge[$0] }.reduce(0, +)
        } else {
            aggregatedBadge = nil
        }

        // Encode the encrypted content for the payload
        let encryptedPayload: EncryptedCtrlxPayload
        do {
            let encoder = JSONEncoder()
            let encryptedData = try encoder.encode(payload.encryptedContent)
            encryptedPayload = EncryptedCtrlxPayload(
                encrypted: encryptedData.base64EncodedString(),
                pairId: pairId
            )
        } catch {
            logger.error("Failed to encode encrypted payload: \(error)")
            return
        }

        let badgeRequest = payload.silent ? EncryptedBadgeNotification(
            badge: aggregatedBadge, payload: encryptedPayload
        ).request(deviceToken: deviceToken, topic: bundleId) : nil

        if isE2EMode {
            do {
                if payload.silent {
                    try await authorizePush(EncryptedBadgeNotification(badge: aggregatedBadge, payload: encryptedPayload), pairID: pairId)
                } else {
                    let notification = APNSAlertNotification(
                        alert: APNSAlertNotificationContent(title: .raw("CtrlX"), body: .raw("New activity")),
                        expiration: .immediately,
                        priority: .immediately,
                        topic: bundleId,
                        payload: encryptedPayload,
                        badge: aggregatedBadge,
                        sound: nil,
                        mutableContent: 1
                    )
                    try await authorizePush(notification, pairID: pairId)
                }
            } catch { return }
            recordE2EPush(
                pairId: pairId,
                deviceToken: deviceToken,
                hostBadge: payload.badge,
                aggregatedBadge: aggregatedBadge,
                silent: payload.silent,
                pushType: badgeRequest?.headers["apns-push-type"] ?? "alert"
            )
            await metricsService.incrementPushNotifications()
            return
        }

        guard let client else { return } // Cannot happen here — guarded above.

        do {
            if let badgeRequest {
                try await authorizePush(badgeRequest.message, pairID: pairId)
                _ = try await client.send(badgeRequest)
            } else {
                let alert = APNSAlertNotificationContent(
                    // Agent-neutral placeholder; the iOS Notification Service
                    // Extension decrypts and replaces both title and body.
                    title: .raw("CtrlX"),
                    body: .raw("New activity") // Placeholder - extension replaces this
                )
                let notification = APNSAlertNotification(
                    alert: alert,
                    expiration: .immediately,
                    priority: .immediately,
                    topic: bundleId,
                    payload: encryptedPayload,
                    badge: aggregatedBadge,
                    sound: nil,
                    mutableContent: 1 // Triggers Notification Service Extension
                )
                try await authorizePush(notification, pairID: pairId)
                _ = try await client.sendAlertNotification(
                    notification,
                    deviceToken: deviceToken
                )
            }
            await metricsService.incrementPushNotifications()
            logger.info("Encrypted push notification sent", metadata: [
                "pairId": "\(pairId)",
                "silent": "\(payload.silent)",
                "hostBadge": "\(payload.badge.map(String.init) ?? "nil")",
                "aggregatedBadge": "\(aggregatedBadge.map(String.init) ?? "nil")",
            ])
        } catch let error as APNSError {
            handleAPNsError(error, pairId: pairId, deviceToken: deviceToken)
        } catch {
            logger.error("Failed to send encrypted push notification: \(error)")
        }
    }

    private func authorizePush(_ notification: some Encodable, pairID: String) async throws {
        guard let access else { return }
        guard
            let connection = await connectionHub.getConnection(pairId: pairID, deviceType: .host),
            let principal = connection.principal else {
            throw RelayAccessFailure(code: .authenticationRequired, message: "An authenticated Host is required for push delivery.")
        }
        do {
            let data = try JSONEncoder().encode(notification)
            _ = try await access.admit(principal, bytes: data.count)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await connectionHub.rejectAccess(relayAccessFailure(error), pairID: pairID, accountID: principal.accountID, sourceWebSocket: connection.webSocket)
            throw error
        }
        try Task.checkCancellation()
    }

    /// Append a JSON-line record of an outgoing push to the E2E log file.
    /// Format matches what scenarios assert on; see `APNsPushLogEntry` below.
    private func recordE2EPush(
        pairId: String,
        deviceToken: String,
        hostBadge: Int?,
        aggregatedBadge: Int?,
        silent: Bool,
        pushType: String
    ) {
        guard let path = e2eLogPath else { return }
        let entry = APNsPushLogEntry(
            timestamp: Date().timeIntervalSince1970,
            pairId: pairId,
            deviceToken: deviceToken,
            hostBadge: hostBadge,
            aggregatedBadge: aggregatedBadge,
            silent: silent,
            pushType: pushType
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            let data = try encoder.encode(entry)
            var line = data
            line.append(0x0A) // newline
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                FileManager.default.createFile(atPath: path, contents: line)
            }
        } catch {
            logger.error("Failed to write E2E push log entry: \(error)")
        }
    }

    /// Drop the per-host badge contribution for a pair. Called when a pair is
    /// removed (via the unpair endpoint, `resetState`, or a `BadDeviceToken`
    /// response from APNs) so the stale entry doesn't linger in memory.
    func clearBadge(pairId: String) {
        lastBadge.removeValue(forKey: pairId)
    }

    /// Graceful shutdown
    func shutdown() async {
        logger.info("APNs service shutting down")
        do {
            try await client?.shutdown()
        } catch {
            logger.error("Failed to shut down APNs client: \(error)")
        }
    }

    // MARK: - Private Helpers

    /// Handle APNs-specific errors
    private func handleAPNsError(_ error: APNSError, pairId: String, deviceToken: String) {
        logger.error("APNs error: \(error)", metadata: [
            "pairId": "\(pairId)",
            "responseStatus": "\(error.responseStatus)",
        ])

        // Check for errors that indicate the token is invalid
        if let reason = error.reason?.reason {
            // reason is a String, check for known invalid token errors
            if reason == "BadDeviceToken" || reason == "Unregistered" {
                // Device token is no longer valid, remove it and stop counting
                // this pair toward the aggregated badge total.
                lastBadge.removeValue(forKey: pairId)
                Task {
                    await pairingService.removePushToken(for: pairId)
                    logger.warning("Removed invalid push token for pair", metadata: ["pairId": "\(pairId)"])
                }
            }
            // Note: pair-removed cleanup of `lastBadge` is wired through
            // `PairingService.setOnPairRemoved` in `configure(_:)`.
        }
    }
}

// MARK: - Custom Payloads

/// One line in the E2E push log: a record of what the relay would have sent
/// to APNs. The same shape is decoded on the test side to assert on badge
/// values and push types across the aggregation scenarios.
public struct APNsPushLogEntry: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let pairId: String
    public let deviceToken: String
    public let hostBadge: Int?
    public let aggregatedBadge: Int?
    public let silent: Bool
    public let pushType: String

    public init(
        timestamp: TimeInterval,
        pairId: String,
        deviceToken: String,
        hostBadge: Int?,
        aggregatedBadge: Int?,
        silent: Bool,
        pushType: String
    ) {
        self.timestamp = timestamp
        self.pairId = pairId
        self.deviceToken = deviceToken
        self.hostBadge = hostBadge
        self.aggregatedBadge = aggregatedBadge
        self.silent = silent
        self.pushType = pushType
    }
}

/// Custom payload for encrypted Ctrlx push notifications.
///
/// The `encrypted` field contains a Base64-encoded JSON representation of
/// `EncryptedPayload` from CtrlxEncryption. The iOS Notification Service
/// Extension decodes and decrypts this to get the actual notification content.
struct EncryptedCtrlxPayload: Codable {
    /// Base64-encoded JSON of EncryptedPayload
    let encrypted: String

    /// Pair ID for reference (also in encrypted content)
    let pairId: String
}

/// A badge is a user-visible update, so APNs requires the alert push type.
/// Omitting alert, sound and content-available lets iOS apply it without a wake.
struct EncryptedBadgeNotification: APNSMessage {
    struct APS: Encodable {
        let badge: Int?
    }

    enum CodingKeys: CodingKey {
        case aps
    }

    let badge: Int?
    let payload: EncryptedCtrlxPayload

    func request(deviceToken: String, topic: String) -> APNSRequest<Self> {
        APNSRequest(
            message: self, deviceToken: deviceToken, pushType: .alert,
            expiration: .immediately, priority: .consideringDevicePower,
            apnsID: nil, topic: topic, collapseID: nil
        )
    }

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(APS(badge: badge), forKey: .aps)
    }
}
