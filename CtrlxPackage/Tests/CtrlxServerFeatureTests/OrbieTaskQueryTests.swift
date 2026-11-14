import CtrlxNetworking
import CtrlxPluginProtocol
import Darwin
import Foundation
import Testing
@testable import CtrlxServerFeature

struct OrbieTaskQueryTests {
    private actor Backend {
        var observations: [AgentWorkflowObservation]
        var mismatch = false
        init(_ observations: [AgentWorkflowObservation]) {
            self.observations = observations
        }

        func scan() -> [AgentWorkflowObservation] {
            observations
        }

        func setReadiness(_ value: AgentWorkflowReadiness) {
            observations[0].readiness = value
        }

        func replaceProcess() {
            observations[0].processRuntimeID = "replacement"
        }

        func changeConversation() {
            observations[0].conversationID = UUID().uuidString
        }

        func changeInspection() {
            mismatch = true
        }

        func inspect(_ instance: AgentWorkflowInstance) -> AgentWorkflowInstance {
            var current = instance
            if mismatch {
                current.conversationID = UUID().uuidString
            }
            return current
        }
    }

    private struct Fixture {
        let root: URL
        let paths: CtrlxPaths
        let orbie: OrbieStore
        let tasks: OrbiterStore
        let backend: Backend
        let caller: PluginIngressPeer
        let service: OrbieTaskQueryService
    }

    private func peer(start: UInt64 = 100) throws -> PluginIngressPeer {
        let uid = getuid()
        let processes: [Int32: PluginIngressPeer.Process] = [
            42: .init(processID: 42, parentProcessID: 1, userID: uid, startSeconds: start, startMicroseconds: 0),
            43: .init(processID: 43, parentProcessID: 42, userID: uid, startSeconds: 200, startMicroseconds: 0),
        ]
        return try #require(PluginIngressPeer.capture(peerPID: 43, userID: uid, inspect: { processes[$0] }))
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbie-query-\(UUID())")
        let paths = CtrlxPaths(stateRootOverride: root.appendingPathComponent("state"))
        let hostID = UUID()
        let pane = WorkspacePaneIdentity(serverID: "10:20", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let caller = try peer()
        let runtime = try #require(caller.processes.first { $0.processID == 42 }?.runtimeID)
        let backend = Backend([.init(pluginID: "codex", processID: 42, processRuntimeID: runtime, workspacePane: pane, paneID: "%0", conversationID: UUID().uuidString, displayName: "Orbie", workingDirectory: paths.orbieDirectory.path, capabilities: .init(maximumInputBytes: 100_000), readiness: .ready)])
        let ledger = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let workflows = AgentWorkflowService(store: ledger, scan: { _ in await backend.scan() }, schedule: { _ in Issue.record("A read-only task query must not schedule Agent work") })
        let current = try #require(try await workflows.snapshot(refreshInstances: true).instances.first)
        let orbie = OrbieStore(paths: paths, hostID: hostID)
        var record = OrbieRecord(hostID: hostID)
        record.enabled = true
        record.creation = .init(id: UUID(), pluginID: "codex", providerID: nil, directory: paths.orbieDirectory.path, pane: pane)
        record.binding = current
        record.draft = "SENSITIVE_UNSENT_MAIN_DRAFT"
        try await orbie.save(record)
        let tasks = OrbiterStore(paths: paths, hostID: hostID)
        var index = OrbiterIndex(hostID: hostID)
        index.tasks = (0..<20).map { number in
            .init(id: UUID(), title: "音频 \(number)", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(number * 100)), goal: String(repeating: "目标🌍", count: 2_000), source: String(repeating: "来源", count: 1_000), materials: "SENSITIVE_SELECTED_MATERIAL", directory: root.appendingPathComponent("project-\(number)").path, origin: .associated, pluginID: "codex", providerID: nil, forkSource: nil, draft: "SENSITIVE_UNSENT_TASK_DRAFT", archived: number == 19)
        }
        try await tasks.save(index)
        let service = OrbieTaskQueryService(orbie: orbie, tasks: tasks, workflows: workflows) { await backend.inspect($0) }
        return .init(root: root, paths: paths, orbie: orbie, tasks: tasks, backend: backend, caller: caller, service: service)
    }

    private func list(_ f: Fixture, params: [String: JSONValue] = [:]) async -> JSONRPCResponse {
        await f.service.handle(.init(id: "query", method: "orbie.tasks.list", params: params), peer: f.caller)
    }

