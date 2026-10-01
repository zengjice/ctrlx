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
        source.paneID == pane.paneId
            && source.sessionName == pane.sessionName
            && source.windowID == pane.stableWindowId
            && source.pluginID == detected.pluginID
            && detected.processIDs == [processID]
            && UUID(uuidString: source.sessionID) != nil
            && runtimeID == self.runtimeID
    }
}

@DependencyClient
struct AgentSessionIdentityClient: Sendable {
    var load: @Sendable (_ paneID: String) async -> AgentSessionIdentity? = { _ in nil }
    var save: @Sendable (_ identity: AgentSessionIdentity) async -> Bool = { _ in false }
    var runtimeID: @Sendable (_ processID: String) -> String? = { _ in nil }
}

extension AgentSessionIdentityClient: DependencyKey {
    static let previewValue: Self = Self(load: { _ in nil }, save: { _ in false }, runtimeID: { _ in nil })
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
        return Self(
            load: { await storage.load($0) },
            save: { await storage.save($0) },
            runtimeID: { processID in
                guard let pid = Int32(processID), pid > 1 else { return nil }
                var info = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                      info.pbi_uid == getuid(), info.pbi_start_tvsec > 0
                else { return nil }
                return "\(info.pbi_uid):\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
            }
        )
    }
}

private actor AgentSessionIdentityStorage {
    private let fileURL: URL
    private var records: [String: AgentSessionIdentity]?
    private let logger = Logger(label: "com.jicezeng.ctrlx.agent-session-identity")

    init(fileURL: URL) { self.fileURL = fileURL }

    func load(_ paneID: String) -> AgentSessionIdentity? {
        ensureLoaded()
        return records?[paneID]
    }

    func save(_ identity: AgentSessionIdentity) -> Bool {
        ensureLoaded()
        var updated = records ?? [:]
        updated[identity.source.paneID] = identity
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            records = updated
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
            records = try JSONDecoder().decode([String: AgentSessionIdentity].self, from: Data(contentsOf: fileURL))
        } catch {
            logger.warning("Could not read native Agent identities; awaiting fresh Agent events: \(error)")
            records = [:]
        }
    }
}
