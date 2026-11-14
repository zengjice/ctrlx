import CtrlxNetworking
import Foundation

struct OrbieTaskSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let project: String
    let createdAt: Date
    let updatedAt: Date
    let archived: Bool
    let state: String
    let goal: String
    let source: String
    let report: Report?

    struct Report: Codable, Equatable, Sendable {
        let runID: UUID
        let invocationID: UUID
        let text: String
        let reportedAt: Date
    }
}

enum OrbieTaskCatalog {
    static func summaries(tasks: [OrbiterTask], runs: [AgentWorkflowRun], instances: [AgentWorkflowInstance]) -> [OrbieTaskSummary] {
        tasks.map { task in
            let executions = task.runIDs.compactMap { id in runs.first { $0.id == id } }
            let last = executions.last
            let current = task.binding?.agentID.resolve(in: instances, identity: { $0.agentID }).value
            let state: String
            if task.archived {
                state = "archived"
            } else if last?.status == .paused {
                state = "paused"
            } else if let last, !last.status.isTerminal {
                state = "working"
            } else if let current {
                state = current.readiness.rawValue
            } else {
                state = "unavailable"
            }
            let report = executions.reversed().compactMap { run -> OrbieTaskSummary.Report? in
                guard let (_, result) = OrbiterStore.reports(in: run).last else { return nil }
                return .init(runID: run.id, invocationID: result.invocationID, text: bounded(result.text, bytes: 2_000), reportedAt: result.completedAt)
            }.first
            return .init(
                id: task.id, title: bounded(task.title, bytes: 160), project: bounded(task.directory, bytes: 1_024),
                createdAt: task.createdAt, updatedAt: max(last?.createdAt ?? task.createdAt, report?.reportedAt ?? task.createdAt),
                archived: task.archived, state: state, goal: bounded(task.goal, bytes: 1_000),
                source: bounded(task.source, bytes: 512), report: report
            )
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    static func search(_ summaries: [OrbieTaskSummary], query: String, since: Date? = nil, includeArchived: Bool = false, limit: Int = 8) -> [OrbieTaskSummary] {
        Array(summaries.filter {
            (includeArchived || !$0.archived) && $0.updatedAt >= (since ?? .distantPast)
                && (query.isEmpty || "\($0.title) \($0.project) \($0.goal) \($0.source)".localizedStandardContains(query))
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

    /// Only this explicit marker in a verified final answer creates a candidate.
    static func candidates(in text: String) -> [UUID] {
        var ids: [UUID] = []
        for fragment in text.components(separatedBy: "[CtrlX task: ").dropFirst() {
            guard let end = fragment.firstIndex(of: "]"), let id = UUID(uuidString: String(fragment[..<end])), !ids.contains(id) else { continue }
            ids.append(id)
            if ids.count == 8 {
                break
            }
        }
        return ids
    }

    static func displayAnswer(_ text: String) -> String {
        var result = text
        for id in candidates(in: text) {
            result = result.replacingOccurrences(of: "[CtrlX task: \(id.uuidString)]", with: "", options: .caseInsensitive)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
