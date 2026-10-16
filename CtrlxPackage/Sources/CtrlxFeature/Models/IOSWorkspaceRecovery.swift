import CtrlxCommon
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

struct IOSWorkspaceRecoverySnapshot: Codable, Equatable, Sendable {
    var version = 1
    var selectedSession: ViewerWorkspaceReference?
    var sessions: [IOSWorkspaceRecoverySession] = []
    var drafts: [IOSWorkspaceRecoveryDraft] = []

    func validate() throws {
        guard version == 1 else { throw IOSWorkspaceRecoveryError("Unsupported workspace recovery version. The saved file has been kept.") }
        guard Set(sessions.map(\.reference)).count == sessions.count, Set(drafts.map(\.id)).count == drafts.count else {
            throw IOSWorkspaceRecoveryError("Duplicate saved workspace identity. The saved file has been kept.")
        }
        for session in sessions {
            guard
                session.reference.windowID == nil, session.reference.paneID == nil,
                Set(session.files.map { $0.snapshot.id }).count == session.files.count,
                session.files.allSatisfy({ $0.source.map { $0.sessionReference == session.reference } ?? true }) else {
                throw IOSWorkspaceRecoveryError("Invalid saved workspace source. The saved file has been kept.")
            }
        }
        guard drafts.allSatisfy({ $0.pane.windowID != nil && $0.pane.paneID != nil }) else {
            throw IOSWorkspaceRecoveryError("Invalid saved draft source. The saved file has been kept.")
        }
        if let selectedSession, !sessions.contains(where: { $0.reference == selectedSession }) {
            throw IOSWorkspaceRecoveryError("The saved selected session is unavailable. The saved file has been kept.")
        }
    }
}

struct IOSWorkspaceRecoverySession: Codable, Equatable, Sendable {
    var reference: ViewerWorkspaceReference
    var name: String
    var selectedWindowID: UUID?
    var selectedPaneID: UUID?
    var selectedFileID: UUID?
    var files: [IOSWorkspaceRecoveryFile] = []
}

struct IOSWorkspaceRecoveryFile: Codable, Equatable, Sendable {
    var snapshot: FileBrowserTab.Snapshot
    var source: ViewerWorkspaceReference?
}

/// Text only: no request ID, form continuation, remote temporary path or Send action.
struct IOSWorkspaceRecoveryDraft: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var pane: ViewerWorkspaceReference
    var text: String
}

struct IOSWorkspaceRecoveryError: LocalizedError {
    var message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

@DependencyClient
struct IOSWorkspaceRecoveryStore: Sendable {
    var load: @Sendable () async throws -> IOSWorkspaceRecoverySnapshot?
    var save: @Sendable (IOSWorkspaceRecoverySnapshot) async throws -> Void
}

extension IOSWorkspaceRecoveryStore: DependencyKey {
    static let liveValue: Self = {
        let arguments = CommandLine.arguments
        if arguments.contains("--e2e-test") {
            if let index = arguments.firstIndex(of: "--ctrlx-state-root"), index + 1 < arguments.count {
                return diskBacked(directory: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("Recovery"))
            }
            return inMemory()
        }
        return diskBacked(directory: URL.applicationSupportDirectory.appendingPathComponent("CtrlX/Recovery"))
    }()

    static var testValue: Self {
        inMemory()
    }

    static func diskBacked(directory: URL) -> Self {
        let storage = IOSWorkspaceRecoveryStorage(directory: directory)
        return .init(load: { try await storage.load() }, save: { try await storage.save($0) })
    }

    static func inMemory(_ snapshot: IOSWorkspaceRecoverySnapshot? = nil) -> Self {
        let storage = IOSWorkspaceRecoveryStorage(snapshot: snapshot)
        return .init(load: { try await storage.load() }, save: { try await storage.save($0) })
    }
}

actor IOSWorkspaceRecoveryStorage {
    private let directory: URL?
    private var loaded = false
    private var current: IOSWorkspaceRecoverySnapshot?

    init(directory: URL) {
        self.directory = directory
    }

    init(snapshot: IOSWorkspaceRecoverySnapshot?) {
        self.directory = nil
        self.current = snapshot
        self.loaded = true
    }

    func load() throws -> IOSWorkspaceRecoverySnapshot? {
        guard !loaded, let directory else { return current }
        let file = directory.appendingPathComponent("ios-workspace.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshot = try JSONDecoder().decode(IOSWorkspaceRecoverySnapshot.self, from: Data(contentsOf: file))
            try snapshot.validate()
            current = snapshot
        }
        loaded = true
        return current
    }

    func save(_ proposed: IOSWorkspaceRecoverySnapshot) throws {
        try proposed.validate()
        let previous = try load()
        guard proposed != previous else { return }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let previous {
                try encoder.encode(previous).write(to: directory.appendingPathComponent("ios-workspace.previous.json"), options: .atomic)
            }
            try encoder.encode(proposed).write(to: directory.appendingPathComponent("ios-workspace.json"), options: .atomic)
        }
        current = proposed
    }
}
