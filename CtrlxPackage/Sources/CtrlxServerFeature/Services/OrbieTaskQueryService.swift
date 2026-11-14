import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Read-only local API. A claimed task UUID or pane ID never authorizes the caller.
actor OrbieTaskQueryService {
    private let orbie: OrbieStore
    private let tasks: OrbiterStore
    private let workflows: AgentWorkflowService
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance

    init(
        orbie: OrbieStore,
        tasks: OrbiterStore,
        workflows: AgentWorkflowService,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    ) {
        self.orbie = orbie
        self.tasks = tasks
        self.workflows = workflows
        self.inspect = inspect
    }

    func handle(_ request: JSONRPCRequest, peer: PluginIngressPeer?) async -> JSONRPCResponse {
        let listing = request.method == "orbie.tasks.list"
        guard listing || request.method == "orbie.tasks.show" else { return .methodNotFound(id: request.id, request.method) }
        let allowed: Set<String> = listing ? ["query", "limit", "since", "includeArchived"] : ["taskId"]
        guard Set(request.params.keys).isSubset(of: allowed) else { return .invalidParams(id: request.id, "Unsupported Orbie task query parameters. Target and caller overrides are not supported.") }
        guard let peer else { return denied(request.id) }
        do {
            let record = try await orbie.load()
            guard record.enabled, record.target != nil else { return denied(request.id) }
            let archive = try await workflows.snapshot(refreshInstances: true)
            guard
                archive.hostID == record.hostID,
                let current = record.currentInstance(in: archive.instances),
                peer.contains(processID: current.processID, runtimeID: current.processRuntimeID) else { return denied(request.id) }
            let verified = try await inspect(current)
            guard current.matchesBinding(verified), UUID(uuidString: verified.conversationID) != nil else { return denied(request.id) }
            let index = try await tasks.load()
            guard index.hostID == record.hostID else { return denied(request.id) }
            let catalog = OrbieTaskCatalog.summaries(tasks: index.tasks, runs: archive.runs, instances: archive.instances)
            if listing {
                let query = request.params["query"]?.stringValue ?? ""
                let limit = request.params["limit"]?.intValue ?? 8
                let archived = request.params["includeArchived"]?.boolValue ?? false
                let since = request.params["since"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
                guard
                    query.utf8.count <= 256, (1...12).contains(limit),
                    request.params["query"] == nil || request.params["query"]?.stringValue != nil,
                    request.params["limit"] == nil || request.params["limit"]?.intValue != nil,
                    request.params["includeArchived"] == nil || request.params["includeArchived"]?.boolValue != nil,
                    request.params["since"] == nil || since != nil else { return .invalidParams(id: request.id, "Expected query (up to 256 UTF-8 bytes), limit 1–12, includeArchived and an optional ISO-8601 since date.") }
                let found = OrbieTaskCatalog.search(catalog, query: query, since: since, includeArchived: archived, limit: limit)
                return try .init(id: request.id, result: ["tasks": encode(found), "reportKind": .string("Agent reports; goals are not independently verified")])
            }
            guard let raw = request.params["taskId"]?.stringValue, let id = UUID(uuidString: raw) else { return .invalidParams(id: request.id, "Expected a saved task UUID.") }
            guard let summary = catalog.first(where: { $0.id == id }) else { return .init(id: request.id, error: .init(code: "not_found", message: "This task is not in the local Orbie index.")) }
            return try .init(id: request.id, result: [
                "task": encode(summary),
                "materialsDirectory": .string(tasks.paths.orbiterDirectory(id).path),
                "reportKind": .string("Agent report; not independent verification of the goal"),
            ])
        } catch {
            return .init(id: request.id, error: .init(code: "orbie_query_failed", message: "Could not verify the Orbie caller or read its saved tasks. Open Orbie and review its binding."))
        }
    }

    private func encode(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    private func denied(_ id: String) -> JSONRPCResponse {
        .init(id: id, error: .init(code: "orbie_denied", message: "Only the verified, enabled Agent in this Host's Orbie tab may query saved tasks. Open its terminal and check startup or recovery."))
    }
}
