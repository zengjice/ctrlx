import CtrlxNetworking
import Foundation

struct OrbieAgentSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let agentID: AgentID?
    let title: String
    let project: String
    let updatedAt: Date
    let state: String
    let report: String?
}

enum OrbieAgentCatalog {
    static func summaries(agents: [OrbiterRecord], messages: [AgentMessage], instances: [AgentWorkflowInstance]) -> [OrbieAgentSummary] {
        agents.map { record in
            let current = record.agentID?.resolve(in: instances, identity: { $0.agentID }).value
            let history = record.messageIDs.compactMap { id in messages.first { $0.id == id } }
            return OrbieAgentSummary(
                id: record.id,
                agentID: record.agentID,
                title: bounded(current?.displayName ?? record.title, bytes: 160),
                project: bounded(current?.workingDirectory ?? record.directory, bytes: 1_024),
                updatedAt: history.last?.completedAt ?? history.last?.createdAt ?? .distantPast,
                state: current?.readiness.rawValue ?? "unavailable",
                report: history.reversed().compactMap(\.answer).first.map { bounded($0, bytes: 2_000) }
            )
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    static func search(_ summaries: [OrbieAgentSummary], query: String, since: Date? = nil, limit: Int = 8) -> [OrbieAgentSummary] {
        Array(summaries.filter {
            $0.updatedAt >= (since ?? .distantPast) && (query.isEmpty || "\($0.title) \($0.project)".localizedStandardContains(query))
        }.prefix(limit))
    }

    static func bounded(_ text: String, bytes: Int) -> String {
        var result = "", remaining = bytes
        for character in text {
            let count = String(character).utf8.count
            guard count <= remaining else { break }
            result.append(character)
            remaining -= count
        }
        return result
    }

    static func candidates(in text: String) -> [String] {
        var ids: [String] = []
        for fragment in text.components(separatedBy: "[CtrlX Agent: ").dropFirst() {
            guard let end = fragment.firstIndex(of: "]") else { continue }
            let value = String(fragment[..<end])
            let parts = value.split(separator: "/")
            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, UUID(uuidString: String(parts[1])) != nil, !ids.contains(value) else { continue }
            ids.append(value)
            if ids.count == 8 {
                break
            }
        }
        return ids
    }

    static func workflowCandidates(in text: String) -> [UUID] {
        var ids: [UUID] = []
        for fragment in text.components(separatedBy: "[CtrlX Workflow: ").dropFirst() {
            guard let end = fragment.firstIndex(of: "]"), let id = UUID(uuidString: String(fragment[..<end])), !ids.contains(id) else { continue }
            ids.append(id)
            if ids.count == 8 {
                break
            }
        }
        return ids
    }

    static func associatedWorkflows(_ archive: AgentWorkflowArchive, targets: Set<AgentID>, instances: [AgentWorkflowInstance]) -> [AgentWorkflowDefinition] {
        archive.definitions.filter { definition in
            definition.agents.contains { participant in
                definition.instance(for: participant.id, in: instances).map { targets.contains($0.agentID) }
                    ?? definition.agentTargets?[participant.id].map { targets.contains($0.agentID) } ?? false
            }
        }
    }

    static func displayAnswer(_ text: String) -> String {
        var result = text
        for id in candidates(in: text) {
            result = result.replacingOccurrences(of: "[CtrlX Agent: \(id)]", with: "", options: .caseInsensitive)
        }
        for id in workflowCandidates(in: text) {
            result = result.replacingOccurrences(of: "[CtrlX Workflow: \(id.uuidString)]", with: "", options: .caseInsensitive)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
