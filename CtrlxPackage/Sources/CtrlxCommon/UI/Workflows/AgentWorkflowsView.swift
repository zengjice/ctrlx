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
                        .listRowBackground(endpoint.id == "local" ? Color.accentColor.opacity(0.08) : nil)
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
        }
        .toolbar {
            if let close {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: close) { Label("Close", symbol: .xmark) }
                        .help("Close workflows")
                        .accessibilityIdentifier("workflow-close")
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
    @State private var tagFilter = ""
    @State private var starting: AgentWorkflowDefinitionSummary?
    @State private var configurations: (hostID: UUID, items: [AgentWorkflowDefinitionSummary])?
    @State private var runs: [AgentWorkflowRunSummary]?
    @State private var editing: AgentWorkflowDefinition?
    @State private var error: String?
    @State private var loading = false
    @State private var pendingDeletion: AgentWorkflowRunSummary?
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var duplicating = false

    private var filteredDefinitions: [AgentWorkflowDefinitionSummary] {
        (configurations?.items ?? []).filter { definition in
            tagFilter.isEmpty || (definition.tags ?? []).contains { $0.localizedStandardContains(tagFilter) }
        }
    }

    private func definitionLabel(_ definition: AgentWorkflowDefinitionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(definition.name)
            Text("\(definition.nodeCount) steps").font(.caption).foregroundStyle(.secondary)
            if let tags = definition.tags, !tags.isEmpty {
                Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func runStatusLabel(_ run: AgentWorkflowRunSummary) -> some View {
        let (symbol, color): (Symbols, Color) = switch run.status {
        case .running: (.playFill, .blue)
        case .paused: (.pause, .orange)
        case .finishing: (.hourglass, .blue)
        case .completed: (.checkmarkCircle, .green)
        case .ended: (.stopFill, .secondary)
        }
        return HStack(spacing: 6) {
            symbol.image
                .frame(minWidth: 12)
                .foregroundStyle(color.opacity(0.8))
                .accessibilityHidden(true)
            Text("\(run.status.title) · round \(run.round)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    var body: some View {
        List {
            if let configurations {
                Section("Configurations") {
                    TextField("Filter by tag", text: $tagFilter)
                    ForEach(filteredDefinitions) { definition in
                        HStack {
                            NavigationLink(value: AgentWorkflowNavigation.Destination.configuration(route: endpoint.id, hostID: configurations.hostID, id: definition.id)) {
                                definitionLabel(definition)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            Button { starting = definition } label: { Label("Start workflow", symbol: .playFill).labelStyle(.iconOnly) }
                                .buttonStyle(.borderless)
                                .disabled(duplicating || !endpoint.isConnected)
                                .accessibilityIdentifier("workflow-quick-start-\(definition.id)")
                            Button { duplicate(definition) } label: { Label("Duplicate configuration", symbol: .docOnDoc).labelStyle(.iconOnly) }
                                .buttonStyle(.borderless)
                                .disabled(loading || deleting || duplicating || !endpoint.isConnected)
                                .help("Duplicate configuration")
                                .accessibilityIdentifier("workflow-duplicate-\(definition.id)")
                        }
                    }
                    if configurations.items.isEmpty {
                        Text("Create your first workflow.").foregroundStyle(.secondary)
                    }
                }
                Section("Runs") {
                    ForEach(runs ?? []) { run in
                        HStack {
                            NavigationLink(value: AgentWorkflowNavigation.Destination.run(route: endpoint.id, hostID: configurations.hostID, id: run.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run.name)
                                    runStatusLabel(run)
                                    if let issue = run.issue {
                                        Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
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
                    if runs == nil, loading {
                        ProgressView("Loading runs…")
                    } else if runs?.isEmpty == true {
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
                    guard let hostID = configurations?.hostID else { return }
                    editing = .init(name: "", hostID: hostID, nodes: [], edges: [], entryNodeID: UUID())
                } label: { Label("New workflow", symbol: .plus) }
                    .disabled(configurations == nil || duplicating || !endpoint.isConnected || !endpoint.isSupported)
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await refresh() } }) { draft in
            AgentWorkflowEditor(endpoint: endpoint, definition: draft, isNew: true, createAgent: createAgent)
        }
        .sheet(item: $starting, onDismiss: { Task { await refresh() } }) { definition in
            if let hostID = configurations?.hostID {
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
        guard !loading, !deleting, !duplicating else { return }
        loading = true
        defer { loading = false }
        do {
            let saved = try await endpoint.configurations(hostID: configurations?.hostID)
            try Task.checkCancellation()
            configurations = saved
            error = nil
            let history = try await endpoint.runs(hostID: saved.hostID)
            try Task.checkCancellation()
            runs = history
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
            .disabled(loading || deleting || duplicating || !endpoint.isConnected)
    }

    private func duplicate(_ definition: AgentWorkflowDefinitionSummary) {
        guard !loading, !deleting, !duplicating, let hostID = configurations?.hostID else { return }
        let path = navigation.path
        duplicating = true
        Task {
            defer { duplicating = false }
            do {
                let source = try await endpoint.request(.definition(definition.id), hostID: hostID)
                guard navigation.path == path else { return }
                guard let original = source.definition else { throw AgentWorkflowError("The configuration is unavailable.") }
                editing = original.duplicated()
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func delete(_ run: AgentWorkflowRunSummary) {
        guard !loading, !deleting, !duplicating, let hostID = configurations?.hostID else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await endpoint.request(.deleteRun(run.id, expectedRevision: run.revision), hostID: hostID)
                runs?.removeAll { $0.id == run.id }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
struct AgentWorkflowConfigurationView: View {
    private struct CatalogSelection: Equatable {
        var bindings: [UUID: AgentWorkflowTarget?] = [:]
        var retry = 0
    }

    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let definitionID: UUID
    let openAgent: (AgentWorkflowInstance) -> Void
    let createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?
    var navigation = AgentWorkflowNavigation()
    @Environment(\.dismiss) private var dismiss
    @State private var definition: AgentWorkflowDefinition?
    @State private var definitionReload = 0
    @State private var detailVisible = false
    @State private var attachments: [UUID: AgentWorkflowAttachment]?
    @State private var attachmentReads: [Set<UUID>: Task<[UUID: AgentWorkflowAttachment], Error>] = [:]
    @State private var editing: AgentWorkflowDefinition?
    @State private var instances: [AgentWorkflowInstance]?
    @State private var instanceRead: (selection: CatalogSelection, task: Task<[AgentWorkflowInstance], Error>)?
    @State private var catalogSelection = CatalogSelection()
    @State private var showingStart = false
    @State private var busy = false
    @State private var error: String?
    @State private var attachmentError: String?
    @State private var agentError: String?
    @State private var confirmingDelete = false

    private var missingAgentLabel: String {
        instanceRead != nil || instances == nil && agentError == nil ? "Checking Agent…" : "Agent unavailable"
    }

    private var loadingAttachments: Bool {
        attachments == nil && attachmentError == nil && definition?.attachmentIDs.isEmpty == false
    }

    var body: some View {
        let attachmentIDs = definition?.attachmentIDs
        let selection = catalogSelection
        Form {
            if let definition {
                Section("Initial task") {
                    Text(verbatim: definition.initialInput.text).textSelection(.enabled)
                    if loadingAttachments, !definition.initialInput.attachmentIDs.isEmpty {
                        ProgressView("Loading attachments…")
                    } else {
                        ForEach(definition.initialInput.attachmentIDs, id: \.self) { AgentWorkflowAttachmentLabel(attachment: attachments?[$0]) }
                    }
                }
                Section("Participating Agents") {
                    ForEach(definition.agents) { participant in
                        let instance = definition.instance(for: participant.id, in: instances ?? [])
                        VStack(alignment: .leading) {
                            Text(instance?.displayName ?? missingAgentLabel).font(.headline)
                            if let instance {
                                Text(instance.workingDirectory).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let agentError {
                        Text(agentError).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Steps") {
                    ForEach(definition.nodes) { node in
                        if node.kind == .content {
                            NavigationLink {
                                AgentWorkflowInputPreview(definition: definition, node: node, attachments: attachments ?? [:])
                            } label: { nodeLabel(node, definition: definition) }
                                .disabled(loadingAttachments)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                let instance = openableInstance(for: node.agentInstanceID, in: definition)
                                Button {
                                    if let instance {
                                        openAgent(instance)
                                    }
                                } label: { nodeLabel(node, definition: definition) }
                                    .buttonStyle(.plain)
                                    .disabled(!endpoint.isConnected || instance == nil)
                                    .accessibilityIdentifier("workflow-open-agent-\(node.id)")
                                NavigationLink("Preview task input") { AgentWorkflowInputPreview(definition: definition, node: node, attachments: attachments ?? [:]) }
                                    .disabled(loadingAttachments)
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
                    Text("Starting authorizes these Agents to exchange task results. Steps with finish permission can request completion. Other instances receive no access.")
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
            if let attachmentError {
                Section { Text(attachmentError).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(definition?.name ?? "Configuration")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = definition }.disabled(definition == nil || busy || !endpoint.isConnected)
                    .accessibilityIdentifier("workflow-edit-configuration")
            }
        }
        .sheet(item: $editing, onDismiss: editorDismissed) { draft in
            AgentWorkflowEditor(
                endpoint: endpoint, definition: draft, isNew: false, createAgent: createAgent, initialInstances: instances,
                readInstances: readInstances, readAttachments: { try await readAttachments(draft.attachmentIDs) }
            )
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
        .onAppear { detailVisible = true }
        .onDisappear {
            detailVisible = false
            if editing == nil {
                cancelReads()
            }
        }
        .task(id: definitionReload) { await loadDefinition() }
        .task(id: attachmentIDs) {
            guard let attachmentIDs else { return }
            _ = try? await readAttachments(attachmentIDs)
        }
        .task(id: selection) { await readParticipatingAgents(selection) }
    }

    private func nodeLabel(_ node: AgentWorkflowNode, definition: AgentWorkflowDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(node.name, symbol: node.kind == .content ? .docTextFill : .terminal).font(.headline)
            if node.kind == .content {
                Text("Content node").font(.caption).foregroundStyle(.secondary)
            } else if let instance = definition.instance(for: node.agentInstanceID, in: instances ?? []) {
                Text("\(instance.displayName) · \(instance.readiness.title)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(missingAgentLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text(node.id == definition.entryNodeID ? "Entry" : "Waits for: " + definition.upstream(of: node.id).map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            if let selection = node.modelSelection {
                Text(selection.model + (selection.effort.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(definition.edges.filter { $0.target == node.id }, id: \.source) { edge in
                let source = definition.nodes.first { $0.id == edge.source }?.name ?? "Unavailable"
                Text("\(source): \(edge.includesResult ? "output and attachments" : "completion only")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Original task: \(definition.initialTask(for: node).title)").font(.caption).foregroundStyle(.secondary)
            if !node.input.text.isEmpty {
                Text(verbatim: node.input.text)
            }
            if
                let exit = definition.loopExit, exit.source == node.id,
                let target = definition.nodes.first(where: { $0.id == exit.target }) {
                Label("On approval: \(target.name)", symbol: .checkmarkCircle).font(.caption)
            } else if node.allowsFinish {
                Label("Can end this workflow", symbol: .checkmarkCircle).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func loadDefinition() async {
        do {
            let response = try await endpoint.request(.definition(definitionID), hostID: hostID)
            guard let value = response.definition else { throw AgentWorkflowError("The configuration is unavailable.") }
            try Task.checkCancellation()
            if definition?.attachmentIDs != value.attachmentIDs {
                attachments = nil
                attachmentError = nil
            }
            let resolved = value.resolvingAgents(in: instances ?? [])
            definition = resolved
            let bindings = Dictionary(value.agents.map { ($0.id, value.agentTargets?[$0.id]) }, uniquingKeysWith: { first, _ in first })
            let retry = needsCatalogRead(for: resolved) ? catalogSelection.retry + 1 : catalogSelection.retry
            catalogSelection = CatalogSelection(bindings: bindings, retry: retry)
            error = nil
            if attachmentError != nil {
                _ = try? await readAttachments(value.attachmentIDs)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func editorDismissed() {
        if !detailVisible {
            cancelReads()
        }
        definitionReload += 1
    }

    private func cancelReads() {
        instanceRead?.task.cancel()
        instanceRead = nil
        for pending in attachmentReads.values {
            pending.cancel()
        }
        attachmentReads.removeAll()
    }

    private func readAttachments(_ ids: Set<UUID>) async throws -> [UUID: AgentWorkflowAttachment] {
        try Task.checkCancellation()
        if let pending = attachmentReads[ids] {
            return try await pending.value
        }
        if definition?.attachmentIDs == ids, let attachments {
            return attachments
        }
        let pending = Task { [endpoint, hostID] in
            let metadata = try await endpoint.attachments(Array(ids), hostID: hostID)
            return Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        }
        attachmentReads[ids] = pending
        defer {
            if !pending.isCancelled {
                attachmentReads[ids] = nil
            }
        }
        do {
            let values = try await pending.value
            guard !pending.isCancelled else { throw CancellationError() }
            if definition?.attachmentIDs == ids {
                attachments = values
                attachmentError = nil
            }
            return values
        } catch {
            if !pending.isCancelled, definition?.attachmentIDs == ids {
                attachmentError = error.localizedDescription
            }
            throw error
        }
    }

    private func openableInstance(for agentID: UUID?, in definition: AgentWorkflowDefinition) -> AgentWorkflowInstance? {
        guard
            let instance = definition.instance(for: agentID, in: instances ?? []),
            instance.readiness != .unavailable else { return nil }
        return instance
    }

    private func needsCatalogRead(for definition: AgentWorkflowDefinition) -> Bool {
        definition.agents.contains { agentError != nil || openableInstance(for: $0.id, in: definition) == nil }
    }

    private func readParticipatingAgents(_ selection: CatalogSelection) async {
        guard !selection.bindings.isEmpty else { return }
        if let pending = instanceRead, pending.selection != selection {
            _ = try? await pending.task.value
        }
        guard selection == catalogSelection, let definition else { return }
        _ = try? await readInstances(useCached: !needsCatalogRead(for: definition))
    }

    private func readInstances(useCached: Bool) async throws -> [AgentWorkflowInstance] {
        try Task.checkCancellation()
        if let instanceRead {
            return try await instanceRead.task.value
        }
        if useCached, let instances {
            return instances
        }
        let pending = Task {
            defer {
                if !Task.isCancelled {
                    instanceRead = nil
                }
            }
            do {
                let values = try await endpoint.instances(hostID: hostID)
                try Task.checkCancellation()
                instances = values
                definition = definition?.resolvingAgents(in: values)
                agentError = nil
                return values
            } catch {
                if !Task.isCancelled {
                    agentError = error.localizedDescription
                }
                throw error
            }
        }
        instanceRead = (catalogSelection, pending)
        return try await pending.value
    }
}
