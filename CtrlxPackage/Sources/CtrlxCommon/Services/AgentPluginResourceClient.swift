import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct AgentPluginResourceClient: Sendable {
    public var version: @Sendable (_ manifest: URL) async throws -> String

    /// Bundled plugins currently use stable numeric versions. Unknown formats
    /// must not be reported as up to date or as an available downgrade.
    public static func isVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && Int($0) != nil }
    }

    public static func updateAvailable(installed: String?, bundled: String) -> Bool {
        guard let installed, isVersion(installed), isVersion(bundled) else { return false }
        return VersionCompatibility.compare(installed, bundled) == .orderedAscending
    }
}

extension AgentPluginResourceClient: DependencyKey {
    public static let liveValue = Self(version: { url in
        try await Task.detached {
            struct Manifest: Decodable { let name: String
                let version: String
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            guard manifest.name == "ctrlx", isVersion(manifest.version) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return manifest.version
        }.value
    })
}
