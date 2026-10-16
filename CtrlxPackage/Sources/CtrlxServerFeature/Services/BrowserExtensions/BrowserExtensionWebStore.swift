#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    enum BrowserExtensionWebStore {
        static func identifier(from input: String) throws -> String {
            let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if validID(input) {
                return input
            }
            guard
                let url = URL(string: input), url.scheme == "https", url.host == "chromewebstore.google.com",
                url.user == nil, url.password == nil, url.port == nil else {
                throw BrowserExtensionPackageError("Enter a Chrome Web Store extension link or its 32-letter ID.")
            }
            let parts = url.path.split(separator: "/")
            guard (2...3).contains(parts.count), parts.first == "detail", let last = parts.last, validID(String(last)) else {
                throw BrowserExtensionPackageError("The Chrome Web Store link does not identify an extension.")
            }
            return String(last)
        }

        static func downloadURL(identifier: String, chromiumVersion: String) throws -> URL {
            let versionParts = chromiumVersion.split(separator: ".", omittingEmptySubsequences: false)
            guard
                validID(identifier), versionParts.count == 4,
                versionParts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt32($0) != nil }) else {
                throw BrowserExtensionPackageError("The Host returned an invalid Chromium version or extension ID.")
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = "clients2.google.com"
            components.path = "/service/update2/crx"
            components.queryItems = [
                URLQueryItem(name: "response", value: "redirect"),
                URLQueryItem(name: "prodversion", value: chromiumVersion),
                URLQueryItem(name: "acceptformat", value: "crx3"),
                URLQueryItem(name: "x", value: "id=\(identifier)&uc"),
            ]
            guard let url = components.url else { throw BrowserExtensionPackageError("Could not create the store download URL.") }
            return url
        }

        static func allowedDownloadURL(_ url: URL) -> Bool {
            guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host else { return false }
            return host == "clients2.google.com" || host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".gvt1.com")
        }

        private static func validID(_ value: String) -> Bool {
            value.utf8.count == 32 && value.utf8.allSatisfy { (97...112).contains($0) }
        }
    }

    @DependencyClient
    struct BrowserExtensionDownloadClient: Sendable {
        var download: @Sendable (_ identifier: String, _ chromiumVersion: String) async throws -> Data
    }

    extension BrowserExtensionDownloadClient: DependencyKey {
        static let liveValue = Self(download: { identifier, version in
            let url = try BrowserExtensionWebStore.downloadURL(identifier: identifier, chromiumVersion: version)
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(from: url, delegate: ExtensionStoreRedirects())
            guard
                let response = response as? HTTPURLResponse, response.statusCode == 200,
                let finalURL = response.url, BrowserExtensionWebStore.allowedDownloadURL(finalURL) else {
                throw BrowserExtensionPackageError("Chrome Web Store did not provide a compatible extension package.")
            }
            let limit = BrowserExtensionPackage.Limits().archiveBytes
            guard response.expectedContentLength <= limit else {
                throw BrowserExtensionPackageError("The store package exceeds the compressed size limit.")
            }
            var data = Data()
            data.reserveCapacity(Int(max(0, response.expectedContentLength)))
            for try await byte in bytes {
                guard data.count < limit else { throw BrowserExtensionPackageError("The store package exceeds the compressed size limit.") }
                data.append(byte)
            }
            return data
        })
    }

    final private class ExtensionStoreRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, BrowserExtensionWebStore.allowedDownloadURL(url) else { return nil }
            return request
        }
    }
#endif
