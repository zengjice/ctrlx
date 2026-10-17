import AppKit
import Dependencies
import DependenciesMacros
import Foundation

/// LaunchServices resolves application protocols on the browser's Host Mac.
@DependencyClient
struct ExternalApplicationClient: Sendable {
    var open: @MainActor @Sendable (_ url: URL) throws -> String
}

extension ExternalApplicationClient: DependencyKey {
    static let liveValue = Self(open: { url in
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            throw ExternalApplicationError("No app on the Host Mac can open \(url.scheme ?? "this") links.")
        }
        let name = FileManager.default.displayName(atPath: application.path)
        guard NSWorkspace.shared.open(url) else {
            throw ExternalApplicationError("Could not open \(name) on the Host Mac. Try opening the app manually, then click the link again.")
        }
        return name
    })

    static let testValue = Self()
}

private struct ExternalApplicationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        self.errorDescription = message
    }
}
