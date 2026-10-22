import Dependencies
import DependenciesMacros
import Foundation

/// Bounded reads for provider configuration. Contents must never be logged or
/// forwarded to Viewers; providers extract only identity/display metadata.
@DependencyClient
public struct AccountConfigurationClient: Sendable {
    public var read: @Sendable (_ url: URL) async throws -> Data?
}

extension AccountConfigurationClient: DependencyKey {
    public static let liveValue = Self(read: { url in
        try await Task.detached {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            return data
        }.value
    })
}
