import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct AgentPluginResourceClient: Sendable {
    public var version: @Sendable (_ manifest: URL) async throws -> String
    public var publishSessionSkills: @Sendable (_ skills: URL, _ stateDirectory: URL) async throws -> Void

    private static let missingSkillsPrefix = "missing + hooks "

    /// Keep the installed hook component visible without inventing a skills version
    /// or adding a new case to the installation wire enum.
    public static func hooksOnlyVersion(_ hooks: String?) -> String {
        missingSkillsPrefix + (hooks ?? "unknown")
    }

    public static func hooksVersionIfSkillsMissing(_ version: String?) -> String? {
        guard let version, version.hasPrefix(missingSkillsPrefix) else { return nil }
        let hooks = String(version.dropFirst(missingSkillsPrefix.count))
        return isVersion(hooks) || hooks == "unknown" ? hooks : nil
    }

    public static func combinedVersion(skills: String?, hooks: String?) -> String? {
        guard let skills, let hooks, isVersion(skills), isVersion(hooks) else { return nil }
        return "\(skills) + hooks \(hooks)"
    }

    /// Bundled plugins currently use stable numeric versions. Unknown formats
    /// must not be reported as up to date or as an available downgrade.
    public static func isVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && Int($0) != nil }
    }

    public static func updateAvailable(installed: String?, bundled: String) -> Bool {
        guard let installed else { return false }
        var current = installed.components(separatedBy: " + hooks ")
        let target = bundled.components(separatedBy: " + hooks ")
        guard (1...2).contains(target.count), target.allSatisfy(isVersion) else { return false }
        if target.count == 2, hooksVersionIfSkillsMissing(installed) != nil {
            return true
        }
        guard current.allSatisfy(isVersion) else { return false }
        // A legacy single-plugin installation still needs the separate bridge.
        if target.count == 2, current.count == 1 {
            current.append("0.0.0")
        }
        guard current.count == target.count else { return false }
        return zip(current, target).contains { VersionCompatibility.compare($0, $1) == .orderedAscending }
    }
}

extension AgentPluginResourceClient: DependencyKey {
    public static let liveValue = Self(version: { url in
        try await Task.detached {
            struct Manifest: Decodable { let name: String
                let version: String
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            guard ["ctrlx", "ctrlx-hooks"].contains(manifest.name), isVersion(manifest.version) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return manifest.version
        }.value
    }, publishSessionSkills: { skills, directory in
        try await Task.detached {
            guard FileManager.default.fileExists(atPath: skills.appendingPathComponent("file-links/SKILL.md").path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try skills.standardizedFileURL.path.write(to: directory.appendingPathComponent("session-skills-root"), atomically: true, encoding: .utf8)
        }.value
    })
}
