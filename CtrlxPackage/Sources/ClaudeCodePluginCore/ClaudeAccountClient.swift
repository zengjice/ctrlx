import CryptoKit
import CtrlxCommon
import Dependencies
import DependenciesMacros
import Foundation
#if os(macOS)
    import Security
#endif

@DependencyClient
struct ClaudeAccountClient: Sendable {
    var status: @Sendable (_ command: String, _ root: String, _ isDefault: Bool) async throws -> Data
    var token: @Sendable (_ root: String, _ isDefault: Bool) async throws -> String?
    var request: @Sendable (_ path: String, _ token: String) async throws -> Data
}

enum ClaudeAccountError: Error { case unavailable, authentication, oversized }

extension ClaudeAccountClient: DependencyKey {
    static let liveValue = Self(status: { command, root, isDefault in
        @Dependency(ProcessRunner.self) var process
        let args = isDefault ? ["-u", "CLAUDE_CONFIG_DIR", command, "auth", "status"] : [command, "auth", "status"]
        let result = try await process.runBounded("/usr/bin/env", args, isDefault ? nil : ["CLAUDE_CONFIG_DIR": root], 10, 1_048_576)
        guard !result.outputTruncated, !result.stdout.isEmpty else { throw ClaudeAccountError.unavailable }
        return result.stdout
    }, token: { root, isDefault in
        #if os(macOS)
            // Match the CLI's secure-storage namespace; never prompt for Keychain access.
            let environment = ProcessInfo.processInfo.environment
            guard
                environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil,
                environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil,
                environment["USE_STAGING_OAUTH"] == nil,
                environment["USE_LOCAL_OAUTH"] == nil,
                environment["ANTHROPIC_BASE_URL"] == nil else { throw ClaudeAccountError.unavailable }
            let suffix = isDefault ? "" : "-" + SHA256.hash(data: Data(root.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
            let service = "Claude Code-credentials" + suffix
            let credential = try await Task.detached {
                var result: CFTypeRef?
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
                ]
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound {
                    return Data?.none
                }
                guard status == errSecSuccess, let data = result as? Data else { throw ClaudeAccountError.unavailable }
                return data
            }.value
            @Dependency(AccountConfigurationClient.self) var files
            let bytes: Data?
            if let credential {
                bytes = credential
            } else {
                bytes = try await files.read(URL(fileURLWithPath: root).appendingPathComponent(".credentials.json"))
            }
            guard let bytes else { return nil }
            let stored = try JSONDecoder().decode(ClaudeCredential.self, from: bytes)
            return stored.claudeAiOauth?.accessToken
        #else
            throw ClaudeAccountError.unavailable
        #endif
    }, request: { path, token in
        guard
            ["/api/oauth/profile", "/api/oauth/usage"].contains(path),
            let url = URL(string: "https://api.anthropic.com" + path) else { throw ClaudeAccountError.unavailable }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: ClaudeAccountRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeAccountError.unavailable }
        if http.statusCode == 401 {
            throw ClaudeAccountError.authentication
        }
        guard http.statusCode == 200 else { throw ClaudeAccountError.unavailable }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < 1_048_576 else { throw ClaudeAccountError.oversized }
            bytes.append(byte)
        }
        return bytes
    })
}

private struct ClaudeCredential: Decodable {
    struct OAuth: Decodable { let accessToken: String }
    let claudeAiOauth: OAuth?
}

final private class ClaudeAccountRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
