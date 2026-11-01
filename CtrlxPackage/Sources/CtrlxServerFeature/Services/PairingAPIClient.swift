import CtrlxCommon
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

/// HTTP client for the relay's /api/pairing endpoints used by the host
/// during pairing (register a code, poll for completion, delete a pair).
///
/// Extracted from `PairingManager` so pairing flows are testable without
/// real network access (the default server URL is the production relay).
@DependencyClient
public struct PairingAPIClient: Sendable {
    public var register: @Sendable (
        _ serverURL: String, _ registration: PairingRegistration
    ) async throws -> PairingResponse
    public var status: @Sendable (_ serverURL: String, _ pairId: String) async throws -> PairingStatus
    public var delete: @Sendable (_ serverURL: String, _ pairId: String) async throws -> Void
}

extension PairingAPIClient: DependencyKey {
    public static var liveValue: PairingAPIClient {
        @Dependency(RelayCredentials.self) var credentials
        @Sendable
        func request(
            serverURL: String, path: String, method: String, body: Data? = nil, pairID: String? = nil
        ) async throws -> Data {
            guard let url = URL(string: "\(serverURL.httpURL)\(path)") else {
                throw PairingError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            try await credentials.authorize(&request, server: serverURL, pairID: pairID, role: pairID == nil ? nil : "host")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PairingError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw PairingError.serverError(statusCode: httpResponse.statusCode)
            }
            return data
        }

        return PairingAPIClient(
            register: { serverURL, registration in
                let body = try JSONEncoder().encode(registration)
                let data = try await request(
                    serverURL: serverURL, path: "/api/pairing/register", method: "POST", body: body
                )
                let response = try JSONDecoder().decode(PairingResponse.self, from: data)
                if case let .registered(info) = response, let token = info.relayCredential {
                    try await credentials.save(token, serverURL, info.pairId, "host")
                }
                return response
            },
            status: { serverURL, pairId in
                let data = try await request(
                    serverURL: serverURL, path: "/api/pairing/\(pairId)/status", method: "GET", pairID: pairId
                )
                return try JSONDecoder().decode(PairingStatus.self, from: data)
            },
            delete: { serverURL, pairId in
                _ = try await request(
                    serverURL: serverURL, path: "/api/pairing/\(pairId)", method: "DELETE", pairID: pairId
                )
                try await credentials.delete(serverURL, pairId, "host")
            }
        )
    }
}
