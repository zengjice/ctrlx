import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct AgentResumeExecutableClient: Sendable {
    public var resolve: @Sendable (_ recorded: String?, _ configured: String) async throws -> String
}

extension AgentResumeExecutableClient: DependencyKey {
    public static let liveValue = live(inheritedPath: ProcessInfo.processInfo.environment["PATH"], isExecutable: {
        FileManager.default.isExecutableFile(atPath: $0)
    })

    public static let testValue = Self(resolve: { recorded, configured in recorded ?? configured })

    static func live(inheritedPath: String?, isExecutable: @escaping @Sendable (String) -> Bool) -> Self {
        Self(resolve: { recorded, configured in
            if let recorded, recorded.hasPrefix("/"), isExecutable(recorded) {
                return recorded
            }
            guard !configured.isEmpty else { throw ProcessRunnerError.executableNotFound(path: configured) }
            if configured.hasPrefix("/"), isExecutable(configured) {
                return configured
            }
            if !configured.contains("/") {
                #if os(macOS)
                    @Dependency(LoginShellPath.self) var shellPath
                    let path = ProcessRunner.effectivePath(resolved: shellPath.resolve(), inherited: inheritedPath)
                #else
                    let path = inheritedPath ?? ""
                #endif
                for root in path.split(separator: ":") where root.hasPrefix("/") {
                    let candidate = URL(fileURLWithPath: String(root)).appendingPathComponent(configured).path
                    if isExecutable(candidate) {
                        return candidate
                    }
                }
            }
            throw ProcessRunnerError.executableNotFound(path: configured)
        })
    }
}
