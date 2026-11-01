import CtrlxNetworking
import Foundation
import NIOCore
import Testing
import Vapor
@testable import CtrlxExternalServerLib

@Suite("Relay access rate-limit isolation")
struct RelayAccessLimitsTests {
    @Test("Forwarded client addresses require an explicitly trusted socket peer")
    func trustedProxyAddresses() async throws {
        let app = try await Application.make(.testing)
        let limits = try RelayAccessLimits(trustedProxyIPs: "127.0.0.1, ::1")
        let trusted = try request(app, peer: "127.0.0.1", forwarded: "192.0.2.1, 198.51.100.8")
        #expect(limits.clientIP(trusted) == "198.51.100.8")
        let chain = try request(app, peer: "127.0.0.1", forwarded: "198.51.100.8, ::1")
        #expect(limits.clientIP(chain) == "198.51.100.8")
        let direct = try request(app, peer: "203.0.113.7", forwarded: "198.51.100.8")
        #expect(limits.clientIP(direct) == "203.0.113.7")
        let malformed = try request(app, peer: "127.0.0.1", forwarded: "invalid")
        #expect(limits.clientIP(malformed) == "127.0.0.1")
        #expect(try RelayAccessLimits().clientIP(trusted) == "127.0.0.1")
        #expect(throws: RelayConfigurationError.self) { try RelayAccessLimits(trustedProxyIPs: "0.0.0.0/0") }
        try await app.asyncShutdown()
    }

    @Test("Pairing attempts from different clients behind a trusted proxy have separate buckets")
    func anonymousClients() async throws {
        let app = try await Application.make(.testing)
        let limits = try RelayAccessLimits(trustedProxyIPs: "127.0.0.1")
        let first = try request(app, peer: "127.0.0.1", forwarded: "192.0.2.1")
        let second = try request(app, peer: "127.0.0.1", forwarded: "192.0.2.2")
        try await limits.checkAnonymous(first, operation: "pair", limit: 1)
        await #expect(throws: RelayAccessFailure.self) { try await limits.checkAnonymous(first, operation: "pair", limit: 1) }
        try await limits.checkAnonymous(second, operation: "pair", limit: 1)
        try await app.asyncShutdown()
    }

    @Test("Invalid credentials cannot consume a valid credential's bucket", arguments: ["register", "connect", "pair-access"])
    func authenticatedClients(operation: String) async throws {
        let app = try await Application.make(.testing)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-rate-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try await RelayAccessService.open(directory: directory)
        let first = try await service.createAccount(name: "first", monthlyBytes: 100)
        let second = try await service.createAccount(name: "second", monthlyBytes: 100)
        let limits = try RelayAccessLimits()
        let invalid = try request(app, peer: "127.0.0.1")
        for _ in 0..<2 {
            await #expect(throws: RelayAccessFailure.self) {
                try await limits.authenticate(invalid, using: service, operation: operation, limit: 1)
            }
        }
        let firstRequest = try request(app, peer: "127.0.0.1", token: first.key)
        let principal = try await limits.authenticate(firstRequest, using: service, operation: operation, limit: 1)
        #expect(principal.accountID == first.accountID)
        await #expect(throws: RelayAccessFailure.self) {
            try await limits.authenticate(firstRequest, using: service, operation: operation, limit: 1)
        }
        let secondRequest = try request(app, peer: "127.0.0.1", token: second.key)
        #expect(try await limits.authenticate(secondRequest, using: service, operation: operation, limit: 1).accountID == second.accountID)
        try await service.shutdown()
        try await app.asyncShutdown()
    }

    private func request(_ app: Application, peer: String, forwarded: String? = nil, token: String? = nil) throws -> Request {
        var headers = HTTPHeaders()
        if let forwarded {
            headers.add(name: "X-Forwarded-For", value: forwarded)
        }
        if let token {
            headers.bearerAuthorization = .init(token: token)
        }
        return try Request(application: app, method: .GET, url: "/", headers: headers, remoteAddress: SocketAddress(ipAddress: peer, port: 1_234), on: app.eventLoopGroup.next())
    }
}
