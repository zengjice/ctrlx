import CtrlxNetworking
import Foundation
import NIOCore
import Vapor

/// Authenticated traffic and anonymous attempts never share a rate-limit bucket.
actor RelayAccessLimits {
    private struct Bucket {
        var start: ContinuousClock.Instant
        var count: Int
    }

    private var buckets: [String: Bucket] = [:]
    private let trustedProxyIPs: Set<String>

    init(trustedProxyIPs: String = "") throws {
        self.trustedProxyIPs = try Set(trustedProxyIPs.split(separator: ",").map {
            let value = String($0).trimmingCharacters(in: .whitespaces)
            guard let ip = try? SocketAddress(ipAddress: value, port: 0).ipAddress else {
                throw RelayConfigurationError.invalidTrustedProxyIP(value)
            }
            return ip
        })
    }

    nonisolated func clientIP(_ req: Request) -> String {
        guard let remote = req.remoteAddress?.ipAddress else { return "local" }
        guard trustedProxyIPs.contains(remote) else { return remote }
        var peer = remote
        // Walk from the socket towards the client, stopping at the first
        // untrusted hop. Never accept a client-supplied leftmost address blindly.
        let forwarded = req.headers["X-Forwarded-For"].joined(separator: ",")
        for part in forwarded.split(separator: ",", omittingEmptySubsequences: false).reversed() {
            guard trustedProxyIPs.contains(peer) else { break }
            guard let ip = try? SocketAddress(ipAddress: part.trimmingCharacters(in: .whitespaces), port: 0).ipAddress else { return remote }
            peer = ip
        }
        return peer
    }

    func checkAnonymous(_ req: Request, operation: String, limit: Int) throws {
        try check(operation + ":anonymous:" + clientIP(req), limit: limit)
    }

    func authenticate(
        _ req: Request, using service: RelayAccessService, operation: String, limit: Int,
        pairID: String? = nil, role: String? = nil, deviceID: String? = nil
    ) async throws -> RelayPrincipal {
        let principal: RelayPrincipal
        do {
            principal = try await service.authenticate(req.headers.bearerAuthorization?.token, pairID: pairID, role: role, deviceID: deviceID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkAnonymous(req, operation: operation, limit: limit)
            throw error
        }
        try check(operation + ":credential:" + principal.credentialHash, limit: limit)
        return principal
    }

    func check(_ key: String, limit: Int, now: ContinuousClock.Instant = .now) throws {
        if buckets.count >= 4_096 {
            buckets = buckets.filter { now - $0.value.start < .seconds(60) }
        }
        if var bucket = buckets[key], now - bucket.start < .seconds(60) {
            guard bucket.count < limit else { throw limited() }
            bucket.count += 1
            buckets[key] = bucket
        } else {
            guard buckets.count < 4_096 else { throw limited() }
            buckets[key] = Bucket(start: now, count: 1)
        }
    }

    private func limited() -> RelayAccessFailure {
        RelayAccessFailure(code: .rateLimited, message: "Too many Relay requests. Please wait a minute before trying again.")
    }
}

struct RelayAccessLimitsKey: StorageKey { typealias Value = RelayAccessLimits }

extension Application {
    var relayAccessLimits: RelayAccessLimits {
        storage[RelayAccessLimitsKey.self]!
    }
}
