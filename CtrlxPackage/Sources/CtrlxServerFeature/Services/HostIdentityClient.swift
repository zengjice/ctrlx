import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct HostIdentityClient: Sendable {
    var load: @Sendable () async throws -> UUID
}

extension HostIdentityClient: DependencyKey {
    static let liveValue: Self = {
        let arguments = CommandLine.arguments
        let override = arguments.firstIndex(of: "--ctrlx-state-root").flatMap { index -> URL? in
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return diskBacked(stateRoot: CtrlxPaths(stateRootOverride: override).stateRoot)
    }()

    static func diskBacked(stateRoot: URL) -> Self {
        let storage = HostIdentityStorage(stateRoot: stateRoot)
        return Self(load: { try await storage.load() })
    }

    static let testValue = Self()
}

/// Device identity survives disabling or clearing workspace recovery. A legacy
/// workspace UUID is migrated once; unreadable identity is never replaced.
private actor HostIdentityStorage {
    private struct Record: Codable {
        var schemaVersion = 1
        let hostID: UUID
    }

    private struct Legacy: Decodable {
        let hostID: UUID
    }

    private let stateRoot: URL
    private var current: UUID?

    init(stateRoot: URL) {
        self.stateRoot = stateRoot
    }

    func load() throws -> UUID {
        if let current {
            return current
        }
        let file = stateRoot.appendingPathComponent("host-identity.json")
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path) {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard record.schemaVersion == 1 else {
                throw HostIdentityError("The saved Host identity uses an unsupported format.")
            }
            current = record.hostID
            return record.hostID
        }
        let legacy = stateRoot.appendingPathComponent("Recovery/workspace.json")
        let hostID: UUID
        if manager.fileExists(atPath: legacy.path) {
            hostID = try JSONDecoder().decode(Legacy.self, from: Data(contentsOf: legacy)).hostID
        } else {
            hostID = UUID()
        }
        try manager.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Record(hostID: hostID)).write(to: file, options: .atomic)
        current = hostID
        return hostID
    }
}

struct HostIdentityError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }

    init(_ message: String) {
        self.message = message
    }
}
