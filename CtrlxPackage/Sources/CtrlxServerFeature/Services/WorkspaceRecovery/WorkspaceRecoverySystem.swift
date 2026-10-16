import Darwin
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct WorkspaceRecoverySystem: Sendable {
    var bootID: @Sendable () throws -> String
    var directoryExists: @Sendable (String) -> Bool = { _ in false }
    var pathExists: @Sendable (String) -> Bool = { _ in false }
}

extension WorkspaceRecoverySystem: DependencyKey {
    static let liveValue = Self(
        bootID: {
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
                throw WorkspaceRecoveryError("Cannot determine this Mac's boot identity.")
            }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
                throw WorkspaceRecoveryError("Cannot read this Mac's boot identity.")
            }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        },
        directoryExists: { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        },
        pathExists: { FileManager.default.fileExists(atPath: $0) }
    )
}