    @Test
    func boundedLookupHidesDraftsAndDoesNotChangeTaskOrOrbieRecords() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let originalTasks = try Data(contentsOf: f.paths.orbiterIndex), originalOrbie = try Data(contentsOf: f.paths.orbieBinding)
        let response = await list(f, params: ["query": .string("音频"), "limit": .int(12)])
        #expect(response.ok)
        guard case let .array(tasks) = response.result?["tasks"] else { Issue.record("Missing task summaries")
            return
        }
        #expect(tasks.count == 12)
        let first = try #require(tasks.first?.objectValue)
        #expect(first["title"] == .string("音频 18"))
        #expect(first["goal"]?.stringValue?.utf8.count ?? .max <= 1_000)
        #expect(first["source"]?.stringValue?.utf8.count ?? .max <= 512)
        #expect(first["createdAt"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) } != nil)
        let data = try JSONEncoder().encode(response)
        #expect(data.count < 128 * 1_024)
        #expect(!String(decoding: data, as: UTF8.self).contains("SENSITIVE_"))
        #expect(try Data(contentsOf: f.paths.orbiterIndex) == originalTasks)
        #expect(try Data(contentsOf: f.paths.orbieBinding) == originalOrbie)
    }

    @Test(arguments: ["missing-peer", "reused-pid", "disabled", "new-process", "new-conversation", "inspection-mismatch"])
    func callerAuthorityCannotBeGuessedOrInherited(kind: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var caller: PluginIngressPeer? = f.caller
        switch kind {
        case "missing-peer": caller = nil
        case "reused-pid": caller = try peer(start: 101)
        case "disabled": var record = try await f.orbie.load()
            record.enabled = false
            try await f.orbie.save(record)
        case "new-process": await f.backend.replaceProcess()
        case "new-conversation": await f.backend.changeConversation()
        default: await f.backend.changeInspection()
        }
        let response = await f.service.handle(.init(id: "query", method: "orbie.tasks.list", params: [:]), peer: caller)
        #expect(!response.ok && response.result == nil)
    }

    @Test(arguments: [AgentWorkflowReadiness.busy, .draft, .awaitingHuman])
    func readOnlySearchRemainsAvailableWhileOrbieNeedsAttention(readiness: AgentWorkflowReadiness) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.backend.setReadiness(readiness)
        #expect(await list(f).ok)
    }

    @Test
    func initialConversationUsesVerifiedCatalogWithoutRewritingTheBinding() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var record = try await f.orbie.load()
        record.binding?.conversationID = ""
        try await f.orbie.save(record)
        #expect(await list(f).ok)
        #expect(try await f.orbie.load().binding?.conversationID == "")
    }

    @Test
    func filtersAndExactTaskIDsNeverFallBackToOtherTasks() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let none = await list(f, params: ["query": .string("No matching task")])
        #expect(none.result?["tasks"] == .array([]))
        let recent = await list(f, params: ["since": .string(Date(timeIntervalSince1970: 1_700_001_800).ISO8601Format()), "includeArchived": .bool(true)])
        guard case let .array(tasks) = recent.result?["tasks"] else { Issue.record("Missing filtered tasks")
            return
        }
        #expect(tasks.count == 2)
        let saved = try #require(try await f.tasks.load().tasks.first)
        let show = await f.service.handle(.init(id: "show", method: "orbie.tasks.show", params: ["taskId": .string(saved.id.uuidString)]), peer: f.caller)
        #expect(show.ok && show.result?["task"]?.objectValue?["id"] == .string(saved.id.uuidString))
        let missing = await f.service.handle(.init(id: "show", method: "orbie.tasks.show", params: ["taskId": .string(UUID().uuidString)]), peer: f.caller)
        #expect(missing.error?.code == "not_found")
        for params: [String: JSONValue] in [["_peerPID": .int(42)], ["paneId": .string("%0")], ["limit": .int(13)], ["limit": .string("8")], ["since": .string("yesterday")], ["includeArchived": .int(1)]] {
            #expect(!(await list(f, params: params)).ok)
        }
    }

    @Test
    func candidateMarkersAreUUIDsAndDoNotInterpretCommandsOrPaths() {
        let id = UUID()
        let text = "Candidate\n[CtrlX task: \(id)]\n[CtrlX task: \(id.uuidString.lowercased())]\n[CtrlX task: /tmp/file]\n[CtrlX task: $(touch marker)]"
        #expect(OrbieTaskCatalog.candidates(in: text) == [id])
        #expect(OrbieTaskCatalog.candidates(in: "Open /tmp/file; run ctrlx select-pane %1").isEmpty)
        #expect(!OrbieTaskCatalog.displayAnswer(text).contains(id.uuidString))
        #expect(OrbieTaskCatalog.bounded(String(repeating: "🌍音", count: 100), bytes: 31).utf8.count <= 31)
    }
}
