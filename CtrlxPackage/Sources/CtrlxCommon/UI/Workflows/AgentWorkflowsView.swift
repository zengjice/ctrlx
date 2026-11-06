import CtrlxNetworking
import SwiftUI

@MainActor
public struct AgentWorkflowsView: View {
    private let endpoints: () -> [AgentWorkflowEndpoint]
    private let openAgent: (String, AgentWorkflowInstance) -> Void
    private let createAgent: ((String, UUID) async throws -> AgentWorkflowAgentCreation)?
    private let close: (() -> Void)?
    private let navigation: AgentWorkflowNavigation

    public init(
        endpoints: @escaping () -> [AgentWorkflowEndpoint],
        openAgent: @escaping (String, AgentWorkflowInstance) -> Void,
        createAgent: ((String, UUID) async throws -> AgentWorkflowAgentCreation)? = nil,
        close: (() -> Void)? = nil,
        navigation: AgentWorkflowNavigation = .init()
    ) {
        self.endpoints = endpoints
        self.openAgent = openAgent
        self.createAgent = createAgent
        self.close = close
        self.navigation = navigation
    }

    public var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            List {
                Section {
                    ForEach(endpoints()) { endpoint in
                        NavigationLink(value: AgentWorkflowNavigation.Destination.host(endpoint.id)) {
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
            .navigationDestination(for: AgentWorkflowNavigation.Destination.self) { destination in
                if let endpoint = endpoints().first(where: { $0.id == destination.route }) {
                    let open: (AgentWorkflowInstance) -> Void = { instance in
                        navigation.remember(instance, route: endpoint.id)
                        openAgent(endpoint.id, instance)
                    }
                    let create = createAgent.map { action in { hostID in try await action(endpoint.id, hostID) } }
                    switch destination {
                    case .host:
                        AgentWorkflowHostView(endpoint: endpoint, createAgent: create, navigation: navigation, openAgent: open)
                    case let .configuration(_, hostID, id):
                        AgentWorkflowConfigurationView(endpoint: endpoint, hostID: hostID, definitionID: id, openAgent: open, createAgent: create, navigation: navigation)
                    case let .run(_, hostID, id):
                        AgentWorkflowRunView(endpoint: endpoint, hostID: hostID, runID: id, openAgent: open)
                    }
                } else {
                    ContentUnavailableView("Host unavailable", image: Symbols.exclamationmarkTriangle.rawValue)
                }
            }
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
    let createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?
    @Environment(\.scenePhase) private var scenePhase
    let navigation: AgentWorkflowNavigation
    let openAgent: (AgentWorkflowInstance) -> Void
    @State private var starting: AgentWorkflowDefinitionSummary?
    @State private var overview: AgentWorkflowOverview?
    @State private var editing: AgentWorkflowDefinition?
    @State private var error: String?
    @State private var loading = false
    @State private var pendingDeletion: AgentWorkflowRunSummary?
    @State private var confirmingDelete = false
    @State private var deleting = false

    var body: some View {
        List {
            if let overview {
                Section("Configurations") {
                    ForEach(overview.definitions) { definition in
                        HStack {
                            NavigationLink(value: AgentWorkflowNavigation.Destination.configuration(route: endpoint.id, hostID: overview.hostID, id: definition.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(definition.name)
                                    Text("\(definition.nodeCount) steps").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button { starting = definition } label: { Label("Start workflow", symbol: .playFill).labelStyle(.iconOnly) }
                                .buttonStyle(.borderless)
                                .disabled(!endpoint.isConnected)
                                .accessibilityIdentifier("workflow-quick-start-\(definition.id)")
                        }
                    }
                    if overview.definitions.isEmpty {
                        Text("Create your first workflow.").foregroundStyle(.secondary)
                    }
                }
                Section("Runs") {
                    ForEach(overview.runs) { run in
                        HStack {
                            NavigationLink(value: AgentWorkflowNavigation.Destination.run(route: endpoint.id, hostID: overview.hostID, id: run.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run.name)
                                    Text("\(run.status.title) · round \(run.round)").font(.caption).foregroundStyle(.secondary)
                                    if let issue = run.issue {
                                        Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2)
                                    }
                                }
                            }
                            if run.status.isTerminal {
                                deleteButton(run).labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .help("Delete run")
                                    .accessibilityIdentifier("workflow-delete-run-\(run.id)")
                            }
                        }
                        .contextMenu {
                            if run.status.isTerminal {
                                deleteButton(run)
                            }
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            if run.status.isTerminal {
                                deleteButton(run)
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
        .sheet(item: $starting, onDismiss: { Task { await refresh() } }) { definition in
            if let hostID = overview?.hostID {
                AgentWorkflowStartView(endpoint: endpoint, hostID: hostID, definitionID: definition.id, navigation: navigation, openAgent: openAgent)
            }
        }
        .confirmationDialog("Delete this run and its handoff history?", isPresented: $confirmingDelete, presenting: pendingDeletion) { run in
            Button("Delete run", role: .destructive) { delete(run) }
                .disabled(loading || deleting || !endpoint.isConnected)
                .accessibilityIdentifier("workflow-confirm-delete-run")
        } message: { _ in
            Text("The configuration and Agent tabs stay available.")
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
        guard !loading, !deleting else { return }
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

    private func deleteButton(_ run: AgentWorkflowRunSummary) -> some View {
        Button(role: .destructive) {
            pendingDeletion = run
            confirmingDelete = true
        } label: { Label("Delete run", symbol: .trash) }
            .disabled(loading || deleting || !endpoint.isConnected)
    }

    private func delete(_ run: AgentWorkflowRunSummary) {
        guard !loading, !deleting, let hostID = overview?.hostID else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await endpoint.request(.deleteRun(run.id, expectedRevision: run.revision), hostID: hostID)
                if let overview {
                    self.overview = .init(hostID: overview.hostID, definitions: overview.definitions, runs: overview.runs.filter { $0.id != run.id })
                }
                error = nil
            } catch { self.error = error.localizedDescription }
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
    var navigation = AgentWorkflowNavigation()
    @Environment(\.dismiss) private var dismiss
    @State private var definition: AgentWorkflowDefinition?
    @State private var attachments: [UUID: AgentWorkflowAttachment] = [:]
    @State private var editing: AgentWorkflowDefinition?
    @State private var instances: [AgentWorkflowInstance] = []
    @State private var showingStart = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            if let definition {
                Section("Initial task") {
                    Text(verbatim: definition.initialInput.text).textSelection(.enabled)
                    ForEach(definition.initialInput.attachmentIDs, id: \.self) { AgentWorkflowAttachmentLabel(attachment: attachments[$0]) }
                }
                Section("Participating Agents") {
                    ForEach(definition.agents) { participant in
                        VStack(alignment: .leading) {
                            Text(participant.name).font(.headline)
                            Text(instances.first { $0.id == participant.id }?.displayName ?? "Agent unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Steps") {
                    ForEach(definition.nodes) { node in
                        if node.kind == .content {
                            NavigationLink {
                                AgentWorkflowInputPreview(definition: definition, node: node, attachments: attachments)
                            } label: { nodeLabel(node, definition: definition) }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                let instance = instances.first { $0.id == node.agentInstanceID }
                                Button {
                                    if let instance {
                                        openAgent(instance)
                                    }
                                } label: { nodeLabel(node, definition: definition) }
                                    .buttonStyle(.plain)
                                    .disabled(!endpoint.isConnected || instance == nil || instance?.readiness == .unavailable)
                                    .accessibilityIdentifier("workflow-open-agent-\(node.id)")
                                NavigationLink("Preview task input") { AgentWorkflowInputPreview(definition: definition, node: node, attachments: attachments) }
                            }
                        }
                    }
                }
                Section {
                    if let loop = definition.loop {
                        LabeledContent("Loop", value: "Up to \(loop.maximumRounds) rounds")
                        LabeledContent("Repeat from", value: definition.nodes.first { $0.id == (loop.entryNodeID ?? definition.entryNodeID) }?.name ?? "Unavailable")
                        Text(loop.includesResult ? "The final step's output is passed to the repeat entry." : "Repeating waits for the final step without passing its output.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Run once after all dependencies finish.")
                    }
                    Button("Start workflow…") { showingStart = true }
                        .disabled(busy || !endpoint.isConnected)
                } footer: {
                    Text("Starting authorizes these Agent instances to exchange task results and the listed roles to request completion. Other instances receive no access.")
                }
                Section {
                    Button("Delete configuration", role: .destructive) { confirmingDelete = true }
                        .disabled(busy || !endpoint.isConnected)
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
                Button("Edit") { editing = definition }.disabled(definition == nil || busy || !endpoint.isConnected)
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) {
            AgentWorkflowEditor(endpoint: endpoint, definition: $0, isNew: false, createAgent: createAgent)
        }
        .sheet(isPresented: $showingStart) {
            AgentWorkflowStartView(endpoint: endpoint, hostID: hostID, definitionID: definitionID, navigation: navigation, openAgent: openAgent)
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

    private func nodeLabel(_ node: AgentWorkflowNode, definition: AgentWorkflowDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(node.name, symbol: node.kind == .content ? .docTextFill : .terminal).font(.headline)
            if node.kind == .content {
                Text("Content node").font(.caption).foregroundStyle(.secondary)
            } else if let instance = instances.first(where: { $0.id == node.agentInstanceID }) {
                Text("\(definition.agents.first { $0.id == instance.id }?.name ?? instance.displayName) · \(instance.displayName) · \(instance.readiness.title)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Agent unavailable").font(.caption).foregroundStyle(.secondary)
            }
            Text(node.id == definition.entryNodeID ? "Entry" : "Waits for: " + definition.upstream(of: node.id).map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(definition.edges.filter { $0.target == node.id }, id: \.source) { edge in
                let source = definition.nodes.first { $0.id == edge.source }?.name ?? "Unavailable"
                Text("\(source): \(edge.includesResult ? "output and attachments" : "completion only")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Original task: \(definition.initialTask(for: node).title)").font(.caption).foregroundStyle(.secondary)
            if !node.input.text.isEmpty {
                Text(verbatim: node.input.text)
            }
            if node.allowsFinish {
                Label("Can end this workflow", symbol: .checkmarkCircle).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            let response = try await endpoint.request(.definition(definitionID), hostID: hostID)
            guard let value = response.definition else { throw AgentWorkflowError("The configuration is unavailable.") }
            let metadata = try await endpoint.attachments(Array(value.attachmentIDs), hostID: hostID)
            try Task.checkCancellation()
            attachments = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
            definition = value
            instances = value.agentInstanceIDs.isEmpty ? [] : try await endpoint.instances(hostID: hostID)
            try Task.checkCancellation()
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
