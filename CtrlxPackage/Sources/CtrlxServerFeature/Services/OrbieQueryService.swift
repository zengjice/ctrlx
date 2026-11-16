import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Read-only local API. A claimed Agent ID or pane ID never authorizes the caller.
actor OrbieQueryService {
    private let orbie: OrbieStore
    private let orbiters: OrbiterStore
    private let interaction: AgentMessageService
    private let workflows: @Sendable () async throws -> AgentWorkflowArchive?
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance

    init(
        orbie: OrbieStore,
        orbiters: OrbiterStore,
        interaction: AgentMessageService,
        workflows: @escaping @Sendable () async throws -> AgentWorkflowArchive?,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    ) {
        self.orbie = orbie
        self.orbiters = orbiters
        self.interaction = interaction
        self.workflows = workflows
        self.inspect = inspect
    }

    func handle(_ request: JSONRPCRequest, peer: PluginIngressPeer?) async -> JSONRPCResponse {
        let listing = request.method.hasSuffix(".list")
        let agentQuery = request.method.hasPrefix("orbie.agents.")
        guard ["orbie.agents.list", "orbie.agents.show", "orbie.workflows.list", "orbie.workflows.show"].contains(request.method) else { return .methodNotFound(id: request.id, request.method) }
        let allowed: Set<String> = listing ? (agentQuery ? ["query", "limit", "since"] : ["query", "limit", "since", "tag"]) : ["id"]
        guard Set(request.params.keys).isSubset(of: allowed) else { return .invalidParams(id: request.id, "Unsupported query parameters. Caller and target overrides are not supported.") }
        guard let peer else { return denied(request.id) }
        do {
            let record = try await orbie.load()
            guard record.enabled, record.target != nil else { return denied(request.id) }
            let instances = try await interaction.catalog.snapshot(refresh: true)
            guard
                let current = record.currentInstance(in: instances),
                peer.contains(processID: current.processID, runtimeID: current.processRuntimeID) else { return denied(request.id) }
            let verified = try await inspect(current)
            guard current.matchesBinding(verified), UUID(uuidString: verified.conversationID) != nil else { return denied(request.id) }
            let index = try await orbiters.load()
            guard index.hostID == record.hostID else { return denied(request.id) }
            let query = request.params["query"]?.stringValue ?? ""
            let limit = request.params["limit"]?.intValue ?? 8
            let since = request.params["since"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
            guard
                query.utf8.count <= 256, (1...12).contains(limit),
                request.params["query"] == nil || request.params["query"]?.stringValue != nil,
                request.params["limit"] == nil || request.params["limit"]?.intValue != nil,
                request.params["since"] == nil || since != nil,
                request.params["tag"] == nil || request.params["tag"]?.stringValue.map { $0.utf8.count <= 32 } == true else {
                return .invalidParams(id: request.id, "Expected query up to 256 UTF-8 bytes, limit 1–12 and an ISO-8601 since date.")
            }
            if agentQuery {
                var messages: [AgentMessage] = []
                for agent in index.agents {
                    messages += try await interaction.store.messages(agent.messageIDs, limit: 1)
                }
                let catalog = OrbieAgentCatalog.summaries(agents: index.agents, messages: messages, instances: instances)
                if listing {
                    return try .init(id: request.id, result: ["agents": encode(OrbieAgentCatalog.search(catalog, query: query, since: since, limit: limit))])
                }
                guard let id = request.params["id"]?.stringValue, let summary = catalog.first(where: { $0.id == id }) else {
                    return .invalidParams(id: request.id, "Choose an Agent returned by orbie agents list.")
                }
                return try .init(id: request.id, result: ["agent": encode(summary)])
            }
            guard let archive = try await workflows() else { throw AgentWorkflowError("Workflows are unavailable.") }
            let targets = Set(index.agents.compactMap(\.agentID) + [current.agentID])
            let definitions = OrbieAgentCatalog.associatedWorkflows(archive, targets: targets, instances: instances)
            if listing {
                let tag = request.params["tag"]?.stringValue
                let found = definitions.filter { definition in (query.isEmpty || definition.name.localizedStandardContains(query)) && (tag == nil || definition.tags?.contains(where: { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame }) == true)
                    && (since == nil || archive.runs.contains { run in run.definition.id == definition.id && since.map { run.createdAt >= $0 } == true })
                }.prefix(limit)
                return .init(id: request.id, result: ["workflows": .array(found.map { JSONValue.object(["id": .string($0.id.uuidString), "name": .string(OrbieAgentCatalog.bounded($0.name, bytes: 160)), "tags": .array(($0.tags ?? []).map(JSONValue.string))]) })])
            }
            guard let raw = request.params["id"]?.stringValue, let id = UUID(uuidString: raw), let definition = definitions.first(where: { $0.id == id }) else {
                return .invalidParams(id: request.id, "Choose a Workflow returned by orbie workflows list.")
            }
            return .init(id: request.id, result: ["id": .string(id.uuidString), "name": .string(OrbieAgentCatalog.bounded(definition.name, bytes: 160)), "tags": .array((definition.tags ?? []).map(JSONValue.string)), "steps": .int(definition.nodes.count)])

        } catch {
            return .init(id: request.id, error: .init(code: "orbie_query_failed", message: "Could not verify the Orbie caller or read its associated Agents. Open Orbie and review its binding."))
        }
    }

    private func encode(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    private func denied(_ id: String) -> JSONRPCResponse {
        .init(id: id, error: .init(code: "orbie_denied", message: "Only the verified, enabled Agent in this Host's Orbie tab may query associated Agents. Open its terminal and check startup or recovery."))
    }
}
