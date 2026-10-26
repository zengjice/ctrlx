import CtrlxNetworking
import os
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AgentWorkflowEditor: View {
    let endpoint: AgentWorkflowEndpoint
    let isNew: Bool
    let createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?
    private let expectedRevision: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentWorkflowDefinition
    @State private var instances: [AgentWorkflowInstance] = []
    @State private var error: String?
    @State private var saving = false
    @State private var refreshing = false
    @State private var creation: AgentWorkflowAgentCreation?
    @State private var showingCreation = false
    @State private var loadingCreation = false
    @State private var createdAgent: AgentWorkflowCreatedAgent?
    @State private var attachments: [UUID: AgentWorkflowAttachment] = [:]
    @State private var importedIDs: Set<UUID> = []
    @State private var showingImporter = false
    @State private var importTarget = AttachmentTarget.initial
    @State private var importRequest: AttachmentImport?
    @State private var importProgress = 0.0
    @State private var importName = ""
    @State private var mediaImport: MediaImport?
    @State private var queuedImport: AttachmentImport?

    private enum AttachmentTarget: Equatable {
        case initial
        case node(UUID)
    }

    private struct AttachmentImport: Equatable {
        let id = UUID()
        let target: AttachmentTarget
        let urls: [URL]
    }

    private struct MediaImport: Identifiable {
        let id = UUID()
        let target: AttachmentTarget
        let url: URL
        let mediaType: String
    }

    init(endpoint: AgentWorkflowEndpoint, definition: AgentWorkflowDefinition, isNew: Bool, createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?) {
        self.endpoint = endpoint
        self.isNew = isNew
        self.createAgent = createAgent
        self.expectedRevision = isNew ? nil : definition.revision
        self._draft = State(initialValue: definition)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Workflow name", text: $draft.name)
                    TextField("Initial task", text: $draft.initialInput.text, axis: .vertical).lineLimit(3...12)
                    AgentWorkflowAttachmentRows(
                        ids: draft.initialInput.attachmentIDs,
                        attachments: attachments,
                        add: { chooseAttachments(for: .initial) },
                        remove: { id in draft.initialInput.attachmentIDs.removeAll { $0 == id } }
                    )
                    Text("Initial attachments go to the entry node. Each node can also have its own preset attachments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($draft.nodes) { $node in
                    Section {
                        TextField("Name", text: $node.name)
                        if node.kind == .agent {
                            Picker("Agent", selection: $node.agentInstanceID) {
                                ForEach(instances) { instance in
                                    Text("\(instance.displayName) · \(instance.pluginID)").tag(Optional(instance.id))
                                }
                                if !instances.contains(where: { $0.id == node.agentInstanceID }) {
                                    Text("Agent unavailable · choose a replacement").tag(node.agentInstanceID)
                                }
                            }
                            if let instance = instances.first(where: { $0.id == node.agentInstanceID }) {
                                Text(instance.workingDirectory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let issue = instance.capabilityIssue {
                                    Text(issue).font(.caption).foregroundStyle(.orange)
                                } else if instance.readiness != .ready {
                                    Text(instance.readiness.title).font(.caption).foregroundStyle(.orange)
                                }
                            }
                        } else {
                            Label("Content node", symbol: .docTextFill).font(.caption).foregroundStyle(.secondary)
                            Text("Combines preset content with upstream outputs, then forwards it without calling an Agent.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("Instructions or skill", text: $node.input.text, axis: .vertical).lineLimit(3...12)
                        Text(node.kind == .content
                            ? "Skill commands are forwarded as text. Check that the downstream Agents have the required skills."
                            : "Skill availability is not verified. Check that this Agent has the skills used in your instructions.")
                            .font(.caption).foregroundStyle(.secondary)
                        AgentWorkflowAttachmentRows(
                            ids: node.input.attachmentIDs,
                            attachments: attachments,
                            add: { chooseAttachments(for: .node(node.id)) },
                            remove: { id in node.input.attachmentIDs.removeAll { $0 == id } }
                        )
                        NavigationLink(node.kind == .content ? "Preview output" : "Preview task input") { AgentWorkflowInputPreview(definition: draft, node: node, attachments: attachments) }
                        if node.kind == .agent {
                            Toggle("Allow this Agent to end the workflow", isOn: $node.allowsFinish)
                        }
                        DisclosureGroup("Wait for upstream nodes") {
                            ForEach(draft.nodes.filter { $0.id != node.id }) { source in
                                Toggle(source.name, isOn: connection(from: source.id, to: node.id))
                            }
                            Text("All selected upstream nodes must complete this round. Their outputs are combined in the order shown.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let targets = draft.nodes.filter { target in
                            draft.edges.contains(.init(source: node.id, target: target.id))
                        }
                        if targets.isEmpty {
                            Text("No downstream nodes in this round.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Sends results to: \(targets.map(\.name).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Remove node", role: .destructive) { remove(node.id) }
                    } header: {
                        Text(node.name.isEmpty ? "Node" : node.name)
                    }
                }
                Section {
                    Menu {
                        ForEach(instances.filter { instance in !draft.nodes.contains(where: { $0.agentInstanceID == instance.id }) }) { instance in
                            Button("\(instance.displayName) · \(instance.pluginID)") { add(instance) }
                        }
                    } label: { Label("Add Agent role", symbol: .plus) }
                        .disabled(instances.allSatisfy { instance in draft.nodes.contains(where: { $0.agentInstanceID == instance.id }) })
                    Button { addNode(.init(name: "Content", content: .init())) } label: {
                        Label("Add content node", symbol: .docTextFill)
                    }
                    if createAgent != nil {
                        Button("New Agent tab") { showingCreation = true }
                            .disabled(createdAgent != nil)
                    }
                    if createdAgent != nil {
                        Text("Agent created. Waiting for its identity. Complete any setup or sign-in in its terminal, then refresh Agents.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Choose another Agent") { createdAgent = nil }
                    }
                    Button { Task { await refreshInstances() } } label: {
                        Label("Refresh Agents", symbol: .arrowClockwise)
                    }.disabled(refreshing)
                    if instances.isEmpty {
                        Text("No supported Agent instances found. Open Codex or Claude Code on this Host, then refresh.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !draft.nodes.isEmpty {
                    Section("Execution") {
                        Picker("Entry node", selection: $draft.entryNodeID) {
                            ForEach(draft.nodes) { Text($0.name).tag($0.id) }
                        }
                        Toggle("Repeat rounds", isOn: Binding(get: { draft.loop != nil }, set: { enabled in
                            draft.loop = enabled ? .init(finalNodeID: draft.nodes.last?.id ?? draft.entryNodeID) : nil
                        }))
                        if draft.loop != nil {
                            Picker("Final node", selection: Binding(get: { draft.loop?.finalNodeID ?? draft.entryNodeID }, set: { draft.loop?.finalNodeID = $0 })) {
                                ForEach(draft.nodes) { Text($0.name).tag($0.id) }
                            }
                            TextField("Maximum rounds", value: Binding(get: { draft.loop?.maximumRounds ?? 5 }, set: { draft.loop?.maximumRounds = $0 }), format: .number)
                            Text("Every branch must reach the final node. Its output starts the next round unless an authorized Agent requests completion. The round limit pauses the workflow.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let validationIssue {
                    Section { Text(validationIssue).font(.callout).foregroundStyle(.secondary) }
                }
                if importRequest != nil {
                    Section("Importing attachment") {
                        Text(importName)
                        ProgressView(value: importProgress)
                        Text("Use Stop import to cancel. Files already imported stay in this draft.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .disabled(saving || importRequest != nil)
            .navigationTitle(isNew ? "New workflow" : "Edit workflow")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importRequest == nil ? "Cancel" : "Stop import") {
                        if importRequest != nil {
                            importRequest = nil
                        } else {
                            cancel()
                        }
                    }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving || importRequest != nil || validationIssue != nil || !endpoint.isConnected)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 500, idealHeight: 700)
        #endif
        .interactiveDismissDisabled(saving || importRequest != nil || !importedIDs.isEmpty)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.png, .jpeg, .text, .audio, .movie], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                guard !urls.isEmpty else { return }
                guard draft.attachmentIDs.count + urls.count <= AgentWorkflowWire.maximumAttachments else {
                    error = "A workflow supports up to 32 attachments. Choose fewer files."
                    return
                }
                importRequest = .init(target: importTarget, urls: urls)
            case let .failure(failure): error = failure.localizedDescription
            }
        }
        .task(id: importRequest) {
            guard let request = importRequest else { return }
            await importAttachments(request)
        }
        .sheet(item: $mediaImport, onDismiss: {
            importRequest = queuedImport
            queuedImport = nil
        }) { selection in
            AgentWorkflowMediaImportView(
                endpoint: endpoint, hostID: draft.hostID, url: selection.url,
                mediaType: selection.mediaType,
                availableAttachments: AgentWorkflowWire.maximumAttachments - draft.attachmentIDs.count
            ) { result in
                for item in [result.original] + result.outputs {
                    importedIDs.insert(item.id)
                    attachments[item.id] = item
                }
                do { try appendAttachments(result.outputs, to: selection.target) }
                catch { self.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showingCreation, onDismiss: { creation = nil }) {
            VStack {
                if let creation {
                    AgentWorkflowNewAgentView(creation: creation, preferredSession: draft.creationSession, workflowName: draft.name) { createdAgent = $0 }
                } else if let error {
                    VStack {
                        Text(error).textSelection(.enabled)
                        Button("Close") { showingCreation = false }
                    }.padding()
                } else {
                    ProgressView("Loading Agent launch options…").padding()
                }
            }.task {
                guard let createAgent, !loadingCreation else { return }
                loadingCreation = true
                error = nil
                defer { loadingCreation = false }
                do {
                    let options = try await createAgent(draft.hostID)
                    try Task.checkCancellation()
                    creation = options
                } catch {
                    if !Task.isCancelled {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
        .task {
            await refreshInstances()
            await refreshAttachments()
        }
        .onDisappear {
            let unused = importedIDs
            Task { await discardImports(unused) }
        }
        .task(id: createdAgent) {
            guard createdAgent != nil else { return }
            for _ in 0..<10 {
                await refreshInstances()
                guard createdAgent != nil, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .accessibilityIdentifier("workflow-editor")
    }

    private var validationIssue: String? {
        do { try AgentWorkflowWire.validate(draft)
            return nil
        } catch { return error.localizedDescription }
    }

    private func connection(from source: UUID, to target: UUID) -> Binding<Bool> {
        let edge = AgentWorkflowEdge(source: source, target: target)
        return Binding(get: { draft.edges.contains(edge) }, set: { connected in
            draft.edges.removeAll { $0 == edge }
            if connected {
                draft.edges.append(edge)
            }
        })
    }

    private func add(_ instance: AgentWorkflowInstance) {
        addNode(.init(name: instance.displayName, agentInstanceID: instance.id))
    }

    private func addNode(_ node: AgentWorkflowNode) {
        if draft.nodes.isEmpty {
            draft.entryNodeID = node.id
        }
        draft.nodes.append(node)
    }

    private func remove(_ nodeID: UUID) {
        draft.nodes.removeAll { $0.id == nodeID }
        draft.edges.removeAll { $0.source == nodeID || $0.target == nodeID }
        if draft.entryNodeID == nodeID {
            draft.entryNodeID = draft.nodes.first?.id ?? UUID()
        }
        if draft.loop?.finalNodeID == nodeID {
            draft.loop?.finalNodeID = draft.nodes.last?.id ?? draft.entryNodeID
        }
    }

    private func refreshInstances() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let values = try await endpoint.instances(hostID: draft.hostID)
            try Task.checkCancellation()
            instances = values
            if let target = createdAgent, let instance = values.first(where: { target.matches($0) }) {
                draft.creationSession = AgentWorkflowSessionReference(instance.workspacePane)
                if !draft.nodes.contains(where: { $0.agentInstanceID == instance.id }) {
                    add(instance)
                }
                createdAgent = nil
            }
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await endpoint.request(.save(draft, expectedRevision: expectedRevision), hostID: draft.hostID)
                let originals = draft.attachmentIDs.compactMap { attachments[$0]?.conversion?.sourceID }
                let unused = importedIDs.subtracting(draft.attachmentIDs.union(originals))
                importedIDs.removeAll()
                await discardImports(unused)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func chooseAttachments(for target: AttachmentTarget) {
        importTarget = target
        showingImporter = true
    }

    private func refreshAttachments() async {
        do {
            let values = try await endpoint.attachments(Array(draft.attachmentIDs), hostID: draft.hostID)
            try Task.checkCancellation()
            for value in values {
                attachments[value.id] = value
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func importAttachments(_ request: AttachmentImport) async {
        error = nil
        defer {
            if importRequest?.id == request.id {
                importRequest = nil
            }
        }
        do {
            // Validate formats before uploading any files in this selection.
            let types = try request.urls.map { try AgentWorkflowEndpoint.attachmentMediaType(for: $0) }
            for (index, pair) in zip(request.urls, types).enumerated() {
                let (url, type) = pair
                try Task.checkCancellation()
                guard draft.attachmentIDs.count < AgentWorkflowWire.maximumAttachments else {
                    throw AgentWorkflowError("The workflow already has 32 attachments. Remove some before importing more.")
                }
                if type.hasPrefix("audio/") || type.hasPrefix("video/") {
                    let remaining = Array(request.urls.dropFirst(index + 1))
                    queuedImport = remaining.isEmpty ? nil : .init(target: request.target, urls: remaining)
                    mediaImport = .init(target: request.target, url: url, mediaType: type)
                    return
                }
                importName = url.lastPathComponent
                importProgress = 0
                let attachment = try await endpoint.importAttachment(from: url, mediaType: type, hostID: draft.hostID) { sent, total in
                    importProgress = total > 0 ? Double(sent) / Double(total) : 0
                }
                importedIDs.insert(attachment.id)
                attachments[attachment.id] = attachment
                try appendAttachments([attachment], to: request.target)
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func appendAttachments(_ values: [AgentWorkflowAttachment], to target: AttachmentTarget) throws {
        switch target {
        case .initial: draft.initialInput.attachmentIDs.append(contentsOf: values.map(\.id))
        case let .node(id):
            guard let index = draft.nodes.firstIndex(where: { $0.id == id }) else {
                throw AgentWorkflowError("The role was removed. Import the attachment for another role.")
            }
            draft.nodes[index].input.attachmentIDs.append(contentsOf: values.map(\.id))
        }
    }

    private func cancel() {
        saving = true
        Task {
            await discardImports(importedIDs)
            importedIDs.removeAll()
            saving = false
            dismiss()
        }
    }

    private func discardImports(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        // Remove outputs before originals, including across batches. A retained
        // output deliberately prevents its original from being discarded.
        let values = ids.sorted { (attachments[$0]?.conversion == nil ? 1 : 0) < (attachments[$1]?.conversion == nil ? 1 : 0) }
        for offset in stride(from: 0, to: values.count, by: AgentWorkflowWire.maximumAttachments) {
            let end = min(values.count, offset + AgentWorkflowWire.maximumAttachments)
            do { _ = try await endpoint.request(.discardAttachments(Array(values[offset..<end])), hostID: draft.hostID) }
            catch {
                Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowUploads")
                    .error("Could not remove unused workflow imports: \(error.localizedDescription)")
            }
        }
    }
}

extension AgentWorkflowReadiness {
    var title: String {
        switch self {
        case .ready: "Ready"
        case .busy: "Agent is working; wait before starting."
        case .draft: "The Agent has an unsent draft."
        case .awaitingHuman: "Resolve the Agent’s question or permission request first."
        case .unavailable: "Agent identity or input cannot be verified."
        }
    }
}
