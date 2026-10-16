import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct WorkspaceRecoveryStore: Sendable {
    var load: @Sendable () async throws -> WorkspaceRecoverySnapshot?
    var save: @Sendable (WorkspaceRecoverySnapshot) async throws -> WorkspaceRecoverySnapshot
}

extension WorkspaceRecoveryStore: DependencyKey {
    static let liveValue: Self = {
        let arguments = CommandLine.arguments
        let override = arguments.firstIndex(of: "--ctrlx-state-root").flatMap { index -> URL? in
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return diskBacked(directory: CtrlxPaths(stateRootOverride: override).stateRoot.appendingPathComponent("Recovery"))
    }()

    static func diskBacked(directory: URL) -> Self {
        let storage = WorkspaceRecoveryStorage(directory: directory)
        return Self(load: { try await storage.load() }, save: { try await storage.save($0) })
    }

    static func inMemory(_ snapshot: WorkspaceRecoverySnapshot? = nil) -> Self {
        let storage = WorkspaceRecoveryStorage(snapshot: snapshot)
        return Self(load: { try await storage.load() }, save: { try await storage.save($0) })
    }

    static var testValue: Self {
        .inMemory()
    }
}

/// No suspension between validation, backup and replacement; failed reads never become empty state.
actor WorkspaceRecoveryStorage {
    private let directory: URL?
    private var loaded = false
    private var current: WorkspaceRecoverySnapshot?

    init(directory: URL) {
        self.directory = directory
    }

    init(snapshot: WorkspaceRecoverySnapshot?) {
        self.directory = nil
        self.current = snapshot
        self.loaded = true
    }

    func load() throws -> WorkspaceRecoverySnapshot? {
        if loaded {
            return current
        }
        guard let directory else { return current }
        let file = directory.appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshot = try JSONDecoder().decode(WorkspaceRecoverySnapshot.self, from: Data(contentsOf: file))
            try snapshot.validate()
            current = snapshot
        }
        loaded = true
        return current
    }

    func save(_ proposed: WorkspaceRecoverySnapshot) throws -> WorkspaceRecoverySnapshot {
        try proposed.validate()
        let previous = try load()
        if let previous, proposed.hasSameContents(as: previous) {
            return previous
        }
        var next = proposed
        next.generation = (previous?.generation ?? 0) + 1
        next.savedAt = Date()
        if let directory {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(next)
            if let previous {
                try encoder.encode(previous).write(to: directory.appendingPathComponent("workspace.previous.json"), options: .atomic)
            }
            try bytes.write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
        }
        current = next
        return next
    }
}
