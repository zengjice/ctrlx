/// Built-in CLI admission ranges. Workflow and automatic resume use the same
/// bounds; hook, native conversation and input checks remain separate.
public struct AgentCLIVersionPolicy: Sendable {
    public static let codex = Self(name: "codex-cli", prefix: "codex-cli ", major: 0, minor: 160...179)
    public static let claudeCode = Self(name: "Claude Code", suffix: " (Claude Code)", major: 2, minor: 1...1, patch: 300...399)
    public static let traex = Self(name: "traecli", prefix: "traecli ", major: 0, minor: 213...219)

    private let name: String
    private let prefix: String
    private let suffix: String
    private let major: Int
    private let minor: ClosedRange<Int>
    private let patch: ClosedRange<Int>?

    private init(name: String, prefix: String = "", suffix: String = "", major: Int, minor: ClosedRange<Int>, patch: ClosedRange<Int>? = nil) {
        self.name = name
        self.prefix = prefix
        self.suffix = suffix
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var supportedVersions: String {
        let lower = "\(major).\(minor.lowerBound).\(patch.map { String($0.lowerBound) } ?? "x")"
        let upper = "\(major).\(minor.upperBound).\(patch.map { String($0.upperBound) } ?? "x")"
        return "\(name) \(lower == upper ? lower : lower + "–" + upper) (stable)"
    }

    public func supports(_ version: String) -> Bool {
        guard version.hasPrefix(prefix), version.hasSuffix(suffix) else { return false }
        let number = version.dropFirst(prefix.count).dropLast(suffix.count)
        guard
            let match = number.wholeMatch(of: /(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/),
            let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return false }
        return major == self.major && self.minor.contains(minor) && (self.patch?.contains(patch) ?? true)
    }

    public func automaticResumeUnavailableReason(_ version: String?) -> String? {
        guard let version, supports(version) else {
            return "Automatic resume supports \(supportedVersions); found \(version ?? "unknown version"). Choose Resume to reopen it explicitly."
        }
        return nil
    }
}
