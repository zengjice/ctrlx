import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

/// Credentials are scoped to a normalized Relay origin and base path. Pair
/// roles are separate even when this Mac is both Host and Viewer.
@DependencyClient
public struct RelayCredentials: Sendable {
    public var load: @Sendable (_ server: String, _ pairID: String?, _ role: String?) async throws -> String?
    public var save: @Sendable (_ token: String, _ server: String, _ pairID: String?, _ role: String?) async throws -> Void
    public var delete: @Sendable (_ server: String, _ pairID: String?, _ role: String?) async throws -> Void

    public static func storageKey(server: String, pairID: String?, role: String?) throws -> String {
        guard
            var components = URLComponents(string: server), let originalScheme = components.scheme?.lowercased(),
            ["http", "https", "ws", "wss"].contains(originalScheme), let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw URLError(.badURL)
        }
        components.scheme = ["https", "wss"].contains(originalScheme) ? "https" : "http"
        components.host = host.lowercased()
        if components.port == (components.scheme == "https" ? 443 : 80) {
            components.port = nil
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard
            let origin = components.string, (pairID == nil) == (role == nil),
            role == nil || role == "host" || role == "viewer" else { throw URLError(.badURL) }
        let scope = [origin, pairID ?? "", role ?? "account"]
        // Each component is encoded separately to avoid delimiter collisions.
        return "ctrlx.relay." + scope.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    public static func requireSecureTransport(_ server: String) throws {
        guard
            let components = URLComponents(string: server),
            ["https", "wss"].contains(components.scheme?.lowercased() ?? "") ||
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(components.host?.lowercased() ?? "") else {
            throw RelayAccessFailure(code: .accessDenied, message: "Use HTTPS or WSS for authenticated Relay access. HTTP is allowed only on loopback.")
        }
    }

    public func authorize(_ request: inout URLRequest, server: String, pairID: String? = nil, role: String? = nil) async throws {
        if let token = try await load(server, pairID, role) {
            try Self.requireSecureTransport(server)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

extension RelayCredentials: DependencyKey {
    public static func inMemory() -> Self {
        withDependencies {
            $0[SecretsService.self] = .inMemory()
        } operation: {
            .liveValue
        }
    }

    public static var liveValue: RelayCredentials {
        @Dependency(SecretsService.self) var secrets
        return RelayCredentials(
            load: { server, pairID, role in
                try await secrets.loadSecret(storageKey(server: server, pairID: pairID, role: role))
            },
            save: { token, server, pairID, role in
                try requireSecureTransport(server)
                try await secrets.storeSecret(token, storageKey(server: server, pairID: pairID, role: role))
            },
            delete: { server, pairID, role in
                try await secrets.deleteSecret(storageKey(server: server, pairID: pairID, role: role))
            }
        )
    }
}

@DependencyClient
public struct RelayAccessClient: Sendable {
    public var status: @Sendable (_ server: String, _ pairID: String?, _ role: String?) async throws -> RelayAccessStatus
    public var removePair: @Sendable (_ server: String, _ pairID: String, _ role: String) async throws -> Void
    public var validateKey: @Sendable (_ server: String, _ key: String) async throws -> RelayAccessStatus
}

extension RelayAccessClient: DependencyKey {
    public static var liveValue: RelayAccessClient {
        @Dependency(RelayCredentials.self) var credentials
        return RelayAccessClient(
            status: { server, pairID, role in
                _ = try RelayCredentials.storageKey(server: server, pairID: pairID, role: role)
                let token = try await credentials.load(server, pairID, role)
                return try await fetch(server: server, token: token, verifyAccount: false)
            },
            removePair: { server, pairID, role in
                guard let url = URL(string: server.httpURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/pairing/" + pairID) else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.timeoutInterval = 10
                do {
                    try await credentials.authorize(&request, server: server, pairID: pairID, role: role)
                    let (_, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                } catch {
                    try await credentials.delete(server, pairID, role)
                    throw error
                }
                try await credentials.delete(server, pairID, role)
            },
            validateKey: { server, key in
                let result = try await fetch(server: server, token: key, verifyAccount: true)
                if let failure = result.failure {
                    throw failure
                }
                guard result.metered, result.quota != nil else {
                    throw RelayAccessFailure(code: .accessDenied, message: "This Relay does not accept account access keys.")
                }
                return result
            }
        )
    }

    private static func fetch(server: String, token: String?, verifyAccount: Bool) async throws -> RelayAccessStatus {
        _ = try RelayCredentials.storageKey(server: server, pairID: nil, role: nil)
        guard var components = URLComponents(string: server.httpURL) else { throw URLError(.badURL) }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.path += "/api/access/status"
        if verifyAccount {
            components.queryItems = [URLQueryItem(name: "role", value: "account")]
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token {
            try RelayCredentials.requireSecureTransport(server)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Older relays have no quota endpoint. This only hides unsupported UI;
        // each Relay still decides authorization on every business connection.
        if http.statusCode == 404, !verifyAccount {
            return RelayAccessStatus(metered: false)
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RelayAccessStatus.self, from: data)
    }
}
