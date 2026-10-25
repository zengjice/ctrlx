import CtrlxNetworking
import SwiftUI

@MainActor
public struct AgentWorkflowsView: View {
    private let endpoints: () -> [AgentWorkflowEndpoint]
    private let openAgent: (String, AgentWorkflowInstance) -> Void
    private let createAgent: ((String, UUID) async throws -> AgentWorkflowAgentCreation)?
    private let close: (() -> Void)?

    public init(
        endpoints: @escaping () -> [AgentWorkflowEndpoint],
        openAgent: @escaping (String, AgentWorkflowInstance) -> Void,
        createAgent: ((String, UUID) async throws -> AgentWorkflowAgentCreation)? = nil,
        close: (() -> Void)? = nil
    ) {
        self.endpoints = endpoints
        self.openAgent = openAgent
        self.createAgent = createAgent
        self.close = close
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(endpoints()) { endpoint in
                        NavigationLink {
                            AgentWorkflowHostView(
                                endpoint: endpoint, openAgent: { openAgent(endpoint.id, $0) },
                                createAgent: createAgent.map { action in { hostID in try await action(endpoint.id, hostID) } }
                            )
                            .id(endpoint.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(endpoint.name)
                                Text(endpoint.isConnected ? (endpoint.isSupported ? "Available" : "Update Host to use workflows") : "Offline")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if endpoints().isEmpty {
                        Text("Pair a Host to create a workflow.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Hosts")
                } footer: {
                    Text("Each workflow runs on one Host. It continues when this Viewer disconnects.")
                }
            }
            .navigationTitle("Workflows")
            .toolbar {
                if let close {
                    ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
                }
            }
        }
        .accessibilityIdentifier("agent-workflows")
    }
}

@MainActor
private struct AgentWorkflowHostView: View {
    let endpoint: AgentWorkflowEndpoint
    let openAgent: (AgentWorkflowInstance) -> Void
    let createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var overview: AgentWorkflowOverview?
    @State private var editing: AgentWorkflowDefinition?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let overview {
                Section("Configurations") {
                    ForEach(overview.definitions) { definition in
                        NavigationLink {
                            AgentWorkflowConfigurationView(
                                endpoint: endpoint, hostID: overview.hostID, definitionID: definition.id,
                                openAgent: openAgent, createAgent: createAgent
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(definition.name)
                                Text("\(definition.nodeCount) nodes").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if overview.definitions.isEmpty {
                        Text("Create your first workflow.").foregroundStyle(.secondary)
                    }
                }
                Section("Runs") {
                    ForEach(overview.runs) { run in
                        NavigationLink {
                            AgentWorkflowRunView(endpoint: endpoint, hostID: overview.hostID, runID: run.id, openAgent: openAgent)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.name)
                                Text("\(run.status.title) · round \(run.round)").font(.caption).foregroundStyle(.secondary)
                                if let issue = run.issue {
                                    Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2)
                                }
                            }
                        }
                    }
                    if overview.runs.isEmpty {
                        Text("No runs yet").foregroundStyle(.secondary)
                    }
                }
            } else if error == nil {
                ProgressView("Loading workflows…")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(endpoint.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let hostID = overview?.hostID else { return }
                    editing = .init(name: "", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID())
                } label: { Label("New workflow", symbol: .plus) }
                    .disabled(overview == nil || !endpoint.isConnected || !endpoint.isSupported)
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await refresh() } }) { draft in
            AgentWorkflowEditor(endpoint: endpoint, definition: draft, isNew: true, createAgent: createAgent)
        }
        .refreshable { await refresh() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await endpoint.overview(hostID: overview?.hostID)
            try Task.checkCancellation()
            overview = value
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
struct AgentWorkflowConfigurationView: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let definitionID: UUID
    let openAgent: (AgentWorkflowInstance) -> Void
    let createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?
    @Environment(\.dismiss) private var dismiss
    @State private var definition: AgentWorkflowDefinition?
    @State private var attachments: [UUID: AgentWorkflowAttachment] = [:]
    @State private var editing: AgentWorkflowDefinition?
    @State private var startedRun: UUID?
    @State private var startRequestID = UUID()
    @State private var pendingStart: ManageAgentWorkflows.Operation?
    @State private var expiresAt = Date().addingTimeInterval(86_400)
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            if let definition {
                Section("Initial task") { Text(verbatim: definition.initialInput.text).textSelection(.enabled) }
                Section("Nodes") {
                    ForEach(definition.nodes) { node in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(node.name).font(.headline)
                            if node.kind == .content {
                                Label("Content node", symbol: .docTextFill).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(node.id == definition.entryNodeID ? "Entry" : "Waits for: " + definition.upstream(of: node.id).map(\.name).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !node.input.text.isEmpty {
                                Text(verbatim: node.input.text).textSelection(.enabled)
                            }
                            if node.allowsFinish {
                                Label("Can end this workflow", symbol: .checkmarkCircle).font(.caption)
                            }
                            NavigationLink(node.kind == .content ? "Preview output" : "Preview task input") { AgentWorkflowInputPreview(definition: definition, node: node, attachments: attachments) }
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    if let loop = definition.loop {
                        LabeledContent("Loop", value: "Up to \(loop.maximumRounds) rounds")
                        Text("The final node’s output returns to the entry unless an authorized Agent requests completion.").foregroundStyle(.secondary)
                    } else {
                        Text("Run once after all dependencies finish.")
                    }
                    DatePicker("Authorization expires", selection: $expiresAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .disabled(pendingStart != nil)
                    Button(pendingStart == nil ? "Start workflow" : "Retry original start") { start(definition) }
                        .disabled(busy || !endpoint.isConnected)
                    if pendingStart != nil, !busy {
                        Text("The previous start has not been confirmed. Retrying uses the same request and configuration; check Runs before starting another workflow.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Starting authorizes these Agent instances to exchange task results and the listed roles to request completion. Other instances receive no access.")
                }
                Section {
                    Button("Delete configuration", role: .destructive) { confirmingDelete = true }
                        .disabled(busy || pendingStart != nil || !endpoint.isConnected)
                }
            } else if error == nil {
                ProgressView("Loading configuration…")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(definition?.name ?? "Configuration")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = definition }.disabled(definition == nil || busy || pendingStart != nil || !endpoint.isConnected)
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) {
            AgentWorkflowEditor(endpoint: endpoint, definition: $0, isNew: false, createAgent: createAgent)
        }
        .navigationDestination(item: $startedRun) {
            AgentWorkflowRunView(endpoint: endpoint, hostID: hostID, runID: $0, openAgent: openAgent)
        }
        .confirmationDialog("Delete this configuration?", isPresented: $confirmingDelete) {
            if let definition {
                Button("Delete configuration", role: .destructive) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            _ = try await endpoint.request(.deleteDefinition(definition.id, expectedRevision: definition.revision), hostID: hostID)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        } message: { Text("Existing runs keep their saved configuration and results.") }
        .task { await load() }
    }

    private func load() async {
        do {
            let response = try await endpoint.request(.definition(definitionID), hostID: hostID)
            guard let value = response.definition else { throw AgentWorkflowError("The configuration is unavailable.") }
            let metadata = try await endpoint.attachments(Array(value.attachmentIDs), hostID: hostID)
            try Task.checkCancellation()
            attachments = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
            definition = value
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func start(_ definition: AgentWorkflowDefinition) {
        guard !busy else { return }
        let attempt = pendingStart ?? .start(
            definitionID: definition.id, expectedRevision: definition.revision,
            requestID: startRequestID, authorizationExpiresAt: expiresAt
        )
        pendingStart = attempt
        busy = true
        Task {
            defer { busy = false }
            do {
                let response = try await endpoint.request(attempt, hostID: hostID)
                guard let run = response.run else { throw AgentWorkflowError("The Host did not confirm the workflow. Retry to check this request.") }
                startedRun = run.summary.id
                startRequestID = UUID()
                pendingStart = nil
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
