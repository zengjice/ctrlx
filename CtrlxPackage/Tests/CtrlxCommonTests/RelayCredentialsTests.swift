import CtrlxEncryption
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Relay credential isolation")
struct RelayCredentialsTests {
    @Test("In-memory credentials retain values per fixture without accessing Keychain")
    func inMemory() async throws {
        let first = RelayCredentials.inMemory()
        let second = RelayCredentials.inMemory()
        try await first.save("token", "wss://relay.example", "pair", "viewer")
        #expect(try await first.load("wss://relay.example", "pair", "viewer") == "token")
        #expect(try await second.load("wss://relay.example", "pair", "viewer") == nil)
        try await first.delete("wss://relay.example", "pair", "viewer")
        #expect(try await first.load("wss://relay.example", "pair", "viewer") == nil)
    }

    @Test("Equivalent URLs share credentials; another origin, role, base path or pair does not")
    func namespaces() async throws {
        try await withDependencies {
            $0[SecretsService.self] = .inMemory()
            $0[RelayCredentials.self] = .liveValue
        } operation: {
            @Dependency(RelayCredentials.self) var credentials
            try await credentials.save("account-secret", "wss://RELAY.example:443/", nil, nil)
            #expect(try await credentials.load("https://relay.example", nil, nil) == "account-secret")
            #expect(try await credentials.load("https://other.example", nil, nil) == nil)
            #expect(try await credentials.load("http://relay.example", nil, nil) == nil)
            #expect(try await credentials.load("https://relay.example/test", nil, nil) == nil)
            try await credentials.save("host-secret", "wss://relay.example", "pair", "host")
            #expect(try await credentials.load("https://relay.example/", "pair", "host") == "host-secret")
            #expect(try await credentials.load("https://relay.example", "pair", "viewer") == nil)
            #expect(try await credentials.load("https://relay.example", "another", "host") == nil)
            try await credentials.delete("https://relay.example", "pair", "host")
            #expect(try await credentials.load("https://relay.example", "pair", "host") == nil)
        }
    }

    @Test("Authenticated HTTP is limited to loopback; remote credentials require TLS")
    func secureTransport() throws {
        for url in ["https://relay.example", "wss://relay.example", "http://127.0.0.1:8841", "ws://localhost:8080", "http://[::1]:8080"] {
            try RelayCredentials.requireSecureTransport(url)
        }
        for url in ["http://relay.example", "ws://192.168.1.50:8080"] {
            #expect(throws: (any Error).self) { try RelayCredentials.requireSecureTransport(url) }
        }
    }

    @Test("Ambiguous URLs and role scopes are rejected before credential access")
    func invalidNamespaces() throws {
        for server in ["https://user:secret@relay.example", "https://relay.example?token=secret", "https://relay.example#fragment", "file:///tmp/relay"] {
            #expect(throws: (any Error).self) { try RelayCredentials.storageKey(server: server, pairID: nil, role: nil) }
        }
        #expect(throws: (any Error).self) { try RelayCredentials.storageKey(server: "https://relay.example", pairID: "pair", role: nil) }
    }
}
