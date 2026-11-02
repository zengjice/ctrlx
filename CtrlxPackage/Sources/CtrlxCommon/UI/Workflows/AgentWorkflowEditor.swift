import CtrlxNetworking
import os
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import PhotosUI
#endif

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
    @State private var imageError: (target: AttachmentTarget, message: String)?
    #if os(iOS)
        @State private var showingPhotos = false
        @State private var selectedPhotos: [PhotosPickerItem] = []
    #endif
    @State private var showingReviewTemplate = false

    private enum AttachmentTarget: Equatable {
        case initial
        case node(UUID)
    }

    private struct AttachmentImport {
        let id = UUID()
        let target: AttachmentTarget
        let sources: [AgentWorkflowImageSource]
    }

    init(endpoint: AgentWorkflowEndpoint, definition: AgentWorkflowDefinition, isNew: Bool, createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?) {
        self.endpoint = endpoint
        self.isNew = isNew
        self.createAgent = createAgent
        self.expectedRevision = isNew ? nil : definition.revision
        var editable = definition
        editable.participants = definition.agents
        for index in editable.nodes.indices {
            editable.nodes[index].initialTask = definition.initialTask(for: definition.nodes[index])
        }
        self._draft = State(initialValue: editable)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Workflow name", text: $draft.name)
                    taskInput("Initial task", text: $draft.initialInput.text, ids: draft.initialInput.attachmentIDs, target: .initial) { id in
                        draft.initialInput.attachmentIDs.removeAll { $0 == id }
                    }
                    Text("Choose which steps receive the original task and attachments. The review template sends them only to initial development.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.nodes.isEmpty {
                    Section("Quick start") {
                        Button("Develop, review and repair…") { showingReviewTemplate = true }
                            .disabled(instances.count < 2)
                            .accessibilityIdentifier("workflow-review-template")
                        Text("Choose a Developer and a Reviewer. The template separates development, judgment and repair, and repeats from review.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Participating Agents") {
                    ForEach(draft.agents) { participant in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Role name", text: participantName(participant.id))
                            Picker("Agent", selection: participantBinding(participant.id)) {
                                ForEach(instances.filter { instance in instance.id == participant.id || !draft.agents.contains(where: { $0.id == instance.id }) }) { instance in
                                    Text(instance.displayName).tag(instance.id)
                                }
                                if !instances.contains(where: { $0.id == participant.id }) {
                                    Text("Agent unavailable · choose a replacement").tag(participant.id)
                                }
                            }
                            Button("Remove Agent", role: .destructive) {
                                draft.participants?.removeAll { $0.id == participant.id }
                            }.disabled(draft.nodes.contains { $0.agentInstanceID == participant.id })
                        }
                    }
                    Menu {
                        ForEach(instances.filter { instance in !draft.agents.contains(where: { $0.id == instance.id }) }) { instance in
                            Button(instance.displayName) { add(instance) }
                        }
                    } label: { Label("Add existing Agent", symbol: .plus) }
                    if createAgent != nil {
                        Button("New Agent tab") { showingCreation = true }.disabled(createdAgent != nil)
                    }
                    if createdAgent != nil {
                        Text("Agent created. Complete any setup in its terminal, then refresh Agents.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Choose another Agent") { createdAgent = nil }
                    }
                    Button { Task { await refreshInstances() } } label: {
                        Label("Refresh Agents", symbol: .arrowClockwise)
                    }.disabled(refreshing)
                    Text("Each participant keeps one Agent and conversation. Multiple steps can use that same Agent in sequence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($draft.nodes) { $node in
                    Section {
                        TextField("Step name", text: $node.name)
                        if node.kind == .agent {
                            Picker("Run as", selection: $node.agentInstanceID) {
                                ForEach(draft.agents) { participant in
                                    Text(participant.name).tag(Optional(participant.id))
                                }
                                if !draft.agents.contains(where: { $0.id == node.agentInstanceID }) {
                                    Text("Choose a participating Agent").tag(node.agentInstanceID)
                                }
                            }
                            if let instance = instances.first(where: { $0.id == node.agentInstanceID }) {
                                Text(instance.displayName).font(.caption).foregroundStyle(.secondary)
                                Text(instance.workingDirectory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let issue = instance.capabilityIssue {
                                    Text(issue).font(.caption).foregroundStyle(.orange)
                                } else if instance.readiness != .ready {
                                    Text(instance.readiness.title).font(.caption).foregroundStyle(.orange)
                                }
                            }
                        } else {
                            Label("Content step", symbol: .docTextFill).font(.caption).foregroundStyle(.secondary)
                            Text("Prepares text and attachments without calling an Agent. Connect an Agent step to send this material.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        taskInput("Instructions or skill for this step", text: $node.input.text, ids: node.input.attachmentIDs, target: .node(node.id)) { id in
                            node.input.attachmentIDs.removeAll { $0 == id }
                        }
                        Picker("Original task", selection: Binding(get: { draft.initialTask(for: node) }, set: { node.initialTask = $0 })) {
                            ForEach(AgentWorkflowNode.InitialTask.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        NavigationLink(node.kind == .content ? "Preview output" : "Preview task input") {
                            AgentWorkflowInputPreview(definition: draft, node: node, attachments: attachments)
                        }
                        if node.kind == .agent {
                            Toggle("Allow this step to end the workflow", isOn: $node.allowsFinish)
                            if node.allowsFinish {
                                Text("Define when to finish in this step's instructions. This switch grants permission; it does not define the completion condition.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        DisclosureGroup("Wait for upstream steps") {
                            ForEach(draft.nodes.filter { $0.id != node.id }) { source in
                                Toggle(source.name, isOn: connection(from: source.id, to: node.id))
                                if draft.edges.contains(where: { $0.source == source.id && $0.target == node.id }) {
                                    Picker("Receive from \(source.name)", selection: includesResult(from: source.id, to: node.id)) {
                                        Text("Completion only").tag(false)
                                        Text("Output and attachments").tag(true)
                                    }
                                }
                            }
                            Text("Always waits for all selected steps. Completion only sends no upstream text or attachments.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let targets = draft.nodes.filter { target in
                            draft.edges.contains { $0.source == node.id && $0.target == target.id }
                        }
                        Text(targets.isEmpty ? "No downstream steps." : "Then: " + targets.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Remove step", role: .destructive) { remove(node.id) }
                    } header: {
                        Text("Step \((draft.nodes.firstIndex { $0.id == node.id } ?? 0) + 1) · \(node.name)")
                    }
                }
                Section {
                    Menu {
                        ForEach(draft.agents) { participant in
                            Button(participant.name) {
                                addNode(.init(name: "\(participant.name) task", agentInstanceID: participant.id, initialTask: draft.nodes.isEmpty ? .textAndAttachments : .omit))
                            }
                        }
                    } label: { Label("Add Agent step", symbol: .plus) }
                        .disabled(draft.agents.isEmpty)
                    Button {
                        addNode(.init(name: "Content", content: .init(), initialTask: draft.nodes.isEmpty ? .textAndAttachments : .omit))
                    } label: { Label("Add content step", symbol: .docTextFill) }
                }
                if !draft.nodes.isEmpty {
                    Section("Execution") {
                        Picker("First step", selection: $draft.entryNodeID) {
                            ForEach(draft.nodes) { Text($0.name).tag($0.id) }
                        }
                        Toggle("Repeat rounds", isOn: Binding(get: { draft.loop != nil }, set: { enabled in
                            draft.loop = enabled ? .init(finalNodeID: draft.nodes.last?.id ?? draft.entryNodeID) : nil
                        }))
                        if draft.loop != nil {
                            Picker("Final step", selection: Binding(get: { draft.loop?.finalNodeID ?? draft.entryNodeID }, set: { draft.loop?.finalNodeID = $0 })) {
                                ForEach(draft.nodes) { Text($0.name).tag($0.id) }
                            }
                            Picker("Repeat from", selection: Binding(get: { draft.loop?.entryNodeID ?? draft.entryNodeID }, set: { draft.loop?.entryNodeID = $0 })) {
                                ForEach(draft.nodes) { Text($0.name).tag($0.id) }
                            }
                            Toggle("Include final output on repeat", isOn: Binding(get: { draft.loop?.includesResult ?? true }, set: { draft.loop?.includesResult = $0 }))
                            TextField("Maximum rounds", value: Binding(get: { draft.loop?.maximumRounds ?? 5 }, set: { draft.loop?.maximumRounds = $0 }), format: .number)
                            Text("The first round starts at First step; later rounds start at Repeat from. Earlier steps are not repeated. All branches must reach Final step. The limit pauses the workflow.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let validationIssue {
                    Section { Text(validationIssue).font(.callout).foregroundStyle(.secondary) }
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
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): importImages(urls.map(AgentWorkflowImageSource.file), for: importTarget)
            case let .failure(failure): imageError = (importTarget, failure.localizedDescription)
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showingPhotos, selection: $selectedPhotos, maxSelectionCount: max(1, AgentWorkflowWire.maximumAttachments - draft.attachmentIDs.count), matching: .images)
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty else { return }
            importImages(photos.map(AgentWorkflowImageSource.photo), for: importTarget)
            selectedPhotos = []
        }
        #endif
        .task(id: importRequest?.id) {
            guard let request = importRequest else { return }
            await importAttachments(request)
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
        .sheet(isPresented: $showingReviewTemplate) {
            AgentWorkflowReviewTemplatePicker(instances: instances) { developer, reviewer in
                AgentWorkflowReviewTemplate.apply(to: &draft, developerID: developer, reviewerID: reviewer)
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
        Binding(get: { draft.edges.contains { $0.source == source && $0.target == target } }, set: { connected in
            draft.edges.removeAll { $0.source == source && $0.target == target }
            if connected {
                draft.edges.append(.init(source: source, target: target))
            }
        })
    }

    private func includesResult(from source: UUID, to target: UUID) -> Binding<Bool> {
        Binding(get: { draft.edges.first { $0.source == source && $0.target == target }?.includesResult ?? true }, set: { includes in
            if let index = draft.edges.firstIndex(where: { $0.source == source && $0.target == target }) {
                draft.edges[index].includesResult = includes
            }
        })
    }

    private func participantName(_ id: UUID) -> Binding<String> {
        Binding(get: { draft.agents.first { $0.id == id }?.name ?? "" }, set: { name in
            if let index = draft.participants?.firstIndex(where: { $0.id == id }) {
                draft.participants?[index].name = name
            }
        })
    }

    private func participantBinding(_ id: UUID) -> Binding<UUID> {
        Binding(get: { id }, set: { replacement in
            guard let index = draft.participants?.firstIndex(where: { $0.id == id }) else { return }
            draft.participants?[index].agentInstanceID = replacement
            for step in draft.nodes.indices where draft.nodes[step].agentInstanceID == id {
                draft.nodes[step].agentInstanceID = replacement
            }
        })
    }

    private func add(_ instance: AgentWorkflowInstance) {
        guard !draft.agents.contains(where: { $0.id == instance.id }) else { return }
        draft.participants = draft.agents + [.init(agentInstanceID: instance.id, name: instance.displayName)]
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
        if draft.loop?.entryNodeID == nodeID {
            draft.loop?.entryNodeID = draft.entryNodeID
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
                if !draft.agents.contains(where: { $0.id == instance.id }) {
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

    private func taskInput(_ title: String, text: Binding<String>, ids: [UUID], target: AttachmentTarget, remove: @escaping (UUID) -> Void) -> some View {
        AgentWorkflowTaskInput(
            title: title, text: text, ids: ids, attachments: attachments,
            add: {
                importTarget = target
                showingImporter = true
            }, photos: photoAction(for: target),
            receive: { importImages($0, for: target) }, remove: remove,
            progress: importRequest?.target == target ? (importName, importProgress) : nil,
            error: imageError?.target == target ? imageError?.message : nil
        )
    }

    private func photoAction(for target: AttachmentTarget) -> (() -> Void)? {
        #if os(iOS)
            return {
                importTarget = target
                showingPhotos = true
            }
        #else
            return nil
        #endif
    }

    private func importImages(_ sources: [AgentWorkflowImageSource], for target: AttachmentTarget) {
        guard !sources.isEmpty, importRequest == nil, !saving else { return }
        guard draft.attachmentIDs.count + sources.count <= AgentWorkflowWire.maximumAttachments else {
            imageError = (target, "A workflow supports up to 32 images. Choose fewer images.")
            return
        }
        imageError = nil
        importName = "Preparing image…"
        importProgress = 0
        importRequest = .init(target: target, sources: sources)
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
        defer {
            if importRequest?.id == request.id {
                importRequest = nil
            }
        }
        do {
            for source in request.sources {
                try Task.checkCancellation()
                importName = "Preparing image…"
                importProgress = 0
                let image = try await source.load()
                try Task.checkCancellation()
                importName = image.name
                let attachment = try await endpoint.importImage(image, hostID: draft.hostID) { sent, total in
                    importProgress = total > 0 ? Double(sent) / Double(total) : 0
                }
                importedIDs.insert(attachment.id)
                attachments[attachment.id] = attachment
                try appendAttachments([attachment], to: request.target)
            }
        } catch {
            if !Task.isCancelled {
                imageError = (request.target, error.localizedDescription)
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
