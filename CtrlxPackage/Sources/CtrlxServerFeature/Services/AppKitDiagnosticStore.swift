import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct AppKitDiagnosticStore: Sendable {
    /// Must finish synchronously before AppKit resumes exception handling.
    var write: @Sendable (_ data: Data) throws -> URL
}

extension AppKitDiagnosticStore: DependencyKey {
    static let liveValue = Self(write: { data in
        try save(data, directory: directory())
    })
    static let testValue = Self()

    static func directory(
        arguments: [String] = CommandLine.arguments,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        if arguments.contains("--e2e-test") {
            guard let index = arguments.firstIndex(of: "--ctrlx-state-root"), index + 1 < arguments.count else {
                throw CocoaError(.fileNoSuchFile)
            }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                .appendingPathComponent("appkit-diagnostics", isDirectory: true)
        }
        return home.appendingPathComponent("Library/Logs/CtrlX/AppKit", isDirectory: true)
    }

    static func save(_ data: Data, directory: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let output = directory.appendingPathComponent("appkit-\(timestamp)-\(UUID().uuidString).json")
        try data.write(to: output, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let reports = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter {
                try $0.lastPathComponent != output.lastPathComponent && $0.lastPathComponent.hasPrefix("appkit-") && $0.pathExtension == "json"
                    && ($0.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in reports.dropFirst(4) {
            try files.removeItem(at: old)
        }
        return output
    }
}
