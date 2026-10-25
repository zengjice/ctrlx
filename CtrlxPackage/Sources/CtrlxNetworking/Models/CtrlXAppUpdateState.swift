import Foundation

/// Host-owned state for the macOS CtrlX app update channel.
///
/// Viewers never receive or supply an installer URL. They observe this state
/// and ask the Host to install the exact version/build that the Host checked.
public struct CtrlXAppUpdateState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case idle
        case checking
        case upToDate
        case available
        case installing
        case failed
    }

    public let phase: Phase
    public let currentVersion: String
    public let currentBuild: String?
    public let latestVersion: String?
    public let latestBuild: String?
    public let latestBuildStamp: String?
    public let checkedAt: Date?
    public let canInstall: Bool
    public let error: String?

    public init(
        phase: Phase,
        currentVersion: String,
        currentBuild: String? = nil,
        latestVersion: String? = nil,
        latestBuild: String? = nil,
        latestBuildStamp: String? = nil,
        checkedAt: Date? = nil,
        canInstall: Bool = false,
        error: String? = nil
    ) {
        self.phase = phase
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.latestBuildStamp = latestBuildStamp
        self.checkedAt = checkedAt
        self.canInstall = canInstall
        self.error = error
    }

    public var updateAvailable: Bool {
        phase == .available
    }

    public var latestDisplayVersion: String {
        switch (latestVersion, latestBuild) {
        case let (.some(version), .some(build)):
            "\(version) (\(build))"
        case let (.some(version), .none):
            version
        case let (.none, .some(build)):
            "Build \(build)"
        case (.none, .none):
            "Unknown version"
        }
    }
}
