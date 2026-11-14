import CtrlxNetworking
import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import Logging

struct AgentSessionIdentity: Codable, Sendable, Equatable {
    let source: AgentForkSource
    let processID: String
    let runtimeID: String

    func matches(pane: PaneState, detected: TmuxService.DetectedAgentPane, runtimeID: String?) -> Bool {
        let sameLocation: Bool
        if let saved = source.workspaceIdentity {
            sameLocation = saved.isSamePane(as: pane.workspaceIdentity)
        } else {
            sameLocation = source.sessionName == pane.sessionName && source.windowID == pane.stableWindowId
        }
        return source.paneID == pane.paneId && sameLocation
            && source.pluginID == detected.pluginID
            && detected.processIDs == [processID]
            && UUID(uuidString: source.sessionID) != nil
            && runtimeID == self.runtimeID
    }

    /// Refresh routing metadata only after both the live process and current
    /// conversation agree. A pane move must not revive an old conversation.
    func current(in pane: PaneState, detected: TmuxService.DetectedAgentPane, runtimeID: String?) -> Self? {
        guard
            matches(pane: pane, detected: detected, runtimeID: runtimeID),
            let current = AgentForkSource(pane: pane), current.pluginID == source.pluginID,
            current.sessionID == source.sessionID else { return nil }
        return Self(source: current, processID: processID, runtimeID: self.runtimeID)
    }
}

@DependencyClient
struct AgentSessionIdentityClient: Sendable {
    var load: @Sendable (_ paneID: String) async -> AgentSessionIdentity? = { _ in nil }
    var recoverySource: @Sendable (_ sessionIDs: Set<UUID>, _ windowID: UUID, _ paneID: UUID) async throws -> AgentForkSource? = { _, _, _ in nil }
    var save: @Sendable (_ identity: AgentSessionIdentity) async -> Bool = { _ in false }
    var invalidate: @Sendable (_ paneID: UUID) async -> Void = { _ in }
    var isInvalidated: @Sendable (_ paneID: UUID) async -> Bool = { _ in false }
    var runtimeID: @Sendable (_ processID: String) -> String? = { _ in nil }
    var codexOwnsSession: @Sendable (_ processID: String, _ runtimeID: String, _ conversationID: String) async -> Bool = { _, _, _ in false }
    var codexSessionID: @Sendable (_ processID: String, _ runtimeID: String) async -> String? = { _, _ in nil }
}

extension AgentSessionIdentityClient {
    func currentIdentity(in pane: PaneState, detected: TmuxService.DetectedAgentPane) async -> AgentSessionIdentity? {
        guard let saved = await load(pane.paneId) else { return nil }
        return saved.current(in: pane, detected: detected, runtimeID: runtimeID(saved.processID))
    }

    func workflowInputIssue(for instance: AgentWorkflowInstance, allowsInitialBinding: Bool = false) async -> String? {
        guard instance.pluginID == "codex" else { return nil }
        let pid = String(instance.processID)
        guard runtimeID(pid) == instance.processRuntimeID else { return "The Agent process changed." }
        // The first task is bound by its authenticated native receipt; a new
        // Codex thread may not have any rollout file before that submission.
        if allowsInitialBinding {
            return nil
        }
        let ownsConversation = await codexOwnsSession(pid, instance.processRuntimeID, instance.conversationID)
        guard runtimeID(pid) == instance.processRuntimeID else { return "The Agent process changed." }
        guard ownsConversation else {
            return "The active Codex conversation could not be verified. Refresh the Agent list before starting."
        }
        return nil
    }
}

extension AgentSessionIdentityClient: DependencyKey {
    static let previewValue = Self(load: { _ in nil }, recoverySource: { _, _, _ in nil }, save: { _ in false }, invalidate: { _ in }, isInvalidated: { _ in false }, runtimeID: { _ in nil }, codexOwnsSession: { _, _, _ in false }, codexSessionID: { _, _ in nil })
    static let testValue: Self = previewValue

    static let liveValue: Self = diskBacked(stateRoot: {
        let arguments = CommandLine.arguments
        let override = arguments.firstIndex(of: "--ctrlx-state-root").flatMap { index -> URL? in
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return CtrlxPaths(stateRootOverride: override).stateRoot
    }())

    static func diskBacked(stateRoot: URL) -> Self {
        let storage = AgentSessionIdentityStorage(fileURL: stateRoot.appendingPathComponent("agent-session-identities.json"))
        let codex = CodexProcessSessionReader()
        return Self(
            load: { await storage.load($0) },
            recoverySource: { try await storage.recoverySource(sessionIDs: $0, windowID: $1, paneID: $2) },
            save: { await storage.save($0) },
            invalidate: { await storage.invalidate($0) },
            isInvalidated: { await storage.isInvalidated($0) },
            runtimeID: { processRuntimeID($0) },
            codexOwnsSession: { await codex.ownsSession(processID: $0, runtimeID: $1, conversationID: $2) },
            codexSessionID: { await codex.sessionID(processID: $0, runtimeID: $1) }
        )
    }

    static func processRuntimeID(_ processID: String) -> String? {
        guard let pid = Int32(processID), pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
            info.pbi_uid == getuid(), info.pbi_start_tvsec > 0
        else { return nil }
        return "\(info.pbi_uid):\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
}

private actor AgentSessionIdentityStorage {
    private let fileURL: URL
    private struct Archive: Codable {
        var schemaVersion = 2
        var records: [String: AgentSessionIdentity]
        var invalidated: Set<UUID>
    }

    private var loadIssue: String?
    private var invalidated: Set<UUID> = []
    private var records: [String: AgentSessionIdentity]?
    private let logger = Logger(label: "com.jicezeng.ctrlx.agent-session-identity")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(_ paneID: String) -> AgentSessionIdentity? {
        ensureLoaded()
        return records?[paneID]
    }

    func recoverySource(sessionIDs: Set<UUID>, windowID: UUID, paneID: UUID) throws -> AgentForkSource? {
        ensureLoaded()
        if let loadIssue {
            throw WorkspaceRecoveryError(loadIssue)
        }
        // Recovery crosses tmux incarnations. Runtime pane IDs and process IDs
        // remain mandatory for live matching, but are not recovery identities.
        let matches = (records ?? [:]).values.filter {
            guard let identity = $0.source.workspaceIdentity else { return false }
            return identity.paneID == paneID && !invalidated.contains(paneID)
        }
        guard matches.count <= 1 else {
            throw WorkspaceRecoveryError("Multiple saved Agent identities match this terminal. Use Shell and select the original conversation from the Agent's history.")
        }
        return matches.first?.source
    }

    func isInvalidated(_ paneID: UUID) -> Bool {
        ensureLoaded()
        return loadIssue != nil || invalidated.contains(paneID)
    }

    func invalidate(_ paneID: UUID) {
        ensureLoaded()
        let updated = (records ?? [:]).filter { $0.value.source.workspaceIdentity?.paneID != paneID }
        // In-memory invalidation must survive a failed disk write in this process.
        records = updated
        invalidated.insert(paneID)
        if !commit(updated, invalidated: invalidated) {
            loadIssue = "Could not persist the changed Agent identity. Check workspace storage before recovery."
        }
    }

    func save(_ identity: AgentSessionIdentity) -> Bool {
        ensureLoaded()
        var updated = records ?? [:]
        if let paneID = identity.source.workspaceIdentity?.paneID {
            updated = updated.filter { $0.value.source.workspaceIdentity?.paneID != paneID }
        }
        updated[identity.source.paneID] = identity
        var invalidated = invalidated
        if let paneID = identity.source.workspaceIdentity?.paneID {
            invalidated.remove(paneID)
        }
        return commit(updated, invalidated: invalidated)
    }

    private func commit(_ updated: [String: AgentSessionIdentity], invalidated: Set<UUID>) -> Bool {
        guard loadIssue == nil else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Archive(records: updated, invalidated: invalidated)).write(to: fileURL, options: .atomic)
            records = updated
            self.invalidated = invalidated
            return true
        } catch {
            logger.warning("Could not save native Agent identity: \(error)")
            return false
        }
    }

    private func ensureLoaded() {
        guard records == nil else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = [:]
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
                guard archive.schemaVersion == 2 else { throw WorkspaceRecoveryError("Unsupported native conversation cache format.") }
                records = archive.records
                invalidated = archive.invalidated
            } else {
                let legacy = try JSONDecoder().decode([String: AgentSessionIdentity].self, from: data)
                let backup = fileURL.appendingPathExtension("schema-1.backup")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try data.write(to: backup, options: .atomic)
                }
                records = legacy
            }
        } catch {
            loadIssue = "Could not read the saved Agent identities. The original file was preserved: \(error.localizedDescription)"
            logger.warning("\(loadIssue ?? "")")
            records = [:]
        }
    }
}
